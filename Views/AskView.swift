import SwiftUI

struct AskView: View {
    @EnvironmentObject private var assistant: TutorEngine
    @Binding var draftPrompt: String
    let onAddNotes: () -> Void
    let onOpenSettings: () -> Void

    @State private var activeQuestion: LearningQuestion?
    @State private var activeAssignment: JourneyAssignment?
    @State private var answerText = ""
    @State private var selectedSourceID: UUID?
    @State private var isCheckingAnswer = false
    @State private var quizSession: QuizSession?
    @State private var quizReview: QuizReview?
    @State private var selectedQuizFocus: String?
    @State private var quizSeed = UUID()

    private var screenMode: AskScreenMode {
        if isCheckingAnswer, quizSession != nil {
            return .quizGrading
        }

        if quizReview != nil {
            return .grading
        }

        if activeQuestion != nil {
            return .quiz
        }

        return .home
    }

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
        selectedSource?.quizBuildState == .building
            || assistant.isPreparingNextQuiz(for: selectedSource?.id)
    }

    private var learningPhase: LearningInterfacePhase {
        guard selectedSource != nil else { return .empty }

        if selectedNode.snapshot.totalCount > 0 {
            return hasProcessingNotes ? .quizReadyBuildingMore : .quizReady
        }

        return switch selectedSource?.quizBuildState {
        case .building:
            if assistant.modelReadiness.isReady == false {
                .waitingForModel
            } else if assistant.recentQuizHistory(for: selectedSource, limit: 1).isEmpty == false {
                .rebuildingQuiz
            } else {
                .creatingFirstQuiz
            }
        case .failed:
            assistant.modelReadiness.isReady ? .processingFailed : .waitingForModel
        case .partial, .ready:
            selectedNode.snapshot.totalCount == 0 ? .creatingFirstQuiz : .quizReady
        case .idle:
            .noQuestions
        case nil:
            .empty
        }
    }

    private var canStartQuiz: Bool {
        return assistant.hasAvailableQuizQuestions(for: selectedSource, focusSubtopic: selectedQuizFocus)
    }

    private var availableQuizQuestionCount: Int {
        assistant.availableQuizQuestionCount(for: selectedSource, focusSubtopic: selectedQuizFocus)
    }

    private var quizButtonTitle: String {
        if selectedNode.snapshot.totalCount > 0 {
            if canStartQuiz {
                if availableQuizQuestionCount < assistant.minimumReadyQuizQuestionCount {
                    return "Start Review"
                }
                return "Start Quiz"
            }
            return assistant.modelReadiness.isReady ? "Creating Questions" : "Connect Model"
        }

        return switch selectedSource?.quizBuildState {
        case .building:
            learningPhase == .rebuildingQuiz ? "Rebuilding Quiz" : "Creating First Quiz"
        case .failed:
            assistant.modelReadiness.isReady ? "Try Again" : "Connect Model"
        case .partial, .ready:
            selectedNode.snapshot.totalCount == 0 ? "No Questions Yet" : "Start Quiz"
        case .idle:
            "No Questions Yet"
        case nil:
            "Add Notes"
        }
    }

    private var quizButtonIcon: String {
        if selectedNode.snapshot.totalCount > 0,
           canStartQuiz == false,
           assistant.modelReadiness.isReady == false {
            return "bolt.slash"
        }

        return switch selectedSource?.quizBuildState {
        case .building:
            "hourglass"
        case .failed:
            "exclamationmark.triangle"
        default:
            "play.circle"
        }
    }

    private var quizProgressText: String? {
        quizSession?.progressText
    }

    private var quizContextTitle: String {
        if let selectedQuizFocus, selectedQuizFocus.isEmpty == false {
            return shortQuizContext(selectedQuizFocus)
        }

        if let activeQuestion {
            return shortQuizContext(activeQuestion.subtopicTitle)
        }

        if let selectedSource {
            return shortQuizContext(selectedSource.title)
        }

        return shortQuizContext(selectedNode.title)
    }

    private var quizFocusOptions: [String] {
        assistant.quizFocusOptions(for: selectedSource)
    }

    var body: some View {
        Group {
            switch screenMode {
            case .home:
                homeContent
            case .quiz:
                quizContent
            case .quizGrading:
                quizGradingContent
            case .grading:
                gradingContent
            }
        }
        .background(QuizLoopTheme.background)
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(screenMode == .home ? .visible : .hidden, for: .tabBar)
        .onChange(of: quizReview?.id) {
            guard quizReview != nil else { return }
            prepareNextQuizIfNeeded()
        }
        .onChange(of: selectedSourceID) {
            prepareNextQuizIfNeeded()
        }
        .onChange(of: selectedQuizFocus) {
            prepareNextQuizIfNeeded()
        }
        .onChange(of: assistant.modelReadiness) {
            prepareNextQuizIfNeeded()
        }
        .onChange(of: draftPrompt) {
            applyDraftPromptIfNeeded()
        }
        .onAppear {
            selectedSourceID = selectedSource?.id
            applyDraftPromptIfNeeded()
            prepareNextQuizIfNeeded()
            Task {
                try? await Task.sleep(for: .seconds(1))
                prepareNextQuizIfNeeded()
            }
        }
    }

    private var homeContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                AppHeader(
                    title: "QuizLoop.ai",
                    subtitle: "One note. One quiz journey."
                )

                if assistant.sources.isEmpty {
                    EmptyInlineState(
                        title: "Add your first note",
                        detail: "Paste text or import a source. QuizLoop.ai uses Gemma to build a local quiz bank and SQLite to remember every attempt.",
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
                        phase: learningPhase,
                        canStartQuiz: canStartQuiz,
                        availableQuizQuestionCount: availableQuizQuestionCount,
                        minimumQuizQuestionCount: assistant.minimumReadyQuizQuestionCount,
                        modelReadiness: assistant.modelReadiness,
                        buildProgress: assistant.quizBuildProgress(for: selectedSource),
                        quizReview: quizReview,
                        quizEvidence: assistant.quizProgressEvidence(for: selectedSource)
                    )

                    if canStartQuiz {
                        QuizSetupControls(
                            options: quizFocusOptions,
                            selectedFocus: $selectedQuizFocus,
                            onShuffle: {
                                quizSeed = UUID()
                                quizReview = nil
                            }
                        )
                    }

                    Button(action: primaryAction) {
                        Label(quizButtonTitle, systemImage: quizButtonIcon)
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 50)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.teal)
                    .disabled(primaryActionEnabled == false)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 0)
            .padding(.bottom, 140)
        }
    }

    private var quizContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            QuizTopBar(
                title: quizContextTitle,
                progressText: quizProgressText
            )
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 10)

            if let activeQuestion {
                ScrollView {
                    InlineQuestionView(
                        question: activeQuestion,
                        answerText: $answerText,
                        progressText: nil,
                        isChecking: isCheckingAnswer,
                        presentation: .fullScreen,
                        onChoose: { choice in
                            submitAnswer(choice)
                        },
                        onSubmit: {
                            submitAnswer(answerText)
                        }
                    )
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .padding(.bottom, 36)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var quizGradingContent: some View {
        QuizGradingScreen(title: quizContextTitle)
    }

    private var gradingContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let quizReview {
                    QuizReviewView(
                        review: quizReview,
                        isPreparingNextQuiz: assistant.isPreparingNextQuiz(for: quizReview.sourceID),
                        onDone: {
                            self.quizReview = nil
                        }
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 42)
        }
    }

    private func prepareNextQuizIfNeeded() {
        guard let selectedSourceID else { return }
        let source = assistant.sources.first { $0.id == selectedSourceID }
        assistant.prepareNextQuizIfNeeded(for: source, focusSubtopic: selectedQuizFocus)
    }

    private func continueJourney() {
        let step = assistant.nextJourneyStep(for: selectedSource)
        setActiveStep(step)
    }

    private var primaryActionEnabled: Bool {
        if canStartQuiz { return true }
        if assistant.modelReadiness.isReady == false { return true }
        return learningPhase == .processingFailed
    }

    private func primaryAction() {
        if canStartQuiz {
            startQuiz()
            return
        }

        if assistant.modelReadiness.isReady == false {
            onOpenSettings()
            return
        }

        guard learningPhase == .processingFailed, let selectedSource else { return }
        Task {
            await assistant.retryProcessing(selectedSource)
        }
    }

    private func startQuiz() {
        guard canStartQuiz else { return }
        let sessionSeed = quizSeed
        quizSeed = UUID()
        let quizSelections = assistant.buildQuizSelections(
            for: selectedSource,
            focusSubtopic: selectedQuizFocus,
            seed: sessionSeed
        )
        guard quizSelections.isEmpty == false else { return }

        let session = QuizSession(
            sourceID: selectedSource?.id,
            selections: quizSelections,
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
        selectedQuizFocus = nil
        quizSeed = UUID()
    }

    private func submitAnswer(_ response: String) {
        guard let question = activeQuestion, isCheckingAnswer == false else { return }

        answerText = response

        guard var session = quizSession else {
            isCheckingAnswer = true
            Task {
                let attempt = await assistant.answerJourneyQuestion(question, assignment: activeAssignment, response: response)
                advanceJourney(after: question, attempt: attempt)
            }
            return
        }

        session.record(question: question, response: response)

        if let nextQuestion = session.advance() {
            quizSession = session
            activeQuestion = nextQuestion
            answerText = ""
            isCheckingAnswer = false
        } else {
            finishQuiz(session)
        }
    }

    private func advanceJourney(after question: LearningQuestion, attempt: QuestionAttempt) {
        _ = attempt
        continueJourney(after: question)
    }

    private func finishQuiz(_ session: QuizSession) {
        isCheckingAnswer = true

        Task {
            let attempts = await assistant.gradeQuizAnswers(session.submissions)
            let finalSnapshot = assistant.coverageNode(for: selectedSource).snapshot
            let answered = zip(session.submissions, attempts).map { submission, attempt in
                QuizAnsweredQuestion(
                    question: submission.question,
                    attempt: attempt,
                    selectionReason: submission.selectionReason
                )
            }
            let review = QuizReview(
                sourceID: session.sourceID,
                title: quizContextTitle,
                baseline: session.baseline,
                final: finalSnapshot,
                answered: answered,
                previousQuizScore: assistant.recentQuizHistory(for: selectedSource, limit: 1).first?.score
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

    private func shortQuizContext(_ text: String) -> String {
        let cleaned = text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count > 34 else { return cleaned.isEmpty ? "All" : cleaned }

        let separators = CharacterSet(charactersIn: ":-–—(|")
        if let firstBreak = cleaned.rangeOfCharacter(from: separators),
           cleaned.distance(from: cleaned.startIndex, to: firstBreak.lowerBound) >= 8 {
            let prefix = String(cleaned[..<firstBreak.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            if prefix.count <= 34 {
                return prefix
            }
        }

        let words = cleaned.split(separator: " ")
        var result = ""
        for word in words {
            let candidate = result.isEmpty ? String(word) : "\(result) \(word)"
            guard candidate.count <= 34 else { break }
            result = candidate
        }

        return result.isEmpty ? String(cleaned.prefix(34)) : result
    }

}

private enum LearningInterfacePhase: Equatable {
    case empty
    case creatingFirstQuiz
    case rebuildingQuiz
    case waitingForModel
    case processingFailed
    case noQuestions
    case quizReady
    case quizReadyBuildingMore
}

private enum AskScreenMode {
    case home
    case quiz
    case quizGrading
    case grading
}

private struct QuizSession {
    let sourceID: UUID?
    let selections: [QuizQuestionSelection]
    let baseline: MasterySnapshot
    var index = 0
    var submissions: [QuizAnswerSubmission] = []

    var currentQuestion: LearningQuestion? {
        currentSelection?.question
    }

    var currentSelection: QuizQuestionSelection? {
        guard selections.indices.contains(index) else { return nil }
        return selections[index]
    }

    var progressText: String {
        "\(min(index + 1, selections.count)) of \(selections.count)"
    }

    mutating func record(question: LearningQuestion, response: String) {
        let reason = currentSelection?.reason ?? ""
        submissions.append(QuizAnswerSubmission(question: question, response: response, selectionReason: reason))
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
    let selectionReason: String
}

private struct QuizReview {
    let id = UUID()
    let sourceID: UUID?
    let title: String
    let baseline: MasterySnapshot
    let final: MasterySnapshot
    let answered: [QuizAnsweredQuestion]
    let previousQuizScore: Double?

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

    var quizDelta: Double? {
        guard let previousQuizScore else { return nil }
        return quizScore - previousQuizScore
    }

    var gradeMessage: String {
        guard let quizDelta else {
            return "First grade saved. The next quiz will adapt."
        }

        if quizDelta > 0.005 {
            return "Your quiz grade improved."
        }

        if quizDelta < -0.005 {
            return "Your quiz grade dipped. The next quiz will adapt."
        }

        return "Same grade as your last quiz. The next quiz will adapt."
    }

    var historyEntry: QuizHistoryEntry {
        QuizHistoryEntry(
            sourceID: sourceID,
            title: title,
            score: quizScore,
            questionCount: answered.count,
            gotCount: gotCount,
            closeCount: closeCount,
            reviewCount: reviewCount,
            attemptIDs: answered.map(\.attempt.id)
        )
    }
}

private struct QuizSetupControls: View {
    let options: [String]
    @Binding var selectedFocus: String?
    let onShuffle: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Menu {
                Button("All") {
                    selectedFocus = nil
                }

                ForEach(options, id: \.self) { option in
                    Button(option) {
                        selectedFocus = option
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "scope")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.teal)

                    VStack(alignment: .leading, spacing: 1) {
                        Text("Focus")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)

                        Text(selectedFocus ?? "All")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }

                    Spacer(minLength: 6)

                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)

            Button(action: onShuffle) {
                Image(systemName: "shuffle")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.teal)
                    .frame(width: 48, height: 48)
                    .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Shuffle quiz")
        }
        .frame(maxWidth: .infinity)
    }
}

private struct QuizTopBar: View {
    let title: String
    let progressText: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Quiz")
                    .font(.largeTitle.weight(.semibold))

                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .layoutPriority(1)

            Spacer(minLength: 8)

            if let progressText {
                Text(progressText)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.teal)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.teal.opacity(0.1), in: Capsule())
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct QuizGradingScreen: View {
    let title: String

    var body: some View {
        VStack(spacing: 18) {
            Spacer()

            ProgressView()
                .controlSize(.large)
                .tint(.teal)

            VStack(spacing: 6) {
                Text("Grading")
                    .font(.largeTitle.weight(.semibold))

                Text("Gemma is checking your answers against \(title).")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 28)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Grading. Gemma is checking your answers.")
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
                        NoteStackChip(source: source, isSelected: source.id == selectedSourceID)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 2)
        }
        .accessibilityLabel("Note stacks")
    }
}

private struct NoteStackChip: View {
    @EnvironmentObject private var assistant: TutorEngine
    let source: StudySource
    let isSelected: Bool

    private var buildProgress: QuizBuildProgress? {
        assistant.quizBuildProgress(for: source)
    }

    private var hasQuestionsReady: Bool {
        assistant.availableQuizQuestionCount(for: source) > 0
    }

    private var isBuilding: Bool {
        buildProgress != nil
            || source.quizBuildState == .building
            || assistant.isPreparingNextQuiz(for: source.id)
    }

    private var isFailed: Bool {
        source.quizBuildState == .failed || source.status == .failed
    }

    private var progressValue: Double {
        guard let buildProgress else { return isBuilding ? 0.12 : 0 }
        return min(max(buildProgress.progress, 0), 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                statusMark

                Text(source.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .foregroundStyle(isSelected ? .white : .primary)
            }

            if isBuilding && hasQuestionsReady == false {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill((isSelected ? Color.white : Color.secondary).opacity(0.2))

                        Capsule()
                            .fill(isSelected ? Color.white : Color.teal)
                            .frame(width: max(6, proxy.size.width * progressValue))
                    }
                }
                .frame(height: 3)
                .accessibilityHidden(true)
            }
        }
        .frame(minWidth: 84, maxWidth: 170, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, isBuilding && hasQuestionsReady == false ? 8 : 9)
        .background(
            isSelected ? Color.teal : Color(.secondarySystemBackground),
            in: Capsule()
        )
        .overlay {
            Capsule()
                .stroke(Color(.separator).opacity(isSelected ? 0 : 0.35), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private var statusMark: some View {
        if hasQuestionsReady {
            Circle()
                .fill(isSelected ? Color.white : Color.teal)
                .frame(width: 7, height: 7)
        } else if isFailed {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(isSelected ? .white : .orange)
        } else if isBuilding && hasQuestionsReady == false {
            ProgressView()
                .controlSize(.mini)
                .tint(isSelected ? .white : .teal)
        } else {
            Circle()
                .fill(Color.secondary.opacity(0.45))
                .frame(width: 7, height: 7)
        }
    }

    private var accessibilityLabel: String {
        if hasQuestionsReady {
            return "\(source.title), quiz ready"
        }
        if isFailed {
            return "\(source.title), needs attention"
        }
        if isBuilding && hasQuestionsReady == false {
            return "\(source.title), building quiz, \(Int((progressValue * 100).rounded())) percent"
        }
        return "\(source.title), no quiz ready"
    }
}

private struct AgentToolStrip: View {
    let noteTitle: String
    let noteCount: Int
    let topicCount: Int
    let questionCount: Int
    let quizCount: Int
    let modelName: String
    let isModelReady: Bool

    private var tools: [AgentTool] {
        [
            AgentTool(
                title: "Input",
                value: "\(noteCount)",
                detail: "notes",
                systemImage: "doc.text",
                color: .blue
            ),
            AgentTool(
                title: "Map",
                value: "\(topicCount)",
                detail: "topics",
                systemImage: "point.3.connected.trianglepath.dotted",
                color: .purple
            ),
            AgentTool(
                title: "Test",
                value: "\(questionCount)",
                detail: "checks",
                systemImage: "checklist",
                color: .teal
            ),
            AgentTool(
                title: "Memory",
                value: "\(quizCount)",
                detail: "quizzes",
                systemImage: "internaldrive",
                color: .orange
            )
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Agent tools")
                        .font(.subheadline.weight(.semibold))

                    Text(toolSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 12)

                Label(modelStatusText, systemImage: isModelReady ? "bolt.fill" : "bolt.slash")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isModelReady ? .teal : .orange)
                    .labelStyle(.titleAndIcon)
            }

            HStack(spacing: 8) {
                ForEach(tools) { tool in
                    AgentToolTile(tool: tool)
                }
            }
        }
        .padding(10)
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Agent tools. \(toolSummary)")
    }

    private var modelStatusText: String {
        isModelReady ? modelName : "Model"
    }

    private var toolSummary: String {
        "Gemma builds and grades. SQLite remembers."
    }
}

private struct AgentTool: Identifiable {
    let id = UUID()
    let title: String
    let value: String
    let detail: String
    let systemImage: String
    let color: Color
}

private struct AgentToolTile: View {
    let tool: AgentTool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: tool.systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tool.color)
                .frame(width: 22, height: 22)
                .background(tool.color.opacity(0.1), in: Circle())

            VStack(alignment: .leading, spacing: 1) {
                Text(tool.title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(tool.value)
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()

                    Text(tool.detail)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(7)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct CompactLearningStatus: View {
    let node: LearningCoverageNode
    let sourceID: UUID?
    let phase: LearningInterfacePhase
    let canStartQuiz: Bool
    let availableQuizQuestionCount: Int
    let minimumQuizQuestionCount: Int
    let modelReadiness: ModelReadiness
    let buildProgress: QuizBuildProgress?
    let quizReview: QuizReview?
    let quizEvidence: QuizProgressEvidence

    private var completedChecks: Int {
        node.snapshot.testedCount
    }

    private var understandingPercentText: String {
        "\(Int((node.snapshot.weightedMastery * 100).rounded()))%"
    }

    private var shouldShowBlockingProgress: Bool {
        buildProgress != nil && canStartQuiz == false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            journeySummary

            if statusLine.isEmpty == false {
                Label(statusLine, systemImage: statusIcon)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(statusColor)
            }
        }
        .padding(14)
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 8))
    }

    private var headline: String {
        switch phase {
        case .empty:
            return "Add notes"
        case .creatingFirstQuiz:
            return "Creating first quiz"
        case .rebuildingQuiz:
            return "Updating quiz"
        case .waitingForModel:
            return "Connect model"
        case .processingFailed:
            return "Try again"
        case .noQuestions:
            return "No questions yet"
        case .quizReady, .quizReadyBuildingMore:
            if canStartQuiz == false {
                return modelReadiness.isReady ? "Creating questions" : "Connect model"
            }

            if availableQuizQuestionCount < minimumQuizQuestionCount,
               modelReadiness.isReady,
               completedChecks > 0 {
                return "Review ready"
            }

            if node.snapshot.weightedMastery >= 0.995 {
                return "Understood"
            }
            return node.snapshot.testedCount == 0 ? "Ready to start" : "In progress"
        }
    }

    private var subheadline: String {
        switch phase {
        case .empty:
            return "Paste notes to begin."
        case .creatingFirstQuiz:
            return "Gemma is reading this note. The first quiz appears as soon as it is saved."
        case .rebuildingQuiz:
            return "Your note was saved. Gemma is updating the quiz in the background."
        case .waitingForModel:
            return "Gemma is not ready for this note."
        case .processingFailed:
            return "Gemma could not finish this note last time. Try again to rebuild it."
        case .noQuestions:
            return "This note has not been turned into questions yet."
        case .quizReady:
            if canStartQuiz == false {
                if modelReadiness.isReady == false {
                return "You finished this quiz set. Connect Gemma to build the next one."
                }
                return buildingQuizSubheadline
            }
            if availableQuizQuestionCount < minimumQuizQuestionCount,
               modelReadiness.isReady,
               completedChecks > 0 {
                if buildProgress != nil {
                    return "Fresh questions are still building. You can review older questions now."
                }
                return "No fresh questions are ready. Review older questions now."
            }
            return node.snapshot.testedCount == 0 ? "Start with the next quiz." : "Keep going with the next quiz."
        case .quizReadyBuildingMore:
            if canStartQuiz == false {
                if modelReadiness.isReady == false {
                return "You finished this quiz set. Connect Gemma to build the next one."
                }
                return buildingQuizSubheadline
            }
            if availableQuizQuestionCount < minimumQuizQuestionCount,
               modelReadiness.isReady,
               completedChecks > 0 {
                if buildProgress != nil {
                    return "Fresh questions are still building. You can review older questions now."
                }
                return "No fresh questions are ready. Review older questions now."
            }
            return node.snapshot.testedCount == 0 ? "Start with the next quiz." : "Keep going with the next quiz."
        }
    }

    private var buildingQuizSubheadline: String {
        if completedChecks > 0, availableQuizQuestionCount < minimumQuizQuestionCount {
            return "Fresh questions are still building. Review is ready."
        }

        if availableQuizQuestionCount == 0 {
            return "You finished this quiz set. Making a new one from your note."
        }

        return "Preparing the next fresh quiz."
    }

    private var statusLine: String {
        switch phase {
        case .creatingFirstQuiz:
            return modelReadiness.isReady ? "Creating first quiz" : "Waiting for model"
        case .rebuildingQuiz:
            return "Updating quiz in background"
        case .quizReadyBuildingMore:
            return canStartQuiz ? "" : "Preparing more questions"
        case .waitingForModel:
            return "Model setup needed"
        case .processingFailed:
            return "Processing stopped"
        default:
            return ""
        }
    }

    private var statusIcon: String {
        switch phase {
        case .creatingFirstQuiz, .rebuildingQuiz:
            return "hourglass"
        case .quizReadyBuildingMore:
            return "wand.and.stars"
        case .waitingForModel:
            return "exclamationmark.triangle"
        case .processingFailed:
            return "arrow.clockwise"
        default:
            return "checkmark.circle"
        }
    }

    private var statusColor: Color {
        switch phase {
        case .waitingForModel, .processingFailed:
            return .orange
        case .creatingFirstQuiz, .rebuildingQuiz, .quizReadyBuildingMore:
            return .secondary
        default:
            return .teal
        }
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

                Text(subheadline)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if shouldShowBlockingProgress, let buildProgress {
                QuizBuildProgressView(progress: buildProgress)
            } else {
                UnderstandingSignal(snapshot: node.snapshot)
            }

            Text(historyEvidenceText)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(node.title). \(headline). \(subheadline)")
    }

    private var canShowHistory: Bool {
        node.snapshot.totalCount > 0 && quizEvidence.latest != nil
    }

    private var growthHeadline: String {
        if let latest = quizEvidence.latest, let previous = quizEvidence.previous {
            return "\(previous.percentText) → \(latest.percentText)"
        }

        if let latest = quizEvidence.latest {
            return "Latest quiz \(latest.percentText)"
        }

        switch quizEvidence.direction {
        case .rising:
            return "Growth is rising"
        case .steady:
            return "Growth is steady"
        case .slipping:
            return "Needs a few reps"
        case .waiting:
            return "No quiz history yet"
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
        if node.snapshot.totalCount > 0, quizEvidence.latest == nil {
            return "Take a quiz to start history."
        }

        if phase == .creatingFirstQuiz {
            return "You can leave this screen while Gemma works."
        }

        if phase == .rebuildingQuiz {
            return "You can keep using the app while this updates."
        }

        if phase == .waitingForModel {
            return "Open Settings to check the model."
        }

        if phase == .processingFailed {
            return "Tap Try Again to process this note with Gemma."
        }

        guard let latest = quizEvidence.latest else {
            return "Finish a quiz to start history."
        }

        guard let previous = quizEvidence.previous else {
            return "Finish another quiz to compare."
        }

        let pointChange = Int(((latest.score - previous.score) * 100).rounded())
        if pointChange > 0 {
            return "Understanding gained \(pointChange) points."
        }
        if pointChange < 0 {
            return "A new gap was found. The next check will rebuild it."
        }
        return "Understanding held steady."
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

private struct UnderstandingSignal: View {
    let snapshot: MasterySnapshot

    private var progressColor: Color {
        switch snapshot.weightedMastery {
        case 0.8...:
            .teal
        case 0.35..<0.8:
            .orange
        default:
            .secondary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .lastTextBaseline) {
                Text("\(Int((snapshot.weightedMastery * 100).rounded()))%")
                    .font(.system(size: 42, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(snapshot.weightedMastery >= 0.995 ? .green : progressColor)

                Text("understood")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Spacer(minLength: 0)
            }

            ProgressView(value: snapshot.weightedMastery)
                .tint(progressColor)

            Text("\(snapshot.testedCount) of \(snapshot.totalCount) questions have shaped this score.")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Understanding \(Int((snapshot.weightedMastery * 100).rounded())) percent")
    }
}

private struct PendingLearningVisual: View {
    let phase: LearningInterfacePhase

    private var progressValue: Double {
        switch phase {
        case .quizReady, .quizReadyBuildingMore:
            return 1
        case .creatingFirstQuiz, .rebuildingQuiz:
            return 0.35
        case .waitingForModel, .processingFailed:
            return 0.12
        default:
            return 0
        }
    }

    private var label: String {
        switch phase {
        case .creatingFirstQuiz:
            return "First quiz is being created"
        case .rebuildingQuiz:
            return "Quiz is updating"
        case .waitingForModel:
            return "Model needs attention"
        case .processingFailed:
            return "Try again to build this quiz"
        case .noQuestions:
            return "No questions saved"
        default:
            return "Ready"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ProgressView(value: progressValue)
                .tint((phase == .waitingForModel || phase == .processingFailed) ? .orange : .teal)

            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
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

private struct QuizHistoryRow: View {
    let entry: QuizHistoryEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(entry.percentText)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(scoreColor)

                Spacer()

                Text(entry.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            QuizHistorySignal(entry: entry)
        }
        .padding(10)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
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

private struct QuizHistorySignal: View {
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
        GeometryReader { proxy in
            HStack(spacing: 2) {
                signalSegment(width: proxy.size.width * gotShare, color: .teal)
                signalSegment(width: proxy.size.width * closeShare, color: .orange)
                signalSegment(width: proxy.size.width * reviewShare, color: .secondary)
            }
        }
        .frame(height: 10)
        .clipShape(Capsule())
        .background(Color(.systemBackground), in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Quiz result mix")
        .accessibilityValue("\(entry.gotCount) solid, \(entry.closeCount) close, \(entry.reviewCount) review")
    }

    private func signalSegment(width: CGFloat, color: Color) -> some View {
        Rectangle()
            .fill(color.opacity(0.82))
            .frame(width: max(width, 0))
    }
}

private struct QuizReviewView: View {
    let review: QuizReview
    let isPreparingNextQuiz: Bool
    let onDone: () -> Void
    @State private var showsResults = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if showsResults {
                resultsDetail
            } else {
                summary
            }
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 16) {
            gradeHeader

            ReviewBlocksSignal(review: review)

            if isPreparingNextQuiz {
                PreparingNextQuizSignal()
            }

            Button {
                onDone()
            } label: {
                Label("Back to Widget", systemImage: "rectangle.grid.1x2")
                    .font(.headline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 48)
            }
            .buttonStyle(.borderedProminent)
            .tint(.teal)

            Button {
                showsResults = true
            } label: {
                Label("View Results", systemImage: "list.bullet.clipboard")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 48)
            }
            .buttonStyle(.bordered)
        }
        .padding(16)
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 8))
    }

    private var resultsDetail: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Understanding Report")
                    .font(.title3.weight(.semibold))

                Spacer()

                Button {
                    showsResults = false
                } label: {
                    Text("Summary")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Text("Each answer updates the note map: what matched, what is missing, and which dimension needs another check.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(review.answered) { item in
                QuizResultCard(item: item)
            }

            Button {
                onDone()
            } label: {
                Label("Back to Widget", systemImage: "rectangle.grid.1x2")
                    .font(.headline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 48)
            }
            .buttonStyle(.borderedProminent)
            .tint(.teal)
        }
    }

    private var gradeHeader: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Check Result")
                    .font(.title2.weight(.semibold))

                Text(review.gradeMessage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            Text(gradeText)
                .font(.system(size: 44, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(gradeColor)
                .minimumScaleFactor(0.75)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Check result \(gradeText)")
    }

    private var gradeText: String {
        "\(Int((review.quizScore * 100).rounded()))%"
    }

    private var gradeColor: Color {
        switch review.quizScore {
        case 0.75...:
            .teal
        case 0.45..<0.75:
            .orange
        default:
            .secondary
        }
    }
}

private struct PreparingNextQuizSignal: View {
    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)

            Text("Preparing the next quiz")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Preparing the next quiz")
    }
}

private struct QuizResultCard: View {
    let item: QuizAnsweredQuestion

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(resultTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(resultColor)

                Spacer(minLength: 0)

                Text(item.question.subtopicTitle)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Text(scoreText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(resultColor)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(resultColor.opacity(0.1), in: Capsule())
            }

            Text(item.question.prompt)
                .font(.subheadline.weight(.semibold))
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)

            if shouldShowSelectionReason {
                Label(item.selectionReason, systemImage: "target")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                if shouldShowLearnerAnswer {
                    answerLine(title: "You", text: item.attempt.response, color: .secondary)
                }
                answerLine(title: "Answer", text: item.question.answer, color: resultColor)
            }

            if shouldShowInsight {
                VStack(alignment: .leading, spacing: 10) {
                    if let feedback = meaningfulFeedback {
                        Label(feedback, systemImage: "sparkles")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if shouldShowMatchedIdeas {
                        ideaList(
                            title: "Matched",
                            systemImage: "checkmark.circle.fill",
                            ideas: item.attempt.matchedIdeas,
                            color: .teal
                        )
                    }

                    if item.attempt.missingIdeas.isEmpty == false {
                        ideaList(
                            title: "Needs review",
                            systemImage: "exclamationmark.circle.fill",
                            ideas: item.attempt.missingIdeas,
                            color: .orange
                        )
                    }
                }
                .padding(9)
                .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(10)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(resultTitle). \(item.question.prompt). Your answer: \(item.attempt.response). Correct answer: \(item.question.answer)")
    }

    private var insightText: String {
        [
            item.attempt.feedback ?? "",
            item.attempt.matchedIdeas.joined(separator: " "),
            item.attempt.missingIdeas.joined(separator: " ")
        ]
        .joined(separator: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var shouldShowInsight: Bool {
        meaningfulFeedback != nil
            || item.attempt.missingIdeas.isEmpty == false
            || shouldShowMatchedIdeas
    }

    private var shouldShowMatchedIdeas: Bool {
        item.attempt.score < 0.75 && item.attempt.matchedIdeas.isEmpty == false
    }

    private var shouldShowSelectionReason: Bool {
        item.attempt.score < 0.75 && item.selectionReason.isEmpty == false
    }

    private var shouldShowLearnerAnswer: Bool {
        item.attempt.score < 0.75 || normalizedAnswerText(item.attempt.response) != normalizedAnswerText(item.question.answer)
    }

    private var meaningfulFeedback: String? {
        guard let feedback = item.attempt.feedback?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              feedback.isEmpty == false
        else {
            return nil
        }

        let normalized = feedback.lowercased()
        let genericCorrectFeedback: Set<String> = [
            "got it",
            "correct",
            "good answer",
            "nice work"
        ]

        if item.attempt.score >= 0.75,
           genericCorrectFeedback.contains(normalized) {
            return nil
        }

        return feedback
    }

    private func ideaList(title: String, systemImage: String, ideas: [String], color: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(color)

            ForEach(ideas, id: \.self) { idea in
                Text(idea)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func answerLine(title: String, text: String, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(color)
                .frame(width: 48, alignment: .leading)

            Text(text)
                .font(.caption)
                .foregroundStyle(.primary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func normalizedAnswerText(_ text: String) -> String {
        text
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.isEmpty == false }
            .joined(separator: " ")
    }

    private var scoreText: String {
        "\(Int((item.attempt.score * 100).rounded()))%"
    }

    private var resultTitle: String {
        switch item.attempt.score {
        case 0.75...:
            "Got it"
        case 0.45..<0.75:
            "Close"
        default:
            "Review"
        }
    }

    private var resultColor: Color {
        switch item.attempt.score {
        case 0.75...:
            .teal
        case 0.45..<0.75:
            .orange
        default:
            .secondary
        }
    }
}

private struct ReviewBlocksSignal: View {
    let review: QuizReview

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(signalTitle)
                    .font(.headline.weight(.semibold))

                Spacer()
            }

            HStack(spacing: 8) {
                resultBlock(title: "Got it", count: review.gotCount, color: .teal)
                resultBlock(title: "Close", count: review.closeCount, color: .orange)
                resultBlock(title: "Review", count: review.reviewCount, color: .secondary)
            }
        }
        .padding(12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Understanding result")
        .accessibilityValue(signalDetail)
    }

    private func resultBlock(title: String, count: Int, color: Color) -> some View {
        VStack(spacing: 5) {
            Text("\(count)")
                .font(.title3.weight(.semibold))
                .foregroundStyle(color)

            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity, minHeight: 74)
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(color.opacity(0.18), lineWidth: 1)
        }
    }

    private var signalTitle: String {
        switch review.quizScore {
        case 0.75...:
            "Strong session"
        case 0.45..<0.75:
            "Mixed session"
        default:
            "Review needed"
        }
    }

    private var signalDetail: String {
        if review.gotCount >= review.closeCount && review.gotCount >= review.reviewCount {
            return "Most answers were solid."
        }
        if review.closeCount >= review.reviewCount {
            return "Most answers were close."
        }
        return "This note needs another pass."
    }
}

private enum QuestionPresentation {
    case card
    case fullScreen
}

private struct InlineQuestionView: View {
    let question: LearningQuestion
    @Binding var answerText: String
    let progressText: String?
    let isChecking: Bool
    var presentation: QuestionPresentation = .card
    let onChoose: (String) -> Void
    let onSubmit: () -> Void
    @FocusState private var isAnswerFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: presentation == .fullScreen ? 18 : 14) {
            HStack(spacing: 8) {
                Image(systemName: "checklist")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 20)

                Text(checkTitle)
                    .font(.headline.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                    .layoutPriority(2)

                if let progressText {
                    Text(progressText)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.leading, 2)
                }

                Spacer(minLength: 0)
            }

            focusLabel

            Text(question.prompt)
                .font(presentation == .fullScreen ? .title2.weight(.semibold) : .title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)

            if isChecking {
                GradingStateView(
                    title: progressText == nil ? "Checking answer" : "Updating map",
                    response: answerText
                )
            } else if question.type == .multipleChoice {
                VStack(spacing: presentation == .fullScreen ? 10 : 8) {
                    ForEach(question.choices, id: \.self) { choice in
                        Button {
                            onChoose(choice)
                        } label: {
                            Text(choice)
                                .font(presentation == .fullScreen ? .headline : .subheadline)
                                .foregroundStyle(.primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(presentation == .fullScreen ? 16 : 12)
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
                    .id(question.id)
                    .focused($isAnswerFocused)
                    .autocorrectionDisabled(true)
                    .textInputAutocapitalization(.never)
                    .submitLabel(.done)
                    .onSubmit {
                        isAnswerFocused = false
                    }
                    .lineLimit(2...5)
                    .padding(presentation == .fullScreen ? 16 : 12)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
                    .disabled(isChecking)
                    .toolbar {
                        ToolbarItemGroup(placement: .keyboard) {
                            Spacer()
                            Button("Done") {
                                isAnswerFocused = false
                            }
                        }
                    }

                Button(action: submitWrittenAnswer) {
                    if isChecking {
                        Label(progressText == nil ? "Checking" : "Updating map", systemImage: "sparkles")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    } else {
                        Label("Continue", systemImage: "arrow.right.circle")
                            .frame(maxWidth: .infinity, minHeight: presentation == .fullScreen ? 50 : 44)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.teal)
                .disabled(answerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isChecking)
            }
        }
        .padding(presentation == .fullScreen ? 0 : 14)
        .background {
            if presentation == .card {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(.systemBackground))
            }
        }
    }

    private func submitWrittenAnswer() {
        guard answerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
              isChecking == false
        else { return }

        isAnswerFocused = false
        onSubmit()
    }

    private var focusLabel: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(question.topicTitle)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)

            if normalizedLabel(question.topicTitle) != normalizedLabel(question.subtopicTitle) {
                Text(question.subtopicTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(question.topicTitle), \(question.subtopicTitle)")
    }

    private func normalizedLabel(_ text: String) -> String {
        text
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var checkTitle: String {
        switch question.type {
        case .multipleChoice:
            "Multiple Choice"
        case .fillBlank:
            "Fill In"
        case .shortAnswer:
            "Short Answer"
        case .flashcard:
            "Review"
        }
    }

    private func choiceBackground(for choice: String) -> Color {
        if choice == answerText {
            return Color.teal.opacity(0.16)
        }

        return presentation == .fullScreen ? Color(.systemBackground) : Color(.secondarySystemBackground)
    }

    private func choiceBorder(for choice: String) -> Color {
        if choice == answerText {
            return Color.teal.opacity(0.4)
        }

        return presentation == .fullScreen ? Color(.separator).opacity(0.22) : .clear
    }
}

private struct GradingStateView: View {
    let title: String
    let response: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)

                Text(title)
                    .font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(.secondary)

            if response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Submitted")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    Text(response)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }
}
