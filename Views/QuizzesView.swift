import SwiftUI

struct QuizzesView: View {
    @EnvironmentObject private var assistant: TutorEngine
    @State private var selectedSourceID: UUID?

    private var selectedSource: StudySource? {
        guard let selectedSourceID else { return nil }
        return assistant.sources.first { $0.id == selectedSourceID }
    }

    private var visibleHistory: [QuizHistoryEntry] {
        assistant.quizHistory
            .filter { entry in
                guard let selectedSourceID else { return true }
                return entry.sourceID == selectedSourceID
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    private var evidence: QuizProgressEvidence {
        assistant.quizProgressEvidence(for: selectedSource)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                AppHeader(
                    title: "History",
                    subtitle: "Quiz attempts, feedback, and learning evidence."
                )

                if assistant.quizHistory.isEmpty {
                    EmptyInlineState(
                        title: "No quizzes yet",
                        detail: "Finish a quiz from Home. Your scores, answers, and feedback will appear here.",
                        systemImage: "checklist",
                        actionTitle: nil,
                        action: nil
                    )
                } else {
                    QuizSourceFilter(
                        sources: assistant.sources,
                        selectedSourceID: selectedSourceID,
                        onSelect: { sourceID in
                            selectedSourceID = sourceID
                        }
                    )

                    QuizHistorySummary(
                        title: selectedSource?.title ?? "All Notes",
                        history: visibleHistory,
                        evidence: evidence
                    )

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Quizzes")
                            .font(.headline.weight(.semibold))

                        if visibleHistory.isEmpty {
                            Text("No quizzes for this note yet.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(14)
                                .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 8))
                        } else {
                            ForEach(visibleHistory) { entry in
                                NavigationLink {
                                    QuizHistoryDetailView(
                                        entry: entry,
                                        attempts: attemptDetails(for: entry)
                                    )
                                } label: {
                                    QuizHistorySessionRow(entry: entry)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 140)
        }
        .background(QuizLoopTheme.background)
        .toolbar(.hidden, for: .navigationBar)
    }

    private func attemptDetails(for entry: QuizHistoryEntry) -> [QuizAttemptDetail] {
        let questionsByID = Dictionary(uniqueKeysWithValues: assistant.questions.map { ($0.id, $0) })
        let attemptsByID = Dictionary(uniqueKeysWithValues: assistant.attempts.map { ($0.id, $0) })

        let sessionAttempts: [QuestionAttempt]
        if entry.attemptIDs.isEmpty == false {
            sessionAttempts = entry.attemptIDs.compactMap { attemptsByID[$0] }
        } else {
            let lowerBound = entry.createdAt.addingTimeInterval(-5 * 60)
            let upperBound = entry.createdAt.addingTimeInterval(60)
            sessionAttempts = assistant.attempts
                .filter { attempt in
                    guard lowerBound...upperBound ~= attempt.createdAt,
                          let question = questionsByID[attempt.questionID]
                    else { return false }
                    if let sourceID = entry.sourceID {
                        return question.sourceID == sourceID
                    }
                    return true
                }
                .sorted { $0.createdAt < $1.createdAt }
                .suffix(entry.questionCount)
        }

        return sessionAttempts.compactMap { attempt in
            guard let question = questionsByID[attempt.questionID] else { return nil }
            return QuizAttemptDetail(question: question, attempt: attempt)
        }
    }
}

private struct QuizAttemptDetail: Identifiable {
    let id: UUID
    let question: LearningQuestion
    let attempt: QuestionAttempt

    init(question: LearningQuestion, attempt: QuestionAttempt) {
        self.id = attempt.id
        self.question = question
        self.attempt = attempt
    }
}

private struct QuizSourceFilter: View {
    let sources: [StudySource]
    let selectedSourceID: UUID?
    let onSelect: (UUID?) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                filterButton(title: "All", sourceID: nil)

                ForEach(sources) { source in
                    filterButton(title: source.title, sourceID: source.id)
                }
            }
            .padding(.vertical, 2)
        }
        .accessibilityLabel("Quiz history filter")
    }

    private func filterButton(title: String, sourceID: UUID?) -> some View {
        Button {
            onSelect(sourceID)
        } label: {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .foregroundStyle(selectedSourceID == sourceID ? .white : .primary)
                .background(
                    selectedSourceID == sourceID ? Color.teal : Color(.secondarySystemBackground),
                    in: Capsule()
                )
                .overlay {
                    Capsule()
                        .stroke(Color(.separator).opacity(selectedSourceID == sourceID ? 0 : 0.35), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
    }
}

private struct QuizHistorySummary: View {
    let title: String
    let history: [QuizHistoryEntry]
    let evidence: QuizProgressEvidence

    private var latest: QuizHistoryEntry? {
        history.first
    }

    private var previous: QuizHistoryEntry? {
        history.dropFirst().first
    }

    private var deltaText: String {
        guard let latest, let previous else {
            return latest == nil ? "No quizzes yet" : "First quiz saved"
        }

        let delta = Int(((latest.score - previous.score) * 100).rounded())
        if delta > 0 {
            return "+\(delta) points from last quiz"
        }
        if delta < 0 {
            return "\(delta) points from last quiz"
        }
        return "Same score as last quiz"
    }

    private var latestScoreText: String {
        latest?.percentText ?? "--"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline.weight(.semibold))
                        .lineLimit(1)

                    Text(deltaText)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                Text(latestScoreText)
                    .font(.system(size: 38, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(scoreColor)
            }

            QuizHistoryLine(points: evidence.points, direction: evidence.direction)

            HStack(spacing: 8) {
                summaryPill(title: "Quizzes", value: "\(history.count)", color: .teal)
                summaryPill(title: "Latest", value: latest?.createdAt.formatted(date: .abbreviated, time: .omitted) ?? "--", color: .secondary)
            }
        }
        .padding(14)
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 8))
    }

    private var scoreColor: Color {
        switch latest?.score ?? 0 {
        case 0.75...:
            .teal
        case 0.45..<0.75:
            .orange
        default:
            .secondary
        }
    }

    private func summaryPill(title: String, value: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            Text(title)
                .font(.caption2.weight(.medium))
        }
        .foregroundStyle(color)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct QuizHistoryLine: View {
    let points: [Double]
    let direction: QuizProgressEvidence.Direction

    private var chartPoints: [Double] {
        if points.isEmpty {
            return [0.05, 0.05]
        }
        if points.count == 1, let first = points.first {
            return [first, first]
        }
        return points
    }

    private var lineColor: Color {
        switch direction {
        case .rising:
            .teal
        case .slipping:
            .orange
        case .steady, .waiting:
            .secondary
        }
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                VStack(spacing: 16) {
                    ForEach(0..<3, id: \.self) { _ in
                        Rectangle()
                            .fill(Color(.separator).opacity(0.18))
                            .frame(height: 1)
                    }
                }

                linePath(in: proxy.size)
                    .stroke(lineColor, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))

                ForEach(Array(chartCoordinates(in: proxy.size).enumerated()), id: \.offset) { index, point in
                    Circle()
                        .fill(index == chartPoints.count - 1 ? lineColor : Color(.systemBackground))
                        .overlay {
                            Circle()
                                .stroke(lineColor.opacity(0.7), lineWidth: 1.5)
                        }
                        .frame(width: index == chartPoints.count - 1 ? 12 : 9, height: index == chartPoints.count - 1 ? 12 : 9)
                        .position(point)
                }
            }
        }
        .frame(height: 82)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Quiz score trend")
    }

    private func linePath(in size: CGSize) -> Path {
        let points = chartCoordinates(in: size)
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        for point in points.dropFirst() {
            path.addLine(to: point)
        }
        return path
    }

    private func chartCoordinates(in size: CGSize) -> [CGPoint] {
        let horizontalStep = chartPoints.count <= 1 ? 0 : size.width / CGFloat(chartPoints.count - 1)
        return chartPoints.enumerated().map { index, value in
            let clamped = min(max(value, 0), 1)
            return CGPoint(
                x: CGFloat(index) * horizontalStep,
                y: size.height - CGFloat(clamped) * size.height
            )
        }
    }
}

private struct QuizHistorySessionRow: View {
    let entry: QuizHistoryEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)

                    Text(entry.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                Text(entry.percentText)
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(scoreColor)
            }

            QuizResultMixBar(entry: entry)
        }
        .padding(12)
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 8))
    }

    private var scoreColor: Color {
        switch entry.score {
        case 0.75...:
            .teal
        case 0.45..<0.75:
            .orange
        default:
            .secondary
        }
    }
}

private struct QuizResultMixBar: View {
    let entry: QuizHistoryEntry

    private var total: Int {
        max(entry.questionCount, 1)
    }

    private var gotShare: Double {
        Double(entry.gotCount) / Double(total)
    }

    private var closeShare: Double {
        Double(entry.closeCount) / Double(total)
    }

    private var reviewShare: Double {
        Double(entry.reviewCount) / Double(total)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            GeometryReader { proxy in
                HStack(spacing: 2) {
                    segment(width: proxy.size.width * gotShare, color: .teal)
                    segment(width: proxy.size.width * closeShare, color: .orange)
                    segment(width: proxy.size.width * reviewShare, color: .secondary)
                }
            }
            .frame(height: 10)
            .clipShape(Capsule())
            .background(Color(.secondarySystemBackground), in: Capsule())

            HStack(spacing: 8) {
                label("Got", entry.gotCount, .teal)
                label("Close", entry.closeCount, .orange)
                label("Review", entry.reviewCount, .secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(entry.gotCount) got, \(entry.closeCount) close, \(entry.reviewCount) review")
    }

    private func segment(width: CGFloat, color: Color) -> some View {
        Rectangle()
            .fill(color)
            .frame(width: max(width, 0))
    }

    private func label(_ title: String, _ value: Int, _ color: Color) -> some View {
        Text("\(value) \(title)")
            .font(.caption2.weight(.medium))
            .foregroundStyle(color)
    }
}

private struct QuizHistoryDetailView: View {
    let entry: QuizHistoryEntry
    let attempts: [QuizAttemptDetail]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(entry.title)
                        .font(.title2.weight(.semibold))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(alignment: .firstTextBaseline) {
                        Text(entry.percentText)
                            .font(.system(size: 44, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(scoreColor)

                        Spacer()

                        Text(entry.createdAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    }

                    QuizResultMixBar(entry: entry)
                }
                .padding(14)
                .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 8))

                Text("Attempts")
                    .font(.headline.weight(.semibold))

                if attempts.isEmpty {
                    Text("Attempt details were not saved for this older quiz.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 8))
                } else {
                    ForEach(attempts) { detail in
                        QuizAttemptDetailCard(detail: detail)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 36)
        }
        .background(QuizLoopTheme.background)
        .navigationTitle("Quiz Details")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var scoreColor: Color {
        switch entry.score {
        case 0.75...:
            .teal
        case 0.45..<0.75:
            .orange
        default:
            .secondary
        }
    }
}

private struct QuizAttemptDetailCard: View {
    let detail: QuizAttemptDetail

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(resultTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(resultColor)

                Spacer(minLength: 8)

                Text(scoreText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(resultColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(resultColor.opacity(0.12), in: Capsule())
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(detail.question.topicTitle)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Text(detail.question.subtopicTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }

            Text(detail.question.prompt)
                .font(.subheadline.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)

            answerLine(title: "You", text: detail.attempt.response)
            answerLine(title: "Answer", text: detail.question.answer)

            if let feedback = meaningfulFeedback {
                Label(feedback, systemImage: "sparkles")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
            }

            if detail.attempt.missingIdeas.isEmpty == false {
                ideaList(title: "Needs review", ideas: detail.attempt.missingIdeas, color: .orange)
            }

            if detail.attempt.matchedIdeas.isEmpty == false, detail.attempt.score < 0.75 {
                ideaList(title: "Matched", ideas: detail.attempt.matchedIdeas, color: .teal)
            }
        }
        .padding(12)
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(resultTitle). \(detail.question.topicTitle). \(detail.question.subtopicTitle). \(detail.question.prompt)")
    }

    private func answerLine(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Text(text)
                .font(.caption)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func ideaList(title: String, ideas: [String], color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(color)

            ForEach(ideas, id: \.self) { idea in
                Text(idea)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var meaningfulFeedback: String? {
        let feedback = detail.attempt.feedback?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return feedback.isEmpty ? nil : feedback
    }

    private var scoreText: String {
        "\(Int((detail.attempt.score * 100).rounded()))%"
    }

    private var resultTitle: String {
        switch detail.attempt.score {
        case 0.75...:
            "Got it"
        case 0.45..<0.75:
            "Close"
        default:
            "Review"
        }
    }

    private var resultColor: Color {
        switch detail.attempt.score {
        case 0.75...:
            .teal
        case 0.45..<0.75:
            .orange
        default:
            .secondary
        }
    }
}

private extension QuizHistoryEntry {
    var percentText: String {
        "\(Int((score * 100).rounded()))%"
    }
}
