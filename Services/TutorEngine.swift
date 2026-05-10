import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

@MainActor
final class TutorEngine: ObservableObject {
    @Published private(set) var turns: [TutorTurn]
    @Published private(set) var sources: [StudySource]
    @Published private(set) var topics: [LearningTopic]
    @Published private(set) var segments: [LearningSegment]
    @Published private(set) var questions: [LearningQuestion]
    @Published private(set) var attempts: [QuestionAttempt]
    @Published private(set) var assignments: [JourneyAssignment]
    @Published private(set) var flashcards: [StudyFlashcard]
    @Published private(set) var xpEvents: [XPEvent]
    @Published private(set) var suggestions: [LearningSuggestion]
    @Published private(set) var quizHistory: [QuizHistoryEntry]

    @Published private(set) var isResponding = false
    @Published private(set) var lastError: String?
    @Published private(set) var modelReadiness: ModelReadiness = .checking
    @Published private(set) var modelConfiguration: ModelRuntimeConfiguration

    private var gemmaService: GemmaService
    private let conversationStore: ConversationStore
    private let runtimeStore: ModelRuntimeStore

    init(
        conversationStore: ConversationStore = ConversationStore(),
        runtimeStore: ModelRuntimeStore = ModelRuntimeStore()
    ) {
        let loadedConfiguration = runtimeStore.load()
        self.conversationStore = conversationStore
        self.runtimeStore = runtimeStore
        self.modelConfiguration = loadedConfiguration
        self.gemmaService = Self.makeGemmaService(for: loadedConfiguration)

        let savedTurns = conversationStore.loadTurns()
        self.sources = conversationStore.loadSources()
        self.topics = conversationStore.loadTopics()
        self.segments = conversationStore.loadSegments()
        self.questions = conversationStore.loadQuestions()
        self.attempts = conversationStore.loadAttempts()
        self.assignments = conversationStore.loadAssignments()
        self.flashcards = conversationStore.loadFlashcards(focusText: Self.practiceFocusText(from: savedTurns), limit: 30)
        self.xpEvents = conversationStore.loadXPEvents()
        self.suggestions = conversationStore.loadSuggestions()
        self.quizHistory = conversationStore.loadQuizHistory()

        if savedTurns.isEmpty {
            let welcomeTurn = TutorTurn(
                speaker: .waves,
                text: "Hi, I am Accordian. Add notes or ask me anything.",
                createdAt: .now
            )
            self.turns = [welcomeTurn]
            conversationStore.save(welcomeTurn)
        } else {
            self.turns = savedTurns
        }

        rescoreStoredAttempts()

        Task {
            await refreshModelReadiness()
            await continueProcessingPendingSources()
            await organizeUngroupedSources()
        }
        refreshLearningPlan()
    }

    var todayXP: Int {
        let startOfDay = Calendar.current.startOfDay(for: .now)
        return xpEvents
            .filter { $0.createdAt >= startOfDay }
            .reduce(0) { $0 + $1.points }
    }

    var todayCheckCount: Int {
        let startOfDay = Calendar.current.startOfDay(for: .now)
        return attempts.filter { $0.createdAt >= startOfDay }.count
    }

    var bestSuggestion: LearningSuggestion? {
        suggestions.first
    }

    func refreshModelReadiness() async {
        modelReadiness = .checking

        if modelConfiguration.mode == .onDevice {
            #if canImport(FoundationModels)
            if #available(iOS 26, *) {
                switch SystemLanguageModel.default.availability {
                case .available:
                    modelReadiness = .ready
                case .unavailable(.deviceNotEligible):
                    modelReadiness = .deviceNotEligible
                case .unavailable(.appleIntelligenceNotEnabled):
                    modelReadiness = .appleIntelligenceNotEnabled
                case .unavailable(.modelNotReady):
                    modelReadiness = .appleModelNotReady
                case .unavailable(_):
                    modelReadiness = .deviceNotEligible
                }
                return
            }
            #endif
            modelReadiness = .deviceNotEligible
            return
        }

        do {
            let isInstalled = try await gemmaService.isModelInstalled()
            modelReadiness = isInstalled ? .ready : .modelMissing(gemmaService.modelName)
        } catch {
            modelReadiness = .serverUnavailable
        }
    }

    func updateModelConfiguration(_ configuration: ModelRuntimeConfiguration) async {
        modelConfiguration = configuration
        runtimeStore.save(configuration)
        gemmaService = Self.makeGemmaService(for: configuration)
        await refreshModelReadiness()
    }

    @discardableResult
    func submit(_ prompt: String, displayedAs displayText: String? = nil) async -> String? {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedPrompt.isEmpty == false else { return nil }

        let visibleText = displayText?.trimmingCharacters(in: .whitespacesAndNewlines)
        appendTurn(TutorTurn(speaker: .learner, text: visibleText?.isEmpty == false ? visibleText! : trimmedPrompt, createdAt: .now))
        isResponding = true
        lastError = nil

        do {
            let matches = relevantSources(for: trimmedPrompt)
            let response = try await gemmaService.reply(to: conversationHistory(for: trimmedPrompt, matches: matches))
            let groundedResponse = groundedResponseText(response, matches: matches)
            appendTurn(TutorTurn(speaker: .waves, text: groundedResponse, sourceTitles: matches.map(\.title), createdAt: .now))
            isResponding = false
            return groundedResponse
        } catch {
            await refreshModelReadiness()
            let message = modelConfiguration.mode == .onDevice
                ? "Something went wrong with the on-device model. Check that Apple Intelligence is enabled in Settings."
                : "I could not reach the AI server. Make sure Ollama is running and the model is installed."
            lastError = error.localizedDescription
            appendTurn(TutorTurn(speaker: .waves, text: message, createdAt: .now))
            isResponding = false
            return message
        }
    }

    func reset() {
        lastError = nil
        conversationStore.deleteAll()

        let freshTurn = TutorTurn(
            speaker: .waves,
            text: "Fresh session ready. What would you like to ask?",
            createdAt: .now
        )
        turns = [freshTurn]
        conversationStore.save(freshTurn)
    }

    func addStudySource(title: String, text: String, type: StudySource.SourceType = .notes) {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedText.isEmpty == false else { return }

        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = StudySource(
            title: trimmedTitle.isEmpty ? "Untitled Notes" : trimmedTitle,
            type: type,
            status: .processing,
            text: trimmedText
        )

        sources.insert(source, at: 0)
        conversationStore.save(source)
        conversationStore.replaceTopics(for: source.id, topics: fallbackTopics(for: source))
        topics = conversationStore.loadTopics()
        refreshPracticeDeck()
        refreshLearningPlan()
        refreshJourneyAssignments()

        Task {
            await organizeTopics(for: source)
        }
    }

    @discardableResult
    func makeFlashcards(from text: String) async -> String? {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedText.isEmpty == false else { return nil }

        isResponding = true
        lastError = nil
        let relatedSources = relevantSources(for: recentStudyContext(for: trimmedText))
        let primarySource = relatedSources.first
        let sourceTitle = primarySource?.title ?? "Recent chat"
        let sourceID = primarySource?.id
        let referenceText = referenceText(for: trimmedText, sources: relatedSources)

        do {
            let response = try await gemmaService.reply(to: [
                GemmaMessage(
                    role: "user",
                    content: """
                    Create exactly 3 concise flashcards for a student from this chat and local context.
                    Prefer facts from References when they are relevant.
                    Make the cards varied across learning types: definition, causeEffect, compareContrast, process, misconception, application, or recall.
                    Use only this repeated format:
                    Deck: short deck name
                    Topic: short topic name
                    Type: one of definition, causeEffect, compareContrast, process, misconception, application, recall
                    Front: one clear question
                    Back: one concise answer

                    Recent chat:
                    \(trimmedText)

                    References:
                    \(referenceText.isEmpty ? "No saved reference matched this answer." : referenceText)
                    """
                )
            ])
            let generatedCards = parseFlashcards(
                from: response,
                sourceID: sourceID,
                sourceTitle: sourceTitle,
                referenceText: referenceText
            )
            let cards = generatedCards.isEmpty ? fallbackFlashcards(from: trimmedText, source: primarySource, referenceText: referenceText) : generatedCards

            cards.reversed().forEach { card in
                flashcards.insert(card, at: 0)
                conversationStore.save(card)
            }
            refreshPracticeDeck()
            recordXP(for: .makeCards, reason: "Created flashcards from notes.")

            let message = "I made \(cards.count) flashcards from your notes."
            appendTurn(TutorTurn(speaker: .waves, text: message, createdAt: .now))
            isResponding = false
            return message
        } catch {
            await refreshModelReadiness()
            let cards = fallbackFlashcards(from: trimmedText, source: primarySource, referenceText: referenceText)
            cards.reversed().forEach { card in
                flashcards.insert(card, at: 0)
                conversationStore.save(card)
            }
            refreshPracticeDeck()
            recordXP(for: .makeCards, reason: "Created fallback flashcards from notes.")

            let message = "I made \(cards.count) simple flashcards from that answer."
            lastError = error.localizedDescription
            appendTurn(TutorTurn(speaker: .waves, text: message, createdAt: .now))
            isResponding = false
            return message
        }
    }

    @discardableResult
    func startQuiz(from text: String) async -> String? {
        await submit("""
        Quiz me from this material. Ask one question first, wait for my answer, then give feedback.

        \(text)
        """)
    }

    func saveAnswerAsSource(_ text: String) {
        addStudySource(title: "Saved Answer", text: text)
    }

    func createQuickFlashcard(for topic: LearningTopic?) -> StudyFlashcard {
        let title = topic?.title ?? sources.first?.title ?? "Saved Notes"
        let summary = topic?.summary
            ?? sources.first.map { String($0.text.prefix(220)) }
            ?? "Review the main idea from your saved notes."
        let card = StudyFlashcard(
            sourceID: topic?.sourceID,
            sourceTitle: title,
            deckTitle: title,
            topic: title,
            cardType: .recall,
            front: "What is the main idea of \(title)?",
            back: String(summary),
            referenceText: String(summary)
        )

        flashcards.insert(card, at: 0)
        conversationStore.save(card)
        refreshLearningPlan()
        return card
    }

    func deleteStudySource(_ source: StudySource) {
        sources.removeAll { $0.id == source.id }
        topics.removeAll { $0.sourceID == source.id }
        segments.removeAll { $0.sourceID == source.id }
        questions.removeAll { $0.sourceID == source.id }
        assignments.removeAll { assignment in
            guard let segmentID = assignment.segmentID else { return false }
            return segments.contains { $0.id == segmentID }
        }
        flashcards.removeAll { $0.sourceID == source.id }
        conversationStore.deleteSource(id: source.id)
        refreshPracticeDeck()
        refreshLearningPlan()
        refreshJourneyAssignments()
    }

    func reviewFlashcard(_ card: StudyFlashcard, grade: StudyFlashcard.ReviewGrade) {
        let reviewedCard = card.reviewed(grade)

        guard let index = flashcards.firstIndex(where: { $0.id == card.id }) else {
            return
        }

        flashcards[index] = reviewedCard
        conversationStore.save(reviewedCard)
        recordXP(for: .review, reason: "Reviewed a flashcard.")
        refreshPracticeDeck()
    }

    func refreshPracticeDeck() {
        flashcards = conversationStore.loadFlashcards(focusText: Self.practiceFocusText(from: turns), limit: 30)
        refreshLearningPlan()
    }

    func recordLearningAction(_ action: LearningAction) {
        recordXP(for: action, reason: "Started \(action.title.lowercased()) from the learning tools.")
    }

    private func organizeTopics(for source: StudySource) async {
        let fallback = fallbackTopics(for: source)

        do {
            let response = try await gemmaService.reply(to: [
                GemmaMessage(
                    role: "system",
                    content: learningParserSystemPrompt
                ),
                GemmaMessage(
                    role: "user",
                    content: learningExtractionPrompt(for: source)
                )
            ])

            let extraction = try parseLearningExtraction(from: response)
            let materialized = materializeLearningExtraction(extraction, source: source)
            let finalTopics = materialized.topics.isEmpty ? fallback : materialized.topics
            let finalSegments = materialized.segments
            let finalQuestions = preservingQuestionIDs(
                materialized.questions,
                sourceID: source.id
            )

            guard finalSegments.isEmpty == false, finalQuestions.isEmpty == false else {
                throw LearningExtractionError.insufficientQuestionBank
            }

            conversationStore.replaceTopics(for: source.id, topics: finalTopics)
            topics = conversationStore.loadTopics()
            conversationStore.replaceSegments(for: source.id, segments: finalSegments)
            segments = conversationStore.loadSegments()
            conversationStore.replaceQuestions(for: source.id, questions: finalQuestions)
            questions = conversationStore.loadQuestions()
            updateSourceStatus(source.id, status: .ready)
        } catch {
            conversationStore.replaceTopics(for: source.id, topics: fallback)
            topics = conversationStore.loadTopics()
            updateSourceStatus(source.id, status: .failed)
        }

        refreshJourneyAssignments()
        refreshLearningPlan()
    }

    private func continueProcessingPendingSources() async {
        let pendingSources = sources.filter { source in
            source.status == .processing
                || source.status == .failed
                || gemmaShouldReprocess(source)
        }

        for source in pendingSources {
            updateSourceStatus(source.id, status: .processing)
            await organizeTopics(for: source)
        }
    }

    private func organizeUngroupedSources() async {
        let groupedSourceIDs = Set(topics.compactMap(\.sourceID))
        let ungroupedSources = sources
            .filter { groupedSourceIDs.contains($0.id) == false }

        for source in ungroupedSources {
            await organizeTopics(for: source)
        }
    }

    private func seedFallbackTopicsForUngroupedSources() {
        let groupedSourceIDs = Set(topics.compactMap(\.sourceID))
        let ungroupedSources = sources
            .filter { groupedSourceIDs.contains($0.id) == false }

        guard ungroupedSources.isEmpty == false else { return }

        for source in ungroupedSources {
            conversationStore.replaceTopics(for: source.id, topics: fallbackTopics(for: source))
        }
        topics = conversationStore.loadTopics()
        for source in ungroupedSources {
            seedLearningObjects(for: source, topics: topics.filter { $0.sourceID == source.id })
        }
    }

    private func seedMissingQuestions() {
        var didReplaceQuestions = false

        for source in sources {
            let sourceTopics = topics.filter { $0.sourceID == source.id }
            let sourceQuestions = questions.filter { $0.sourceID == source.id }

            if sourceQuestions.isEmpty || sourceQuestions.count < minimumFallbackQuestionCount || isLegacyFallbackQuestionSet(sourceQuestions) || hasWeakMultipleChoiceDistractors(sourceQuestions) || hasBroadFallbackFillBlank(sourceQuestions) {
                seedLearningObjects(for: source, topics: sourceTopics)
                didReplaceQuestions = true
            }
        }

        if didReplaceQuestions {
            segments = conversationStore.loadSegments()
            questions = conversationStore.loadQuestions()
            refreshJourneyAssignments()
        }
    }

    private func updateSourceStatus(_ sourceID: UUID, status: StudySource.ProcessingStatus) {
        conversationStore.updateSourceStatus(id: sourceID, status: status)
        sources = sources.map { source in
            guard source.id == sourceID else { return source }
            return StudySource(
                id: source.id,
                title: source.title,
                type: source.type,
                status: status,
                text: source.text,
                createdAt: source.createdAt
            )
        }
    }

    private func isLegacyFallbackQuestionSet(_ sourceQuestions: [LearningQuestion]) -> Bool {
        guard sourceQuestions.count <= 3 else { return false }

        let fallbackSubtopics: Set<String> = ["Main idea", "Recall", "Explain"]
        let currentSubtopics = Set(sourceQuestions.map(\.subtopicTitle))
        let multipleChoiceCount = sourceQuestions.filter { $0.type == .multipleChoice }.count

        return multipleChoiceCount == 1 && currentSubtopics.isSubset(of: fallbackSubtopics)
    }

    private var minimumFallbackQuestionCount: Int {
        6
    }

    private func gemmaShouldReprocess(_ source: StudySource) -> Bool {
        guard modelReadiness.isReady else { return false }

        let sourceQuestions = questions.filter { $0.sourceID == source.id }
        return isLegacyFallbackQuestionSet(sourceQuestions)
            || hasWeakMultipleChoiceDistractors(sourceQuestions)
            || hasBroadFallbackFillBlank(sourceQuestions)
    }

    private func hasWeakMultipleChoiceDistractors(_ sourceQuestions: [LearningQuestion]) -> Bool {
        let giveawayPhrases = [
            "not mentioned",
            "different topic",
            "unrelated",
            "not listed"
        ]

        return sourceQuestions.contains { question in
            question.type == .multipleChoice && question.choices.contains { choice in
                let lowercasedChoice = choice.lowercased()
                return giveawayPhrases.contains { lowercasedChoice.contains($0) }
            }
        }
    }

    private func hasBroadFallbackFillBlank(_ sourceQuestions: [LearningQuestion]) -> Bool {
        sourceQuestions.contains { question in
            question.type == .fillBlank
                && question.prompt.contains("mainly about ____")
                && question.answer.count > 80
        }
    }

    private func rescoreStoredAttempts() {
        var didUpdate = false

        for attempt in attempts {
            guard let question = questions.first(where: { $0.id == attempt.questionID }) else {
                continue
            }

            let updatedScore = localAnswerScore(attempt.response, for: question)
            guard abs(updatedScore - attempt.score) > 0.001 else {
                continue
            }

            let updatedAttempt = QuestionAttempt(
                id: attempt.id,
                questionID: attempt.questionID,
                response: attempt.response,
                score: updatedScore,
                createdAt: attempt.createdAt
            )
            conversationStore.save(updatedAttempt)
            didUpdate = true
        }

        if didUpdate {
            attempts = conversationStore.loadAttempts()
        }
    }

    func masterySnapshot(for topic: LearningTopic?) -> MasterySnapshot {
        masterySnapshot(for: scopedQuestions(for: topic))
    }

    func coverageMap() -> LearningCoverageMap {
        let topicNodes = topics.map { topic in
            let topicQuestions = scopedQuestions(for: topic)
            return LearningCoverageNode(
                id: topic.id.uuidString,
                level: .topic,
                title: topic.title,
                summary: topic.summary,
                snapshot: masterySnapshot(for: topicQuestions),
                children: subtopicNodes(for: topicQuestions, topicTitle: topic.title)
            )
        }

        return LearningCoverageMap(
            root: LearningCoverageNode(
                id: "all-notes",
                level: .allNotes,
                title: "All Notes",
                summary: "Coverage across everything saved locally.",
                snapshot: masterySnapshot(for: questions),
                children: topicNodes
            )
        )
    }

    func coverageNode(for source: StudySource?) -> LearningCoverageNode {
        guard let source else {
            return coverageMap().root
        }

        let sourceQuestions = scopedQuestions(for: source)
        let sourceTopics = topics.filter { $0.sourceID == source.id }
        let topicNodes = sourceTopics.map { topic in
            let topicQuestions = sourceQuestions.filter { question in
                question.topicID == topic.id || question.topicTitle == topic.title
            }
            return LearningCoverageNode(
                id: topic.id.uuidString,
                level: .topic,
                title: topic.title,
                summary: topic.summary,
                snapshot: masterySnapshot(for: topicQuestions),
                children: subtopicNodes(for: topicQuestions, topicTitle: topic.title)
            )
        }

        return LearningCoverageNode(
            id: source.id.uuidString,
            level: .allNotes,
            title: source.title,
            summary: "Progress for this note stack.",
            snapshot: masterySnapshot(for: sourceQuestions),
            children: topicNodes
        )
    }

    func saveQuizHistory(_ entry: QuizHistoryEntry) {
        conversationStore.save(entry)
        quizHistory.removeAll { $0.id == entry.id }
        quizHistory.insert(entry, at: 0)
    }

    func quizProgressEvidence(for source: StudySource?) -> QuizProgressEvidence {
        let scopedHistory = quizHistory
            .filter { entry in
                guard let source else { return true }
                return entry.sourceID == source.id
            }
            .sorted { $0.createdAt < $1.createdAt }

        return QuizProgressEvidence(
            latest: scopedHistory.last,
            previous: scopedHistory.dropLast().last,
            points: scopedHistory.suffix(6).map(\.score)
        )
    }

    func growthEvidence(for source: StudySource?) -> LearningGrowthEvidence {
        let questionIDs = Set(scopedQuestions(for: source).map(\.id))
        let scopedAttempts = attempts
            .filter { questionIDs.contains($0.questionID) }
            .sorted { $0.createdAt < $1.createdAt }

        guard scopedAttempts.isEmpty == false else {
            return LearningGrowthEvidence(
                direction: .waiting,
                points: [],
                recentStrongCount: 0,
                recentCloseCount: 0,
                recentReviewCount: 0,
                evidenceText: "Answer a quiz to start the growth line."
            )
        }

        let recentAttempts = Array(scopedAttempts.suffix(8))
        let points = rollingScores(from: recentAttempts)
        let latestWindow = Array(scopedAttempts.suffix(4))
        let previousWindow = Array(scopedAttempts.dropLast(4).suffix(4))
        let latestAverage = averageScore(latestWindow)
        let previousAverage = previousWindow.isEmpty ? nil : averageScore(previousWindow)
        let delta = latestAverage - (previousAverage ?? latestAverage)
        let direction: LearningGrowthEvidence.Direction

        if previousWindow.isEmpty {
            direction = .steady
        } else if delta > 0.08 {
            direction = .rising
        } else if delta < -0.08 {
            direction = .slipping
        } else {
            direction = .steady
        }

        let strong = latestWindow.filter { $0.score >= 0.75 }.count
        let close = latestWindow.filter { 0.45..<0.75 ~= $0.score }.count
        let review = latestWindow.filter { $0.score < 0.45 }.count
        let evidenceText: String

        if previousAverage != nil {
            evidenceText = "\(latestWindow.count) recent checks vs \(previousWindow.count) before."
        } else {
            evidenceText = "\(latestWindow.count) recent checks saved."
        }

        return LearningGrowthEvidence(
            direction: direction,
            points: points,
            recentStrongCount: strong,
            recentCloseCount: close,
            recentReviewCount: review,
            evidenceText: evidenceText
        )
    }

    func subtopicMasteries(for topic: LearningTopic?) -> [SubtopicMastery] {
        let grouped = Dictionary(grouping: scopedQuestions(for: topic)) { question in
            question.subtopicTitle
        }

        return grouped
            .map { title, questions in
                let topicTitle = topic?.title ?? questions.first?.topicTitle ?? "All Notes"
                return SubtopicMastery(
                    id: "\(topicTitle)-\(title)",
                    title: title,
                    topicTitle: topicTitle,
                    snapshot: masterySnapshot(for: questions)
                )
            }
            .sorted { lhs, rhs in
                if lhs.snapshot.weightedMastery == rhs.snapshot.weightedMastery {
                    return lhs.title < rhs.title
                }
                return lhs.snapshot.weightedMastery < rhs.snapshot.weightedMastery
            }
    }

    private func subtopicNodes(for questions: [LearningQuestion], topicTitle: String) -> [LearningCoverageNode] {
        Dictionary(grouping: questions) { question in
            question.subtopicTitle
        }
        .map { title, questions in
            LearningCoverageNode(
                id: "\(topicTitle)-\(title)",
                level: .subtopic,
                title: title,
                summary: "\(questions.count) checks",
                snapshot: masterySnapshot(for: questions),
                children: []
            )
        }
        .sorted { lhs, rhs in
            if lhs.snapshot.weightedMastery == rhs.snapshot.weightedMastery {
                return lhs.title < rhs.title
            }
            return lhs.snapshot.weightedMastery < rhs.snapshot.weightedMastery
        }
    }

    private func masterySnapshot(for scopedQuestions: [LearningQuestion]) -> MasterySnapshot {
        guard scopedQuestions.isEmpty == false else {
            return MasterySnapshot(testedCount: 0, totalCount: 0, weightedMastery: 0, dimensions: defaultUnderstandingDimensions())
        }

        let latestAttemptsByQuestion = latestAttempts()
        let allAttemptsByQuestion = Dictionary(grouping: attempts) { $0.questionID }
        let tested = scopedQuestions.filter { latestAttemptsByQuestion[$0.id] != nil }
        let earned = scopedQuestions.reduce(0.0) { total, question in
            let score = latestAttemptsByQuestion[question.id]?.score ?? 0
            return total + score * question.type.weight * question.importance * question.difficulty
        }
        let possible = scopedQuestions.reduce(0.0) { total, question in
            total + question.type.weight * question.importance * question.difficulty
        }

        return MasterySnapshot(
            testedCount: tested.count,
            totalCount: scopedQuestions.count,
            weightedMastery: possible == 0 ? 0 : earned / possible,
            dimensions: understandingDimensions(
                for: scopedQuestions,
                latestAttemptsByQuestion: latestAttemptsByQuestion,
                allAttemptsByQuestion: allAttemptsByQuestion
            )
        )
    }

    private func understandingDimensions(
        for scopedQuestions: [LearningQuestion],
        latestAttemptsByQuestion: [UUID: QuestionAttempt],
        allAttemptsByQuestion: [UUID: [QuestionAttempt]]
    ) -> [UnderstandingDimension] {
        let coverage = Double(scopedQuestions.filter { latestAttemptsByQuestion[$0.id] != nil }.count) / Double(max(scopedQuestions.count, 1))
        let recognition = dimensionScore(for: scopedQuestions.filter { $0.type == .multipleChoice }, latestAttemptsByQuestion: latestAttemptsByQuestion)
        let recall = dimensionScore(for: scopedQuestions.filter { $0.type == .fillBlank }, latestAttemptsByQuestion: latestAttemptsByQuestion)
        let explanation = dimensionScore(for: scopedQuestions.filter { $0.type == .shortAnswer }, latestAttemptsByQuestion: latestAttemptsByQuestion)
        let applicationQuestions = scopedQuestions.filter { question in
            let text = "\(question.prompt) \(question.subtopicTitle)".lowercased()
            return text.contains("why")
                || text.contains("how")
                || text.contains("use")
                || text.contains("apply")
                || text.contains("scenario")
                || text.contains("example")
        }
        let application = dimensionScore(for: applicationQuestions, latestAttemptsByQuestion: latestAttemptsByQuestion)
        let consistency = consistencyScore(for: scopedQuestions, allAttemptsByQuestion: allAttemptsByQuestion)

        return [
            UnderstandingDimension(id: "coverage", title: "Coverage", value: coverage),
            UnderstandingDimension(id: "recall", title: "Recall", value: recall),
            UnderstandingDimension(id: "recognition", title: "Recognition", value: recognition),
            UnderstandingDimension(id: "explanation", title: "Explain", value: explanation),
            UnderstandingDimension(id: "application", title: "Apply", value: application),
            UnderstandingDimension(id: "consistency", title: "Consistency", value: consistency)
        ]
    }

    private func defaultUnderstandingDimensions() -> [UnderstandingDimension] {
        [
            UnderstandingDimension(id: "coverage", title: "Coverage", value: 0),
            UnderstandingDimension(id: "recall", title: "Recall", value: 0),
            UnderstandingDimension(id: "recognition", title: "Recognition", value: 0),
            UnderstandingDimension(id: "explanation", title: "Explain", value: 0),
            UnderstandingDimension(id: "application", title: "Apply", value: 0),
            UnderstandingDimension(id: "consistency", title: "Consistency", value: 0)
        ]
    }

    private func dimensionScore(
        for questions: [LearningQuestion],
        latestAttemptsByQuestion: [UUID: QuestionAttempt]
    ) -> Double {
        guard questions.isEmpty == false else { return 0 }

        let earned = questions.reduce(0.0) { total, question in
            let score = latestAttemptsByQuestion[question.id]?.score ?? 0
            return total + score * question.importance * question.difficulty
        }
        let possible = questions.reduce(0.0) { total, question in
            total + question.importance * question.difficulty
        }
        return possible == 0 ? 0 : earned / possible
    }

    private func consistencyScore(
        for questions: [LearningQuestion],
        allAttemptsByQuestion: [UUID: [QuestionAttempt]]
    ) -> Double {
        let repeatedScores = questions.compactMap { question -> Double? in
            let recent = (allAttemptsByQuestion[question.id] ?? [])
                .sorted { $0.createdAt > $1.createdAt }
                .prefix(3)
            guard recent.count >= 2 else { return nil }
            return recent.reduce(0.0) { $0 + $1.score } / Double(recent.count)
        }

        guard repeatedScores.isEmpty == false else { return 0 }
        return repeatedScores.reduce(0, +) / Double(repeatedScores.count)
    }

    private func rollingScores(from attempts: [QuestionAttempt]) -> [Double] {
        attempts.indices.map { index in
            let start = max(0, index - 2)
            let window = attempts[start...index]
            return window.reduce(0.0) { $0 + $1.score } / Double(window.count)
        }
    }

    private func averageScore(_ attempts: [QuestionAttempt]) -> Double {
        guard attempts.isEmpty == false else { return 0 }
        return attempts.reduce(0.0) { $0 + $1.score } / Double(attempts.count)
    }

    func nextQuestion(for topic: LearningTopic?) -> LearningQuestion? {
        let latestAttemptsByQuestion = latestAttempts()
        let scoped = scopedQuestions(for: topic)
        return preferredQuestion(from: scoped, latestAttemptsByQuestion: latestAttemptsByQuestion)
    }

    func nextQuestion(for node: LearningCoverageNode) -> LearningQuestion? {
        let latestAttemptsByQuestion = latestAttempts()
        let scoped = scopedQuestions(for: node)
        return preferredQuestion(from: scoped, latestAttemptsByQuestion: latestAttemptsByQuestion)
    }

    func nextJourneyStep(for node: LearningCoverageNode) -> (assignment: JourneyAssignment?, question: LearningQuestion?) {
        refreshJourneyAssignments(for: node)

        guard
            let assignment = assignments.first(where: { $0.status == .pending && $0.dueAt <= .now }),
            let questionID = assignment.questionID,
            let question = questions.first(where: { $0.id == questionID })
        else {
            return (nil, nextQuestion(for: node))
        }

        return (assignment, question)
    }

    func nextJourneyStep(
        for source: StudySource?,
        excluding excludedQuestionID: UUID? = nil
    ) -> (assignment: JourneyAssignment?, question: LearningQuestion?) {
        let allScoped = scopedQuestions(for: source)
        let scoped: [LearningQuestion]

        if let excludedQuestionID, allScoped.count > 1 {
            scoped = allScoped.filter { $0.id != excludedQuestionID }
        } else {
            scoped = allScoped
        }

        refreshJourneyAssignments(for: scoped)

        guard
            let assignment = assignments.first(where: { $0.status == .pending && $0.dueAt <= .now }),
            let questionID = assignment.questionID,
            let question = scoped.first(where: { $0.id == questionID })
        else {
            let latestAttemptsByQuestion = latestAttempts()
            return (nil, preferredQuestion(from: scoped, latestAttemptsByQuestion: latestAttemptsByQuestion))
        }

        return (assignment, question)
    }

    func buildQuiz(for source: StudySource?) -> [LearningQuestion] {
        let scoped = scopedQuestions(for: source)
        guard scoped.isEmpty == false else { return [] }

        let latestAttemptsByQuestion = latestAttempts()
        let targetCount = quizTargetCount(for: scoped)
        var selected: [LearningQuestion] = []

        func addCandidates(_ candidates: [LearningQuestion], until limit: Int) {
            for question in candidates where selected.contains(where: { $0.id == question.id }) == false {
                guard selected.count < targetCount else { break }
                guard selected.filter({ $0.subtopicTitle == question.subtopicTitle }).count < 2 else { continue }

                selected.append(question)
                if selected.count >= limit { break }
            }
        }

        let weak = scoped
            .filter { (latestAttemptsByQuestion[$0.id]?.score ?? 1) < 0.75 }
            .sorted { lhs, rhs in
                priorityScore(for: lhs, latestAttempt: latestAttemptsByQuestion[lhs.id])
                    > priorityScore(for: rhs, latestAttempt: latestAttemptsByQuestion[rhs.id])
            }
        let untested = scoped
            .filter { latestAttemptsByQuestion[$0.id] == nil }
            .sorted { lhs, rhs in lhs.importance > rhs.importance }
        let important = scoped
            .sorted { lhs, rhs in
                lhs.importance * lhs.difficulty > rhs.importance * rhs.difficulty
            }

        addCandidates(weak, until: max(2, targetCount / 2))
        addCandidates(untested, until: max(selected.count + 2, Int(Double(targetCount) * 0.75)))
        addCandidates(important, until: max(selected.count + 1, targetCount - 1))
        addCandidates(scoped.shuffled(), until: targetCount)

        if selected.contains(where: { $0.type == .shortAnswer }) == false,
           let shortAnswer = scoped.first(where: { $0.type == .shortAnswer && selected.contains($0) == false }) {
            if selected.count >= targetCount {
                selected.removeLast()
            }
            selected.append(shortAnswer)
        }

        return selected
    }

    private func quizTargetCount(for questions: [LearningQuestion]) -> Int {
        switch questions.count {
        case 0:
            0
        case 1...5:
            questions.count
        case 6...12:
            min(8, questions.count)
        default:
            min(12, max(8, questions.count / 4))
        }
    }

    @discardableResult
    func answerJourneyQuestion(_ question: LearningQuestion, assignment: JourneyAssignment?, response: String) async -> QuestionAttempt {
        let attempt = await answerQuestion(question, response: response)

        if let assignment {
            conversationStore.completeAssignment(id: assignment.id)
            assignments = conversationStore.loadAssignments()
        }

        refreshJourneyAssignments()
        return attempt
    }

    private func refreshJourneyAssignments(for node: LearningCoverageNode? = nil) {
        let scoped = node.map(scopedQuestions(for:)) ?? questions
        refreshJourneyAssignments(for: scoped)
    }

    private func refreshJourneyAssignments(for scoped: [LearningQuestion]) {
        let latestAttemptsByQuestion = latestAttempts()
        let untestedAssignments = scoped
            .filter { latestAttemptsByQuestion[$0.id] == nil }
            .map { question in
                JourneyAssignment(
                    segmentID: question.segmentID,
                    questionID: question.id,
                    type: .learn,
                    reason: "Build coverage with an untested idea.",
                    priority: priorityScore(for: question, latestAttempt: nil),
                    dueAt: .now
                )
            }

        let generatedAssignments: [JourneyAssignment]
        if untestedAssignments.isEmpty {
            generatedAssignments = reviewAssignments(from: scoped, latestAttemptsByQuestion: latestAttemptsByQuestion)
        } else {
            generatedAssignments = untestedAssignments
        }

        conversationStore.replaceAssignments(generatedAssignments.sorted { lhs, rhs in
            if lhs.dueAt == rhs.dueAt {
                return lhs.priority > rhs.priority
            }
            return lhs.dueAt < rhs.dueAt
        })
        assignments = conversationStore.loadAssignments()
    }

    private func reviewAssignments(
        from scopedQuestions: [LearningQuestion],
        latestAttemptsByQuestion: [UUID: QuestionAttempt]
    ) -> [JourneyAssignment] {
        scopedQuestions
            .filter { latestAttemptsByQuestion[$0.id] != nil }
            .sorted { lhs, rhs in
                priorityScore(for: lhs, latestAttempt: latestAttemptsByQuestion[lhs.id])
                    > priorityScore(for: rhs, latestAttempt: latestAttemptsByQuestion[rhs.id])
            }
            .prefix(3)
            .map { question in
                let latestAttempt = latestAttemptsByQuestion[question.id]
                let needsReview = (latestAttempt?.score ?? 0) < 0.75
                return JourneyAssignment(
                    segmentID: question.segmentID,
                    questionID: question.id,
                    type: needsReview ? .review : .strengthen,
                    reason: needsReview ? "Review a weak idea." : "Strengthen a covered idea.",
                    priority: priorityScore(for: question, latestAttempt: latestAttempt),
                    dueAt: .now
                )
            }
    }

    private func preferredQuestion(
        from scopedQuestions: [LearningQuestion],
        latestAttemptsByQuestion: [UUID: QuestionAttempt]
    ) -> LearningQuestion? {
        let untestedQuestions = scopedQuestions.filter { latestAttemptsByQuestion[$0.id] == nil }
        let untestedMultipleChoice = untestedQuestions.filter { $0.type == .multipleChoice }
        let candidates: [LearningQuestion]

        if untestedMultipleChoice.isEmpty == false {
            candidates = untestedMultipleChoice
        } else if untestedQuestions.isEmpty == false {
            candidates = untestedQuestions
        } else {
            candidates = scopedQuestions
        }

        return candidates
            .max { lhs, rhs in
                priorityScore(for: lhs, latestAttempt: latestAttemptsByQuestion[lhs.id])
                    < priorityScore(for: rhs, latestAttempt: latestAttemptsByQuestion[rhs.id])
            }
    }

    @discardableResult
    func answerQuestion(_ question: LearningQuestion, response: String) async -> QuestionAttempt {
        let score = localAnswerScore(response, for: question)
        let attempt = QuestionAttempt(questionID: question.id, response: response, score: score)
        attempts.insert(attempt, at: 0)
        conversationStore.save(attempt, question: question)
        recordXP(for: .test, reason: score >= 0.75 ? "Passed a learning check." : "Practiced a learning check.")
        refineAnswerScoreInBackground(attempt, question: question)
        return attempt
    }

    private func refineAnswerScoreInBackground(_ attempt: QuestionAttempt, question: LearningQuestion) {
        guard question.type != .multipleChoice, modelReadiness.isReady else { return }

        Task {
            let refinedScore = await scoreAnswerWithGemmaIfUseful(response: attempt.response, for: question)
            guard refinedScore != attempt.score else { return }

            let refinedAttempt = QuestionAttempt(
                id: attempt.id,
                questionID: attempt.questionID,
                response: attempt.response,
                score: refinedScore,
                createdAt: attempt.createdAt
            )

            if let index = attempts.firstIndex(where: { $0.id == attempt.id }) {
                attempts[index] = refinedAttempt
            } else {
                attempts.insert(refinedAttempt, at: 0)
            }

            conversationStore.save(refinedAttempt, question: question)
            refreshJourneyAssignments()
            refreshLearningPlan()
        }
    }

    func previewScore(response: String, for question: LearningQuestion) -> Double {
        localAnswerScore(response, for: question)
    }

    private func localAnswerScore(_ response: String, for question: LearningQuestion) -> Double {
        max(scoreAnswer(response, for: question), semanticCoverageScore(response: response, for: question))
    }

    private func scoreAnswerWithGemmaIfUseful(response: String, for question: LearningQuestion) async -> Double {
        let fallbackScore = localAnswerScore(response, for: question)

        guard question.type != .multipleChoice else {
            return fallbackScore
        }

        guard modelReadiness.isReady else {
            return fallbackScore
        }

        do {
            let gradingMessages = [
                GemmaMessage(
                    role: "system",
                    content: """
                    You are Accordian's bounded answer grader.
                    Grade only against the expected answer from saved notes.
                    Return valid JSON only with keys score and reason.
                    score must be a number from 0 to 1.
                    Be strict about missing core ideas, but allow paraphrases and word order changes.
                    Do not use outside knowledge.
                    """
                ),
                GemmaMessage(
                    role: "user",
                    content: answerGradingPrompt(response: response, question: question, localScore: fallbackScore)
                )
            ]

            let result = try await withTimeout(seconds: 2) {
                try await self.gemmaService.reply(to: gradingMessages)
            }

            let evaluation = try parseAnswerEvaluation(from: result)
            return min(max(evaluation.score, fallbackScore), 1)
        } catch {
            return fallbackScore
        }
    }

    private func answerGradingPrompt(response: String, question: LearningQuestion, localScore: Double) -> String {
        """
        Grade this student answer.

        Question type: \(question.type.rawValue)
        Topic: \(question.topicTitle)
        Subtopic: \(question.subtopicTitle)
        Prompt: \(question.prompt)
        Expected answer from saved notes: \(question.answer)
        Student response: \(response)
        Local heuristic score: \(String(format: "%.2f", localScore))

        Rubric:
        - 1.0: fully captures the expected answer.
        - 0.7 to 0.9: mostly correct but misses a smaller detail.
        - 0.4 to 0.6: partially related but misses a core relationship.
        - 0.1 to 0.3: mentions a relevant word but does not answer the prompt.
        - 0.0: incorrect, blank, or unrelated.

        Return shape:
        {"score":0.0,"reason":"short reason"}
        """
    }

    private func parseAnswerEvaluation(from response: String) throws -> AnswerEvaluation {
        let jsonText = extractJSONObject(from: response)
        let data = Data(jsonText.utf8)
        return try JSONDecoder().decode(AnswerEvaluation.self, from: data)
    }

    private func seedLearningObjects(for source: StudySource, topics sourceTopics: [LearningTopic]) {
        guard sourceTopics.isEmpty == false else { return }

        let objects = fallbackLearningObjects(for: source, topics: sourceTopics)
        let generatedSegments = objects.segments
        conversationStore.replaceSegments(for: source.id, segments: generatedSegments)
        segments = conversationStore.loadSegments()

        let generatedQuestions = preservingQuestionIDs(objects.questions, sourceID: source.id)
        conversationStore.replaceQuestions(for: source.id, questions: generatedQuestions)
        questions = conversationStore.loadQuestions()
    }

    private func fallbackLearningObjects(for source: StudySource, topics sourceTopics: [LearningTopic]) -> (segments: [LearningSegment], questions: [LearningQuestion]) {
        let noteText = learningText(for: source)
        let generatedSegments = sourceTopics.map { topic in
            LearningSegment(
                sourceID: source.id,
                topicID: topic.id,
                topicTitle: topic.title,
                subtopicTitle: "Main idea",
                text: topic.summary,
                evidence: String(noteText.prefix(220)),
                importance: 1,
                difficulty: 1
            )
        }
        let generatedQuestions = sourceTopics.flatMap { topic in
            fallbackQuestions(for: source, topic: topic)
        }
        return (generatedSegments, generatedQuestions)
    }

    private func seedQuestions(for source: StudySource, topics sourceTopics: [LearningTopic]) {
        guard sourceTopics.isEmpty == false else { return }

        let generatedQuestions = preservingQuestionIDs(sourceTopics.flatMap { topic in
            fallbackQuestions(for: source, topic: topic)
        }, sourceID: source.id)
        conversationStore.replaceQuestions(for: source.id, questions: generatedQuestions)
        questions = conversationStore.loadQuestions()
    }

    private func preservingQuestionIDs(_ generatedQuestions: [LearningQuestion], sourceID: UUID) -> [LearningQuestion] {
        let existingQuestionsBySignature = Dictionary(
            questions
                .filter { $0.sourceID == sourceID }
                .map { (questionSignature($0), $0) },
            uniquingKeysWith: { existing, _ in existing }
        )

        return generatedQuestions.map { question in
            guard let existingQuestion = existingQuestionsBySignature[questionSignature(question)] else {
                return question
            }

            return LearningQuestion(
                id: existingQuestion.id,
                sourceID: question.sourceID,
                topicID: question.topicID,
                segmentID: question.segmentID,
                topicTitle: question.topicTitle,
                subtopicTitle: question.subtopicTitle,
                type: question.type,
                prompt: question.prompt,
                answer: question.answer,
                choices: question.choices,
                importance: question.importance,
                difficulty: question.difficulty,
                createdAt: existingQuestion.createdAt
            )
        }
    }

    private func questionSignature(_ question: LearningQuestion) -> String {
        [
            question.type.rawValue,
            question.topicTitle,
            question.subtopicTitle,
            question.prompt,
            question.answer
        ]
        .map { $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
        .joined(separator: "|")
    }

    private func fallbackQuestions(for source: StudySource, topic: LearningTopic) -> [LearningQuestion] {
        let noteText = learningText(for: source)
        let summary = topic.summary == "Found in \(source.title)." ? String(noteText.prefix(220)) : topic.summary
        let fillBlank = fallbackFillBlank(for: topic, summary: summary)
        let mainChoices = normalizedChoices(
            [summary] + plausibleMainIdeaDistractors(for: summary, topicTitle: topic.title),
            answer: summary,
            type: .multipleChoice
        )

        var generatedQuestions = [
            LearningQuestion(
                sourceID: source.id,
                topicID: topic.id,
                topicTitle: topic.title,
                subtopicTitle: "Main idea",
                type: .multipleChoice,
                prompt: "Which statement best matches \(topic.title)?",
                answer: summary,
                choices: mainChoices,
                importance: 1.2,
                difficulty: 0.8
            )
        ]

        if let parts = processParts(in: summary) {
            generatedQuestions.append(
                LearningQuestion(
                    sourceID: source.id,
                    topicID: topic.id,
                    topicTitle: topic.title,
                    subtopicTitle: "Inputs",
                    type: .multipleChoice,
                    prompt: "Which inputs does \(topic.title) use?",
                    answer: parts.inputs,
                    choices: normalizedChoices(
                        [parts.inputs] + inputDistractors(for: parts, topicTitle: topic.title),
                        answer: parts.inputs,
                        type: .multipleChoice
                    ),
                    importance: 1.1,
                    difficulty: 0.9
                )
            )
            generatedQuestions.append(
                LearningQuestion(
                    sourceID: source.id,
                    topicID: topic.id,
                    topicTitle: topic.title,
                    subtopicTitle: "Outputs",
                    type: .multipleChoice,
                    prompt: "What does \(topic.title) make?",
                    answer: parts.outputs,
                    choices: normalizedChoices(
                        [parts.outputs] + outputDistractors(for: parts, topicTitle: topic.title),
                        answer: parts.outputs,
                        type: .multipleChoice
                    ),
                    importance: 1.1,
                    difficulty: 0.9
                )
            )
        }

        generatedQuestions.append(contentsOf: supplementalFallbackQuestions(for: source, topic: topic, summary: summary))

        generatedQuestions.append(contentsOf: [
            LearningQuestion(
                sourceID: source.id,
                topicID: topic.id,
                topicTitle: topic.title,
                subtopicTitle: fillBlank.subtopic,
                type: .fillBlank,
                prompt: fillBlank.prompt,
                answer: fillBlank.answer,
                importance: 1.0,
                difficulty: 1.1
            ),
            LearningQuestion(
                sourceID: source.id,
                topicID: topic.id,
                topicTitle: topic.title,
                subtopicTitle: "Explain",
                type: .shortAnswer,
                prompt: "Explain \(topic.title) in your own words.",
                answer: summary,
                importance: 1.4,
                difficulty: 1.4
            )
        ])

        return generatedQuestions
    }

    private func supplementalFallbackQuestions(
        for source: StudySource,
        topic: LearningTopic,
        summary: String
    ) -> [LearningQuestion] {
        let lowercasedSummary = summary.lowercased()
        var questions: [LearningQuestion] = []

        if lowercasedSummary.contains("programming language") {
            questions.append(
                LearningQuestion(
                    sourceID: source.id,
                    topicID: topic.id,
                    topicTitle: topic.title,
                    subtopicTitle: "Definition",
                    type: .multipleChoice,
                    prompt: "What kind of tool is \(topic.title)?",
                    answer: "a programming language",
                    choices: normalizedChoices(
                        [
                            "a programming language",
                            "an operating system",
                            "a database engine",
                            "a web browser"
                        ],
                        answer: "a programming language",
                        type: .multipleChoice
                    ),
                    importance: 0.8,
                    difficulty: 0.6
                )
            )
        }

        if lowercasedSummary.contains("object-oriented") || lowercasedSummary.contains("object oriented") {
            questions.append(
                LearningQuestion(
                    sourceID: source.id,
                    topicID: topic.id,
                    topicTitle: topic.title,
                    subtopicTitle: "Paradigm",
                    type: .fillBlank,
                    prompt: "\(topic.title) is commonly described as ____.",
                    answer: "object-oriented",
                    importance: 1.0,
                    difficulty: 1.0
                )
            )
        }

        if lowercasedSummary.contains("write once") || lowercasedSummary.contains("run anywhere") {
            questions.append(
                LearningQuestion(
                    sourceID: source.id,
                    topicID: topic.id,
                    topicTitle: topic.title,
                    subtopicTitle: "Portability",
                    type: .fillBlank,
                    prompt: "\(topic.title)'s portability goal is often summarized as write once, ____.",
                    answer: "run anywhere",
                    importance: 1.1,
                    difficulty: 1.1
                )
            )
        }

        if lowercasedSummary.contains("jvm") || lowercasedSummary.contains("virtual machine") {
            questions.append(
                LearningQuestion(
                    sourceID: source.id,
                    topicID: topic.id,
                    topicTitle: topic.title,
                    subtopicTitle: "Runtime",
                    type: .shortAnswer,
                    prompt: "Why does the JVM matter for \(topic.title)?",
                    answer: "The JVM runs compiled Java programs and helps them run across different platforms.",
                    importance: 1.2,
                    difficulty: 1.3
                )
            )
        }

        if lowercasedSummary.contains("high-level") || lowercasedSummary.contains("general-purpose") || lowercasedSummary.contains("memory-safe") {
            questions.append(
                LearningQuestion(
                    sourceID: source.id,
                    topicID: topic.id,
                    topicTitle: topic.title,
                    subtopicTitle: "Properties",
                    type: .shortAnswer,
                    prompt: "Name two important properties of \(topic.title).",
                    answer: "Java is high-level, general-purpose, memory-safe, and object-oriented.",
                    importance: 1.0,
                    difficulty: 1.1
                )
            )
        }

        return questions
    }

    private func fallbackFillBlank(
        for topic: LearningTopic,
        summary: String
    ) -> (subtopic: String, prompt: String, answer: String) {
        let lowercasedSummary = summary.lowercased()

        if lowercasedSummary.contains("programming language") {
            return (
                "Definition",
                "\(topic.title) is a high-level, general-purpose, memory-safe, object-oriented ____.",
                "programming language"
            )
        }

        if lowercasedSummary.contains("write once") || lowercasedSummary.contains("run anywhere") {
            return (
                "Portability",
                "\(topic.title) is intended to let programmers write once, ____.",
                "run anywhere"
            )
        }

        if lowercasedSummary.contains("gravity") && lowercasedSummary.contains("mass") {
            return (
                "Force",
                "\(topic.title) pulls objects with ____ toward each other.",
                "mass"
            )
        }

        if let parts = processParts(in: summary) {
            return (
                "Outputs",
                "\(topic.title) makes ____.",
                parts.outputs
            )
        }

        return (
            "Recall",
            "\(topic.title) is mainly about ____.",
            conciseFallbackAnswer(from: summary)
        )
    }

    private func conciseFallbackAnswer(from summary: String) -> String {
        let sentence = summary
            .components(separatedBy: ".")
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? summary

        if sentence.count <= 90 {
            return sentence
        }

        let words = sentence.components(separatedBy: .whitespaces)
        return words.prefix(10).joined(separator: " ")
    }

    private func plausibleMainIdeaDistractors(for answer: String, topicTitle: String) -> [String] {
        let lowercasedAnswer = answer.lowercased()
        let lowercasedTopic = topicTitle.lowercased()

        if lowercasedTopic.contains("photosynthesis") || lowercasedAnswer.contains("photosynthesis") {
            return [
                "Photosynthesis breaks down glucose and oxygen to release energy for cells.",
                "Photosynthesis uses oxygen and glucose to make carbon dioxide and water.",
                "Photosynthesis moves water through a plant but does not create new chemical energy."
            ]
        }

        if lowercasedTopic.contains("gravity") || lowercasedAnswer.contains("gravity") {
            return [
                "Gravity is a force that pushes objects with mass away from each other.",
                "Gravity only affects objects that are already moving through space.",
                "Gravity changes an object's mass instead of affecting its motion."
            ]
        }

        return [
            "\(topicTitle) describes a similar idea but reverses the cause and effect.",
            "\(topicTitle) applies the same terms to the wrong outcome.",
            "\(topicTitle) explains a related process but leaves out the key relationship."
        ]
    }

    private func inputDistractors(for parts: (inputs: String, outputs: String), topicTitle: String) -> [String] {
        if topicTitle.lowercased().contains("photosynthesis") {
            return [
                "oxygen, glucose, and light energy",
                "soil nutrients, oxygen, and glucose",
                parts.outputs
            ]
        }

        return [
            parts.outputs,
            "\(parts.inputs) and \(parts.outputs)",
            "the final products of \(topicTitle)"
        ]
    }

    private func outputDistractors(for parts: (inputs: String, outputs: String), topicTitle: String) -> [String] {
        if topicTitle.lowercased().contains("photosynthesis") {
            return [
                "carbon dioxide and water",
                "light energy and chlorophyll",
                parts.inputs
            ]
        }

        return [
            parts.inputs,
            "\(parts.outputs) plus the original inputs",
            "the starting materials of \(topicTitle)"
        ]
    }

    private func processParts(in text: String) -> (inputs: String, outputs: String)? {
        guard
            let usesRange = text.range(of: " uses ", options: .caseInsensitive),
            let makeRange = text.range(of: " to make ", options: .caseInsensitive),
            usesRange.upperBound < makeRange.lowerBound
        else {
            return nil
        }

        let inputs = cleaned(String(text[usesRange.upperBound..<makeRange.lowerBound]), fallback: "")
        let rawOutputs = String(text[makeRange.upperBound...])
        let outputs = cleaned(rawOutputs.trimmingCharacters(in: CharacterSet(charactersIn: ". ")), fallback: "")

        guard inputs.isEmpty == false, outputs.isEmpty == false else {
            return nil
        }

        return (inputs, outputs)
    }

    private func scopedQuestions(for topic: LearningTopic?) -> [LearningQuestion] {
        guard let topic else { return questions }
        return questions.filter { question in
            question.topicID == topic.id || question.topicTitle == topic.title
        }
    }

    private func scopedQuestions(for source: StudySource?) -> [LearningQuestion] {
        guard let source else { return questions }
        return questions.filter { question in
            question.sourceID == source.id
        }
    }

    private func scopedQuestions(for node: LearningCoverageNode) -> [LearningQuestion] {
        switch node.level {
        case .allNotes:
            return questions
        case .topic:
            return questions.filter { question in
                question.topicID?.uuidString == node.id || question.topicTitle == node.title
            }
        case .subtopic:
            return questions.filter { question in
                question.subtopicTitle == node.title
            }
        }
    }

    private func latestAttempts() -> [UUID: QuestionAttempt] {
        attempts.reduce(into: [:]) { result, attempt in
            if result[attempt.questionID] == nil {
                result[attempt.questionID] = attempt
            }
        }
    }

    private func priorityScore(for question: LearningQuestion, latestAttempt: QuestionAttempt?) -> Double {
        let attemptScore = latestAttempt?.score
        let weakness = 1 - (attemptScore ?? 0)
        let untestedBonus = latestAttempt == nil ? 2.0 : 0.0
        let firstRepBonus = latestAttempt == nil ? firstRepScore(for: question.type) : 0
        let recencyBonus: Double

        if let latestAttempt {
            let days = Calendar.current.dateComponents([.day], from: latestAttempt.createdAt, to: .now).day ?? 0
            recencyBonus = min(Double(days) * 0.15, 1.5)
        } else {
            recencyBonus = 0
        }

        return question.importance * 2
            + question.difficulty
            + question.type.weight
            + weakness * 2
            + untestedBonus
            + firstRepBonus
            + recencyBonus
    }

    private func firstRepScore(for type: LearningQuestion.QuestionType) -> Double {
        switch type {
        case .multipleChoice:
            2.2
        case .fillBlank:
            1.2
        case .flashcard:
            0.4
        case .shortAnswer:
            0
        }
    }

    private func scoreAnswer(_ response: String, for question: LearningQuestion) -> Double {
        let trimmedResponse = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedResponse.isEmpty == false else { return 0 }

        if question.type == .multipleChoice {
            return trimmedResponse == question.answer ? 1 : 0
        }

        let topicWords = normalizedWords(in: question.topicTitle)
        let responseWords = normalizedWords(in: trimmedResponse).subtracting(topicWords)
        let answerWords = normalizedWords(in: question.answer).subtracting(topicWords)
        guard responseWords.isEmpty == false, answerWords.isEmpty == false else { return 0 }

        let overlap = responseWords.intersection(answerWords)
        let responseCoverage = Double(overlap.count) / Double(max(responseWords.count, 1))
        let answerCoverage = Double(overlap.count) / Double(max(answerWords.count, 1))
        let matchedImportantConcept = overlap.contains { importantConceptWords.contains($0) }

        if question.type == .fillBlank {
            if normalizedText(trimmedResponse) == normalizedText(question.answer) {
                return 1
            }
            if answerWords.isSubset(of: responseWords) {
                return 1
            }
            if matchedImportantConcept, responseCoverage >= 0.34, answerCoverage >= 0.5 {
                return 1
            }
            if overlap.count >= 2 {
                return min(0.85, answerCoverage * 1.6)
            }
            return min(answerCoverage * 1.2, 0.45)
        }

        if responseWords.count <= 1 {
            return min(answerCoverage * 1.5, 0.3)
        }

        if matchedImportantConcept, responseCoverage >= 0.5, answerCoverage >= 0.45, overlap.count >= 2 {
            return min(0.9, answerCoverage * 1.25)
        }

        let score = answerCoverage * 0.8 + responseCoverage * 0.2
        let cappedScore = answerCoverage < 0.25 ? min(score, 0.5) : score
        return min(max(cappedScore, 0), 1)
    }

    private func semanticCoverageScore(response: String, for question: LearningQuestion) -> Double {
        guard question.type == .shortAnswer else { return 0 }

        let responseWords = normalizedWords(in: response)
        let answerWords = normalizedWords(in: question.answer)
        guard responseWords.isEmpty == false, answerWords.isEmpty == false else { return 0 }

        let answerText = question.answer.lowercased()
        if answerText.contains("programming language") || question.topicTitle.lowercased().contains("java") {
            return weightedConceptScore(
                responseWords: responseWords,
                groups: [
                    (["programming", "language"], 0.35),
                    (["object", "oriented"], 0.20),
                    (["run", "anywhere"], 0.15),
                    (["jvm"], 0.10),
                    (["memory", "safe"], 0.10),
                    (["high", "level"], 0.05),
                    (["general", "purpose"], 0.05)
                ]
            )
        }

        if answerText.contains("photosynthesis") {
            return weightedConceptScore(
                responseWords: responseWords,
                groups: [
                    (["light", "energy"], 0.20),
                    (["water"], 0.15),
                    (["carbon", "dioxide"], 0.20),
                    (["glucose"], 0.20),
                    (["oxygen"], 0.15),
                    (["make"], 0.10)
                ]
            )
        }

        if answerText.contains("gravity") {
            return weightedConceptScore(
                responseWords: responseWords,
                groups: [
                    (["force"], 0.25),
                    (["pulls"], 0.25),
                    (["mass"], 0.20),
                    (["toward"], 0.15),
                    (["earth", "center"], 0.15)
                ]
            )
        }

        return 0
    }

    private func weightedConceptScore(
        responseWords: Set<String>,
        groups: [([String], Double)]
    ) -> Double {
        let score = groups.reduce(0.0) { total, group in
            let requiredWords = group.0
            let weight = group.1
            let matchedCount = requiredWords.filter { responseWords.contains($0) }.count
            let coverage = Double(matchedCount) / Double(max(requiredWords.count, 1))
            return total + weight * coverage
        }

        return min(max(score, 0), 1)
    }

    private func normalizedWords(in text: String) -> Set<String> {
        Set(
            text
                .lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count > 2 }
                .map(canonicalAnswerWord)
                .filter { answerStopWords.contains($0) == false }
        )
    }

    private func normalizedText(_ text: String) -> String {
        text
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.isEmpty == false }
            .map(canonicalAnswerWord)
            .joined(separator: " ")
    }

    private func withTimeout<T>(
        seconds: UInt64,
        operation: @escaping () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }

            group.addTask {
                try await Task.sleep(nanoseconds: seconds * 1_000_000_000)
                throw GemmaServiceError.requestTimedOut
            }

            guard let result = try await group.next() else {
                throw GemmaServiceError.requestTimedOut
            }

            group.cancelAll()
            return result
        }
    }

    private func canonicalAnswerWord(_ word: String) -> String {
        switch word {
        case "sun", "sunlight", "solar":
            return "light"
        case "food", "sugar", "sugars":
            return "glucose"
        case "co2":
            return "dioxide"
        case "plant", "plants":
            return "photosynthesis"
        default:
            return word
        }
    }

    private var importantConceptWords: Set<String> {
        [
            "light",
            "energy",
            "water",
            "carbon",
            "dioxide",
            "glucose",
            "oxygen",
            "plant",
            "plants",
            "photosynthesis",
            "cell",
            "cells",
            "force",
            "mass",
            "acceleration",
            "function",
            "variable",
            "equation",
            "theme",
            "evidence"
        ]
    }

    private var answerStopWords: Set<String> {
        [
            "about",
            "after",
            "also",
            "from",
            "into",
            "make",
            "mainly",
            "only",
            "that",
            "their",
            "them",
            "these",
            "this",
            "uses",
            "with"
        ]
    }

    private func appendTurn(_ turn: TutorTurn) {
        turns.append(turn)
        conversationStore.save(turn)
    }

    private func recordXP(for action: LearningAction, reason: String) {
        let event = XPEvent(action: action, reason: reason)
        xpEvents.insert(event, at: 0)
        conversationStore.save(event)
        refreshLearningPlan()
    }

    private func refreshLearningPlan() {
        let newSuggestions = makeSuggestions()
        suggestions = newSuggestions
        conversationStore.replaceSuggestions(newSuggestions)
    }

    private func makeSuggestions() -> [LearningSuggestion] {
        guard sources.isEmpty == false else {
            return []
        }

        var suggestions: [LearningSuggestion] = []
        let dueCards = flashcards.filter(\.isDue).count
        let weakCards = flashcards.filter(\.isWeak).count

        if dueCards > 0 || weakCards > 0 {
            suggestions.append(
                LearningSuggestion(
                    action: .review,
                    title: "Review due cards",
                    detail: "\(max(dueCards, weakCards)) cards need attention. Earn \(LearningAction.review.baseXP) XP.",
                    priority: 100
                )
            )
        }

        if flashcards.isEmpty {
            suggestions.append(
                LearningSuggestion(
                    action: .makeCards,
                    title: "Make practice cards",
                    detail: "Turn saved notes into recall practice. Earn \(LearningAction.makeCards.baseXP) XP.",
                    priority: 90
                )
            )
        }

        let topicTitle = topics.first?.title ?? "your notes"

        suggestions.append(
            LearningSuggestion(
                action: .test,
                title: "Quiz \(topicTitle)",
                detail: "Retrieval practice is the fastest next rep. Earn \(LearningAction.test.baseXP) XP.",
                priority: 85
            )
        )

        suggestions.append(
            LearningSuggestion(
                action: .teach,
                title: "Explain \(topicTitle)",
                detail: "Warm up with the main idea. Earn \(LearningAction.teach.baseXP) XP.",
                priority: 60
            )
        )

        return suggestions.sorted { $0.priority > $1.priority }
    }

    private func groundedResponseText(_ response: String, matches: [StudySource]) -> String {
        guard matches.isEmpty else { return response }

        let normalizedResponse = response.lowercased()
        if normalizedResponse.contains("saved notes")
            || normalizedResponse.contains("local notes")
            || normalizedResponse.contains("saved memory")
            || normalizedResponse.contains("local memory") {
            return response
        }

        if sources.isEmpty {
            return "I do not have any saved notes yet. General answer: \(response)"
        }

        return "I do not have this in saved notes. General answer: \(response)"
    }

    private static func makeGemmaService(for configuration: ModelRuntimeConfiguration) -> GemmaService {
        switch configuration.mode {
        case .localServer:
            return OllamaGemmaService(configuration: configuration)
        case .onDevice:
            #if canImport(FoundationModels)
            if #available(iOS 26, *) {
                return OnDeviceModelService()
            }
            #endif
            return OnDeviceGemmaServicePlaceholder(model: configuration.modelName)
        }
    }

    private func parseTopics(from response: String, sourceID: UUID) -> [LearningTopic] {
        let lines = response
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }

        var parsedTopics: [LearningTopic] = []
        var pendingTitle: String?

        for line in lines {
            if let title = value(after: "Topic:", in: line) {
                pendingTitle = title
            } else if let summary = value(after: "Summary:", in: line), let title = pendingTitle {
                parsedTopics.append(
                    LearningTopic(
                        sourceID: sourceID,
                        title: title,
                        summary: summary
                    )
                )
                pendingTitle = nil
            }
        }

        return Array(parsedTopics.prefix(4))
    }

    private var learningParserSystemPrompt: String {
        """
        You are Accordian's learning parser.
        Return valid JSON only. Do not include markdown, prose, comments, or code fences.
        Use only the supplied notes.
        Extract a complete learning map for a student.
        Create a broad, high-signal question bank that can be saved in SQLite.
        Use judgment to test the most important concepts, relationships, definitions, causes, processes, misconceptions, and applications.
        Multiple-choice distractors must be plausible misconceptions from the same topic, not obvious throwaway answers.
        """
    }

    private func learningExtractionPrompt(for source: StudySource) -> String {
        """
        Extract topics, subtopics, concept segments, and many high-quality questions from these notes.

        Requirements:
        - Ignore webpage navigation, menus, edit links, references, donation prompts, account prompts, and table-of-contents fragments.
        - Extract the article/body concepts, not the page chrome.
        - Decide how many topics, subtopics, concept segments, and questions are needed from the notes.
        - Dense notes should create a larger learning bank; short notes should create a smaller one.
        - Do not pad with low-value questions just to make the bank larger.
        - Do not omit important concepts just to keep the bank small.
        - Use these question types only: multipleChoice, fillBlank, shortAnswer.
        - Prefer important learning checks over easy trivia.
        - Every important concept should be tested in more than one way.
        - multipleChoice questions must include exactly 4 choices and the answer must exactly match one choice.
        - multipleChoice incorrect choices must be plausible, same style and length as the correct answer, and based on common confusions from the supplied notes.
        - Do not use giveaway choices like "not mentioned", "unrelated", "all of the above", "none of the above", or joke answers.
        - Do not always put the correct multipleChoice answer first.
        - Every answer must be directly supported by the supplied notes.
        - fillBlank prompts should test one short missing concept, not a whole sentence or paragraph.
        - shortAnswer prompts should require synthesis, explanation, comparison, or application.
        - importance and difficulty must be numbers from 0.2 to 1.0.
        - Keep prompts and answers concise.

        JSON shape:
        {
          "topics": [
            {
              "title": "short title",
              "summary": "one sentence",
              "subtopics": [
                {
                  "title": "short subtopic",
                  "importance": 0.8,
                  "segments": [
                    {
                      "text": "single concept to learn",
                      "evidence": "direct supporting text from notes",
                      "importance": 0.8,
                      "difficulty": 0.6,
                      "questions": [
                        {
                          "type": "multipleChoice",
                          "prompt": "question",
                          "answer": "exact choice",
                          "choices": ["choice", "choice", "choice", "choice"],
                          "difficulty": 0.6
                        }
                      ]
                    }
                  ]
                }
              ]
            }
          ]
        }

        Notes title: \(source.title)
        Cleaned notes:
        \(learningText(for: source).prefix(20_000))
        """
    }

    private func parseLearningExtraction(from response: String) throws -> LearningExtraction {
        let jsonText = extractJSONObject(from: response)
        let data = Data(jsonText.utf8)
        return try JSONDecoder().decode(LearningExtraction.self, from: data)
    }

    private func extractJSONObject(from response: String) -> String {
        var text = response.trimmingCharacters(in: .whitespacesAndNewlines)

        if text.hasPrefix("```") {
            text = text
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```JSON", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard
            let start = text.firstIndex(of: "{"),
            let end = text.lastIndex(of: "}"),
            start <= end
        else {
            return text
        }

        return String(text[start...end])
    }

    private func materializeLearningExtraction(_ extraction: LearningExtraction, source: StudySource) -> (topics: [LearningTopic], segments: [LearningSegment], questions: [LearningQuestion]) {
        var topics: [LearningTopic] = []
        var segments: [LearningSegment] = []
        var questions: [LearningQuestion] = []

        for extractedTopic in extraction.topics {
            let topicTitle = cleaned(extractedTopic.title, fallback: source.title)
            let topic = LearningTopic(
                sourceID: source.id,
                title: topicTitle,
                summary: cleaned(extractedTopic.summary, fallback: "Found in \(source.title).")
            )
            topics.append(topic)

            for extractedSubtopic in extractedTopic.subtopics {
                let subtopicTitle = cleaned(extractedSubtopic.title, fallback: "Main idea")
                let importance = normalizedWeight(extractedSubtopic.importance)

                for extractedSegment in extractedSubtopic.segments ?? [] {
                    let segmentText = cleaned(extractedSegment.text, fallback: "")
                    guard segmentText.isEmpty == false else { continue }

                    let evidence = cleaned(extractedSegment.evidence ?? segmentText, fallback: segmentText)
                    let segment = LearningSegment(
                        sourceID: source.id,
                        topicID: topic.id,
                        topicTitle: topic.title,
                        subtopicTitle: subtopicTitle,
                        text: segmentText,
                        evidence: evidence,
                        importance: normalizedWeight(extractedSegment.importance ?? importance),
                        difficulty: normalizedWeight(extractedSegment.difficulty ?? 1)
                    )
                    segments.append(segment)

                    for extractedQuestion in extractedSegment.questions {
                        guard let type = questionType(from: extractedQuestion.type) else {
                            continue
                        }

                        let prompt = cleaned(extractedQuestion.prompt, fallback: "")
                        let answer = cleaned(extractedQuestion.answer, fallback: "")
                        guard prompt.isEmpty == false, answer.isEmpty == false else {
                            continue
                        }

                        let choices = normalizedChoices(
                            extractedQuestion.choices ?? [],
                            answer: answer,
                            type: type
                        )
                        guard type != .multipleChoice || choices.count == 4 else {
                            continue
                        }

                        questions.append(
                            LearningQuestion(
                                sourceID: source.id,
                                topicID: topic.id,
                                segmentID: segment.id,
                                topicTitle: topic.title,
                                subtopicTitle: subtopicTitle,
                                type: type,
                                prompt: prompt,
                                answer: type == .multipleChoice ? choices.first(where: { $0 == answer }) ?? answer : answer,
                                choices: choices,
                                importance: segment.importance,
                                difficulty: normalizedWeight(extractedQuestion.difficulty)
                            )
                        )
                    }
                }

                for extractedQuestion in extractedSubtopic.questions ?? [] {
                    guard let type = questionType(from: extractedQuestion.type) else {
                        continue
                    }

                    let prompt = cleaned(extractedQuestion.prompt, fallback: "")
                    let answer = cleaned(extractedQuestion.answer, fallback: "")
                    guard prompt.isEmpty == false, answer.isEmpty == false else {
                        continue
                    }

                    let choices = normalizedChoices(
                        extractedQuestion.choices ?? [],
                        answer: answer,
                        type: type
                    )
                    guard type != .multipleChoice || choices.count == 4 else {
                        continue
                    }

                    questions.append(
                        LearningQuestion(
                            sourceID: source.id,
                            topicID: topic.id,
                            topicTitle: topic.title,
                            subtopicTitle: subtopicTitle,
                            type: type,
                            prompt: prompt,
                            answer: type == .multipleChoice ? choices.first(where: { $0 == answer }) ?? answer : answer,
                            choices: choices,
                            importance: importance,
                            difficulty: normalizedWeight(extractedQuestion.difficulty)
                        )
                    )
                }
            }
        }

        return (topics, segments, questions)
    }

    private func cleaned(_ text: String, fallback: String) -> String {
        let value = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? fallback : String(value.prefix(280))
    }

    private func learningText(for source: StudySource) -> String {
        sanitizedLearningText(source.text, title: source.title)
    }

    private func sanitizedLearningText(_ rawText: String, title: String) -> String {
        let normalizedText = rawText
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: #"\[\d+\]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty == false,
           let bodyStart = normalizedText.range(of: "\(title) is", options: [.caseInsensitive, .diacriticInsensitive]) {
            return String(normalizedText[bodyStart.lowerBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let rejectedFragments = [
            "wikipediathe free encyclopedia",
            "search wikipedia",
            "create account",
            "log in",
            "contents hide",
            "donate",
            "appearance hide",
            "personal tools",
            "page discussion",
            "read edit view history"
        ]

        let cleanedLines = rawText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { line in
                guard line.count > 24 else { return false }
                let lowercasedLine = line.lowercased()
                return rejectedFragments.contains { lowercasedLine.contains($0) } == false
            }

        let joined = cleanedLines
            .joined(separator: " ")
            .replacingOccurrences(of: #"\[\d+\]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return joined.isEmpty ? normalizedText : joined
    }

    private func normalizedWeight(_ value: Double) -> Double {
        min(max(value, 0.2), 1.0)
    }

    private func questionType(from text: String) -> LearningQuestion.QuestionType? {
        switch text.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "multipleChoice":
            return .multipleChoice
        case "fillBlank":
            return .fillBlank
        case "shortAnswer":
            return .shortAnswer
        default:
            return nil
        }
    }

    private func normalizedChoices(_ choices: [String], answer: String, type: LearningQuestion.QuestionType) -> [String] {
        guard type == .multipleChoice else { return [] }

        let cleanedAnswer = cleaned(answer, fallback: answer)
        var cleanedChoices = choices
            .map { cleaned($0, fallback: "") }
            .filter { $0.isEmpty == false }
            .reduce(into: [String]()) { result, choice in
                if result.contains(choice) == false {
                    result.append(choice)
                }
            }

        if cleanedChoices.contains(cleanedAnswer) == false {
            cleanedChoices.insert(cleanedAnswer, at: 0)
        }

        guard cleanedChoices.count >= 4 else {
            return []
        }

        var firstFour = Array(cleanedChoices.prefix(4))
        if firstFour.contains(cleanedAnswer) == false {
            firstFour = [cleanedAnswer] + firstFour.prefix(3)
        }

        guard
            firstFour.count == 4,
            let answerIndex = firstFour.firstIndex(of: cleanedAnswer)
        else {
            return firstFour
        }

        let targetIndex = stableAnswerIndex(for: cleanedAnswer, choiceCount: firstFour.count)
        if answerIndex != targetIndex {
            firstFour.swapAt(answerIndex, targetIndex)
        }

        return firstFour
    }

    private func stableAnswerIndex(for answer: String, choiceCount: Int) -> Int {
        guard choiceCount > 1 else { return 0 }

        let scalarTotal = answer.unicodeScalars.reduce(0) { partialResult, scalar in
            partialResult + Int(scalar.value)
        }

        return max(1, scalarTotal % choiceCount)
    }

    private func fallbackTopics(for source: StudySource) -> [LearningTopic] {
        let noteTitle = cleaned(source.title.replacingOccurrences(of: "Untitled Notes", with: ""), fallback: "")
        let noteText = learningText(for: source)
        let title = noteTitle.isEmpty ? topicTitle(from: noteText) : noteTitle
        let noteSummary = cleaned(noteText.replacingOccurrences(of: "\n", with: " "), fallback: "")
        let summary = noteSummary.isEmpty ? "Found in \(source.title)." : String(noteSummary.prefix(180))

        return [
            LearningTopic(
                sourceID: source.id,
                title: title,
                summary: summary
            )
        ]
    }

    private func parseFlashcards(from response: String, sourceID: UUID?, sourceTitle: String, referenceText: String) -> [StudyFlashcard] {
        let lines = response
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }

        var cards: [StudyFlashcard] = []
        var pendingDeck = sourceTitle == "Recent chat" ? topicTitle(from: referenceText) : sourceTitle
        var pendingFront: String?
        var pendingTopic = topicTitle(from: referenceText)
        var pendingType: StudyFlashcard.CardType = .recall

        for line in lines {
            if let deck = value(after: "Deck:", in: line) {
                pendingDeck = deck
            } else if let topic = value(after: "Topic:", in: line) {
                pendingTopic = topic
            } else if let type = value(after: "Type:", in: line) {
                pendingType = cardType(from: type)
            } else if let front = value(after: "Front:", in: line) {
                pendingFront = front
            } else if let back = value(after: "Back:", in: line), let front = pendingFront {
                cards.append(
                    StudyFlashcard(
                        sourceID: sourceID,
                        sourceTitle: sourceTitle,
                        deckTitle: pendingDeck,
                        topic: pendingTopic,
                        cardType: pendingType,
                        front: front,
                        back: back,
                        referenceText: referenceText
                    )
                )
                pendingFront = nil
                pendingType = .recall
            }
        }

        return Array(cards.prefix(3))
    }

    private func fallbackFlashcards(from text: String, source: StudySource?, referenceText: String) -> [StudyFlashcard] {
        let cleanText = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let answer = cleanText.isEmpty ? "Review this answer in Accordian." : cleanText

        return [
            StudyFlashcard(
                sourceID: source?.id,
                sourceTitle: source?.title ?? "Recent chat",
                deckTitle: source?.title ?? topicTitle(from: answer),
                topic: topicTitle(from: "\(source?.title ?? "") \(answer)"),
                cardType: .recall,
                front: "What is the main idea?",
                back: String(answer.prefix(220)),
                referenceText: referenceText
            )
        ]
    }

    private func value(after prefix: String, in line: String) -> String? {
        guard line.localizedCaseInsensitiveContains(prefix) else { return nil }

        let parts = line.split(separator: ":", maxSplits: 1)
        guard parts.count == 2 else { return nil }

        let value = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func cardType(from text: String) -> StudyFlashcard.CardType {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "/", with: "")
            .replacingOccurrences(of: " ", with: "")

        switch normalized {
        case "definition":
            return .definition
        case "causeeffect", "causeandeffect":
            return .causeEffect
        case "comparecontrast", "compareandcontrast":
            return .compareContrast
        case "process", "order", "sequence":
            return .process
        case "misconception", "mistake", "commonmistake":
            return .misconception
        case "application", "apply":
            return .application
        default:
            return .recall
        }
    }

    private func conversationHistory(for prompt: String, matches providedMatches: [StudySource]? = nil) -> [GemmaMessage] {
        var history = turns.map { turn in
            GemmaMessage(
                role: turn.speaker == .learner ? "user" : "assistant",
                content: turn.text
            )
        }

        let matches = providedMatches ?? relevantSources(for: prompt)
        if matches.isEmpty == false {
            let context = matches.map { source in
                """
                Notes: \(source.title)
                \(source.text.prefix(1_200))
                """
            }
            .joined(separator: "\n\n")

            history.insert(
                GemmaMessage(
                    role: "system",
                    content: """
                    Use these student-provided notes when relevant. If they do not answer the question, say so briefly.

                    \(context)
                    """
                ),
                at: 0
            )
        } else {
            let memoryState = sources.isEmpty
                ? "The student has not saved any notes yet."
                : "No saved notes matched this question."

            history.insert(
                GemmaMessage(
                    role: "system",
                    content: """
                    \(memoryState)
                    If the question asks about saved notes, class material, or what the student learned, say that no matching notes are available and suggest adding or naming the material.
                    If you answer from general knowledge, make that distinction briefly.
                    """
                ),
                at: 0
            )
        }

        return history
    }

    private func recentStudyContext(for text: String) -> String {
        let recentLearnerText = turns
            .reversed()
            .filter { $0.speaker == .learner }
            .prefix(3)
            .map(\.text)
            .joined(separator: " ")
        return "\(recentLearnerText) \(text)"
    }

    private func referenceText(for text: String, sources: [StudySource]) -> String {
        sources.map { source in
            """
            Notes: \(source.title)
            \(source.text.prefix(900))
            """
        }
        .joined(separator: "\n\n")
    }

    private func topicTitle(from text: String) -> String {
        let terms = searchableTerms(in: text)
        guard let first = terms.first else { return "General" }
        return first.prefix(1).uppercased() + first.dropFirst()
    }

    private static func practiceFocusText(from turns: [TutorTurn]) -> String {
        turns
            .reversed()
            .filter { $0.speaker == .learner }
            .prefix(4)
            .map(\.text)
            .joined(separator: " ")
    }

    private func relevantSources(for prompt: String) -> [StudySource] {
        let queryTerms = searchableTerms(in: prompt)
        guard queryTerms.isEmpty == false, isMemoryWidePrompt(prompt, terms: queryTerms) == false else {
            return Array(sources.prefix(2))
        }

        return sources
            .filter { $0.status == .ready }
            .map { source in
                let searchableText = "\(source.title) \(source.text)".lowercased()
                let score = queryTerms.reduce(0) { total, term in
                    searchableText.contains(term) ? total + 1 : total
                }
                return RankedSource(source: source, score: score)
            }
            .filter { $0.score > 0 }
            .sorted { lhs, rhs in
                if lhs.score == rhs.score {
                    return lhs.source.createdAt > rhs.source.createdAt
                }
                return lhs.score > rhs.score
            }
            .prefix(2)
            .map(\.source)
    }

    private func isMemoryWidePrompt(_ prompt: String, terms: [String]) -> Bool {
        let normalizedPrompt = prompt.lowercased()
        let memoryTerms: Set<String> = [
            "memory",
            "saved",
            "notes",
            "note",
            "source",
            "sources",
            "material",
            "materials",
            "learn",
            "learned",
            "review",
            "summarize",
            "summary",
            "quiz"
        ]

        if terms.contains(where: { memoryTerms.contains($0) }) {
            return true
        }

        return normalizedPrompt.contains("what did i learn")
            || normalizedPrompt.contains("what should i review")
            || normalizedPrompt.contains("quiz me")
            || normalizedPrompt.contains("my saved")
    }

    private func searchableTerms(in text: String) -> [String] {
        text
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 3 }
    }
}

private struct RankedSource {
    let source: StudySource
    let score: Int
}

private enum LearningExtractionError: Error {
    case insufficientQuestionBank
}
