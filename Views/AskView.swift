import SwiftUI

struct AskView: View {
    @EnvironmentObject private var assistant: TutorEngine
    @Binding var draftPrompt: String
    let onAddNotes: () -> Void

    @State private var activeQuestion: LearningQuestion?
    @State private var activeAssignment: JourneyAssignment?
    @State private var answerText = ""
    @State private var selectedSourceID: UUID?
    @State private var isCheckingAnswer = false
    @State private var quizSession: QuizSession?
    @State private var quizReview: QuizReview?

    private let questionAnchorID = "active-question-anchor"
    private let topAnchorID = "ask-top-anchor"

    private var selectedNode: LearningCoverageNode {
        assistant.coverageNode(for: selectedSource)
    }

    private var selectedSource: StudySource? {
        if let selectedSourceID,
           let source = assistant.sources.first(where: { $0.id == selectedSourceID }) {
            return source
        }

        return assistant.sources.first
    }

    private var hasProcessingNotes: Bool {
        assistant.sources.contains { $0.status == .processing }
    }

    private var quizProgressText: String? {
        quizSession?.progressText
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Color.clear
                        .frame(height: 0)
                        .id(topAnchorID)

                    AppHeader(
                        title: "Accordian",
                        subtitle: "Learn from your notes."
                    )

                    if assistant.sources.isEmpty {
                        EmptyInlineState(
                            title: "Add notes first",
                            detail: "Paste notes or a lecture transcript. Accordian will turn them into a local learning map.",
                            systemImage: "doc.text",
                            actionTitle: "Add Notes",
                            action: onAddNotes
                        )
                    } else {
                        NoteStackSelector(
                            sources: assistant.sources,
                            selectedSourceID: selectedSource?.id,
                            onSelect: selectSource
                        )

                        CompactLearningStatus(
                            node: selectedNode,
                            sourceID: selectedSource?.id,
                            isBuildingJourney: hasProcessingNotes,
                            modelReadiness: assistant.modelReadiness,
                            quizReview: quizReview,
                            quizEvidence: assistant.quizProgressEvidence(for: selectedSource)
                        )

                        if activeQuestion == nil {
                            Button(action: startQuiz) {
                                Label("Start Quiz", systemImage: "play.circle")
                                    .font(.headline)
                                    .frame(maxWidth: .infinity, minHeight: 48)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.teal)
                        }

                        if let activeQuestion {
                            InlineQuestionView(
                                question: activeQuestion,
                                answerText: $answerText,
                                progressText: quizProgressText,
                                isChecking: isCheckingAnswer,
                                onChoose: { choice in
                                    submitAnswer(choice)
                                },
                                onSubmit: {
                                    submitAnswer(answerText)
                                }
                            )
                            .id(questionAnchorID)
                        }

                        if let quizReview, activeQuestion == nil {
                            QuizReviewView(review: quizReview)
                        }
                    }
                }
                .padding(16)
                .padding(.bottom, 140)
            }
            .background(WavesTheme.background)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: onAddNotes) {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add Notes")
                }
            }
            .onChange(of: activeQuestion) {
                guard activeQuestion != nil else { return }
                withAnimation(.snappy) {
                    proxy.scrollTo(questionAnchorID, anchor: .top)
                }
            }
            .onChange(of: quizReview?.id) {
                guard quizReview != nil else { return }
                withAnimation(.snappy) {
                    proxy.scrollTo(topAnchorID, anchor: .top)
                }
            }
            .onChange(of: draftPrompt) {
                applyDraftPromptIfNeeded()
            }
            .onAppear {
                selectedSourceID = selectedSource?.id
                applyDraftPromptIfNeeded()
            }
        }
    }

    private func continueJourney() {
        let step = assistant.nextJourneyStep(for: selectedSource)
        setActiveStep(step)
    }

    private func startQuiz() {
        let quizQuestions = assistant.buildQuiz(for: selectedSource)
        guard quizQuestions.isEmpty == false else { return }

        let session = QuizSession(
            sourceID: selectedSource?.id,
            questions: quizQuestions,
            baseline: selectedNode.snapshot
        )
        quizSession = session
        quizReview = nil
        activeAssignment = nil
        activeQuestion = session.currentQuestion
        answerText = ""
        isCheckingAnswer = false
    }

    private func continueJourney(after question: LearningQuestion) {
        let step = assistant.nextJourneyStep(for: selectedSource, excluding: question.id)
        setActiveStep(step)
    }

    private func setActiveStep(_ step: (assignment: JourneyAssignment?, question: LearningQuestion?)) {
        activeAssignment = step.assignment
        activeQuestion = step.question
        answerText = ""
        isCheckingAnswer = false
    }

    private func selectSource(_ source: StudySource) {
        selectedSourceID = source.id
        activeQuestion = nil
        activeAssignment = nil
        answerText = ""
        isCheckingAnswer = false
        quizSession = nil
        quizReview = nil
    }

    private func submitAnswer(_ response: String) {
        guard let activeQuestion, isCheckingAnswer == false else { return }

        answerText = response
        isCheckingAnswer = true

        Task {
            let attempt = await assistant.answerJourneyQuestion(activeQuestion, assignment: activeAssignment, response: response)
            advanceQuiz(after: activeQuestion, attempt: attempt)
        }
    }

    private func advanceQuiz(after question: LearningQuestion, attempt: QuestionAttempt) {
        guard var session = quizSession else {
            continueJourney(after: question)
            return
        }

        session.record(question: question, attempt: attempt)

        if let nextQuestion = session.advance() {
            quizSession = session
            activeQuestion = nextQuestion
            answerText = ""
            isCheckingAnswer = false
        } else {
            let finalSnapshot = assistant.coverageNode(for: selectedSource).snapshot
            let review = QuizReview(
                sourceID: session.sourceID,
                title: selectedSource?.title ?? selectedNode.title,
                baseline: session.baseline,
                final: finalSnapshot,
                answered: session.answered
            )
            assistant.saveQuizHistory(review.historyEntry)
            quizSession = nil
            quizReview = review
            activeQuestion = nil
            activeAssignment = nil
            answerText = ""
            isCheckingAnswer = false
        }
    }

    private func applyDraftPromptIfNeeded() {
        let text = draftPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.isEmpty == false else { return }

        draftPrompt = ""
        Task {
            _ = await assistant.submit(text, displayedAs: "Explain: \(selectedNode.title)")
        }
    }

}

private struct QuizSession {
    let sourceID: UUID?
    let questions: [LearningQuestion]
    let baseline: MasterySnapshot
    var index = 0
    var answered: [QuizAnsweredQuestion] = []

    var currentQuestion: LearningQuestion? {
        guard questions.indices.contains(index) else { return nil }
        return questions[index]
    }

    var progressText: String {
        "\(min(index + 1, questions.count)) of \(questions.count)"
    }

    mutating func record(question: LearningQuestion, attempt: QuestionAttempt) {
        answered.append(QuizAnsweredQuestion(question: question, attempt: attempt))
    }

    mutating func advance() -> LearningQuestion? {
        index += 1
        return currentQuestion
    }
}

private struct QuizAnsweredQuestion: Identifiable {
    let id = UUID()
    let question: LearningQuestion
    let attempt: QuestionAttempt
}

private struct QuizReview {
    let id = UUID()
    let sourceID: UUID?
    let title: String
    let baseline: MasterySnapshot
    let final: MasterySnapshot
    let answered: [QuizAnsweredQuestion]

    var growth: Double {
        final.weightedMastery - baseline.weightedMastery
    }

    var gotCount: Int {
        answered.filter { $0.attempt.score >= 0.75 }.count
    }

    var closeCount: Int {
        answered.filter { 0.45..<0.75 ~= $0.attempt.score }.count
    }

    var reviewCount: Int {
        answered.filter { $0.attempt.score < 0.45 }.count
    }

    var quizScore: Double {
        guard answered.isEmpty == false else { return 0 }
        let earned = answered.reduce(0.0) { total, item in
            total + item.attempt.score * item.question.type.weight * item.question.importance * item.question.difficulty
        }
        let possible = answered.reduce(0.0) { total, item in
            total + item.question.type.weight * item.question.importance * item.question.difficulty
        }
        return possible == 0 ? 0 : earned / possible
    }

    var historyEntry: QuizHistoryEntry {
        QuizHistoryEntry(
            sourceID: sourceID,
            title: title,
            score: quizScore,
            questionCount: answered.count,
            gotCount: gotCount,
            closeCount: closeCount,
            reviewCount: reviewCount
        )
    }
}

private struct NoteStackSelector: View {
    let sources: [StudySource]
    let selectedSourceID: UUID?
    let onSelect: (StudySource) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(sources) { source in
                    Button {
                        onSelect(source)
                    } label: {
                        Text(source.title)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .foregroundStyle(source.id == selectedSourceID ? .white : .primary)
                            .background(
                                source.id == selectedSourceID ? Color.teal : Color(.systemBackground),
                                in: Capsule()
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 2)
        }
        .accessibilityLabel("Note stacks")
    }
}

private struct CompactLearningStatus: View {
    let node: LearningCoverageNode
    let sourceID: UUID?
    let isBuildingJourney: Bool
    let modelReadiness: ModelReadiness
    let quizReview: QuizReview?
    let quizEvidence: QuizProgressEvidence

    @State private var showsDetails = false

    private var completedChecks: Int {
        node.snapshot.testedCount
    }

    var body: some View {
        Button {
            withAnimation(.snappy) {
                showsDetails.toggle()
            }
        } label: {
            VStack(alignment: .leading, spacing: 14) {
                if showsDetails {
                    journeyDetails
                } else {
                    journeySummary
                }

                if isBuildingJourney {
                    Label(processingTitle, systemImage: processingIcon)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .padding(14)
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 8))
    }

    private var headline: String {
        if node.snapshot.totalCount == 0 {
            return "Building understanding"
        }

        if node.snapshot.weightedMastery >= 0.995 {
            return "Understood"
        }

        return "Understanding"
    }

    private var processingTitle: String {
        modelReadiness.isReady ? "Building your journey" : "Waiting for Gemma"
    }

    private var processingIcon: String {
        modelReadiness.isReady ? "wand.and.stars" : "hourglass"
    }

    private var journeySummary: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(node.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(headline)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(node.snapshot.weightedMastery >= 0.995 ? .green : .primary)

                Text(growthHeadline)
                    .font(.caption)
                    .foregroundStyle(growthColor)
            }

            QuizHistoryChart(evidence: quizEvidence)

            HStack {
                Text(historyEvidenceText)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)

                Spacer()

                Text("Details")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.teal)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(node.title). \(headline). \(completedChecks) checks saved.")
    }

    private var growthHeadline: String {
        if let latest = quizEvidence.latest, let previous = quizEvidence.previous {
            return "\(previous.percentText) → \(latest.percentText)"
        }

        if let latest = quizEvidence.latest {
            return "Latest quiz \(latest.percentText)"
        }

        switch quizEvidence.direction {
        case .rising: "Growth is rising"
        case .steady: "Growth is steady"
        case .slipping: "Needs a few reps"
        case .waiting: "No quiz history yet"
        }
    }

    private var growthColor: Color {
        switch quizEvidence.direction {
        case .rising:
            .teal
        case .steady, .waiting:
            .secondary
        case .slipping:
            .orange
        }
    }

    private var historyEvidenceText: String {
        guard let latest = quizEvidence.latest else {
            return "Finish a quiz to start history."
        }

        guard let previous = quizEvidence.previous else {
            return "Finish another quiz to compare."
        }

        let pointChange = Int(((latest.score - previous.score) * 100).rounded())
        if pointChange > 0 {
            return "Up \(pointChange) points from previous quiz."
        }
        if pointChange < 0 {
            return "Down \(abs(pointChange)) points from previous quiz."
        }
        return "Same score as previous quiz."
    }

    private var journeyDetails: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(node.title)
                    .font(.headline)
                    .lineLimit(1)

                Spacer()

                Text("Close")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.teal)
            }

            VStack(alignment: .leading, spacing: 8) {
                DetailRow(title: "Checked", value: "\(completedChecks)/\(node.snapshot.totalCount)")
                DetailRow(title: "Understanding", value: headline)
                ForEach(node.snapshot.dimensions) { dimension in
                    DimensionDetailRow(dimension: dimension)
                }
            }
        }
    }
}

private struct QuizHistoryChart: View {
    let evidence: QuizProgressEvidence

    private var chartPoints: [Double] {
        if evidence.points.isEmpty {
            return [0.08, 0.08]
        }
        if evidence.points.count == 1, let score = evidence.points.first {
            return [score, score]
        }
        return evidence.points
    }

    private var lineColor: Color {
        switch evidence.direction {
        case .rising:
            .teal
        case .slipping:
            .orange
        case .steady, .waiting:
            .secondary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
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
            .frame(height: 74)

            HStack(spacing: 8) {
                EvidencePill(title: "Previous", value: evidence.previous?.percentText ?? "--", color: .secondary)
                EvidencePill(title: "Latest", value: evidence.latest?.percentText ?? "--", color: lineColor)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Quiz history line")
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

private struct EvidencePill: View {
    let title: String
    let value: String
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            Text(value)
                .font(.caption.weight(.semibold))
            Text(title)
                .font(.caption2.weight(.medium))
        }
        .foregroundStyle(color)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 7)
        .background(color.opacity(0.1), in: Capsule())
    }
}

private extension QuizHistoryEntry {
    var percentText: String {
        "\(Int((score * 100).rounded()))%"
    }
}

private struct DetailRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.semibold)
        }
        .font(.subheadline)
    }
}

private struct DimensionDetailRow: View {
    let dimension: UnderstandingDimension

    var body: some View {
        HStack(spacing: 10) {
            Text(dimension.title)
                .foregroundStyle(.secondary)
                .frame(width: 86, alignment: .leading)

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color(.secondarySystemBackground))

                    Circle()
                        .fill(Color.teal)
                        .frame(width: 9, height: 9)
                        .offset(x: max(0, (proxy.size.width - 9) * dimension.value))
                }
            }
            .frame(height: 9)
        }
        .font(.caption)
    }
}

private struct QuizReviewView: View {
    let review: QuizReview

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Quiz Complete")
                    .font(.title2.weight(.semibold))

                Text(review.growth > 0 ? "Your understanding moved forward." : "Saved. The next quiz will adapt.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                ReviewStat(title: "Got it", value: "\(review.gotCount)", color: .teal)
                ReviewStat(title: "Close", value: "\(review.closeCount)", color: .orange)
                ReviewStat(title: "Review", value: "\(review.reviewCount)", color: .secondary)
            }

            VStack(alignment: .leading, spacing: 10) {
                ForEach(review.answered) { item in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(resultTitle(for: item.attempt.score))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(resultColor(for: item.attempt.score))

                            Spacer()

                            Text(item.question.subtopicTitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Text(item.question.prompt)
                            .font(.subheadline.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true)

                        Text("You: \(item.attempt.response)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)

                        Text("Answer: \(item.question.answer)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                    .padding(10)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .padding(14)
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 8))
    }

    private func resultTitle(for score: Double) -> String {
        switch score {
        case 0.75...:
            "Got it"
        case 0.45..<0.75:
            "Close"
        default:
            "Review"
        }
    }

    private func resultColor(for score: Double) -> Color {
        switch score {
        case 0.75...:
            .teal
        case 0.45..<0.75:
            .orange
        default:
            .secondary
        }
    }
}

private struct ReviewStat: View {
    let title: String
    let value: String
    let color: Color

    var body: some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.headline.weight(.semibold))
                .foregroundStyle(color)

            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct InlineQuestionView: View {
    let question: LearningQuestion
    @Binding var answerText: String
    let progressText: String?
    let isChecking: Bool
    let onChoose: (String) -> Void
    let onSubmit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(question.type.title, systemImage: "checklist")
                    .font(.headline)

                Spacer()

                if let progressText {
                    Text(progressText)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }

                Text(question.subtopicTitle)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Text(question.prompt)
                .font(.title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)

            if question.type == .multipleChoice {
                VStack(spacing: 8) {
                    ForEach(question.choices, id: \.self) { choice in
                        Button {
                            onChoose(choice)
                        } label: {
                            Text(choice)
                                .font(.subheadline)
                                .foregroundStyle(.primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                                .background(choiceBackground(for: choice), in: RoundedRectangle(cornerRadius: 8))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(choiceBorder(for: choice), lineWidth: choice == answerText ? 1 : 0)
                                }
                        }
                        .buttonStyle(.plain)
                        .disabled(isChecking)
                    }
                }
            } else {
                TextField("Type your answer", text: $answerText, axis: .vertical)
                    .lineLimit(2...5)
                    .padding(12)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
                    .disabled(isChecking)

                Button(action: onSubmit) {
                    if isChecking {
                        Label("Saving", systemImage: "sparkles")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    } else {
                        Label("Continue", systemImage: "arrow.right.circle")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.teal)
                .disabled(answerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isChecking)
            }
        }
        .padding(14)
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 8))
    }

    private func choiceBackground(for choice: String) -> Color {
        choice == answerText ? Color.teal.opacity(0.16) : Color(.secondarySystemBackground)
    }

    private func choiceBorder(for choice: String) -> Color {
        choice == answerText ? Color.teal.opacity(0.4) : .clear
    }
}
