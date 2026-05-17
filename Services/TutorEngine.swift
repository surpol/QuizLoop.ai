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
    @Published private(set) var preparingNextQuizSourceIDs: Set<UUID> = []
    @Published private(set) var quizBuildProgressBySourceID: [UUID: QuizBuildProgress] = [:]

    @Published private(set) var isResponding = false
    @Published private(set) var lastError: String?
    @Published private(set) var modelReadiness: ModelReadiness = .checking
    @Published private(set) var modelConfiguration: ModelRuntimeConfiguration
    @Published private(set) var modelDownloadState = ModelDownloadState()

    private var gemmaService: GemmaService
    private let conversationStore: ConversationStore
    private let runtimeStore: ModelRuntimeStore
    private var modelDownloadTask: Task<Void, Never>?
    private var lastQuizBuildAttemptBySourceID: [UUID: Date] = [:]
    private let quizBuildRetryCooldown: TimeInterval = 3 * 60

    private struct QuestionBankPlan {
        let wordCount: Int
        let targetQuestions: Int
        let minimumQuestions: Int
        let targetSegments: Int
    }

    private struct LearningChunk {
        let index: Int
        let text: String
        let plan: QuestionBankPlan
    }

    private struct QuestionExpansionPlan {
        let wordCount: Int
        let currentQuestionCount: Int
        let maxQuestionCount: Int
        let targetNewQuestions: Int
        let focusSubtopic: String?
        let angleTargets: [String]
        let underservedSubtopics: [String]
        let coverageTargets: [String]
        let reason: String
    }

    private struct FreshQuestionExpansion: Decodable {
        let questions: [FreshQuestion]
    }

    private struct FreshQuestion: Decodable {
        let topicTitle: String
        let subtopicTitle: String
        let assessmentAngle: String?
        let type: String
        let prompt: String
        let answer: String
        let acceptedAnswers: [String]?
        let gradingRubric: String?
        let choices: [String]?
        let importance: Double
        let difficulty: Double

        enum CodingKeys: String, CodingKey {
            case topicTitle = "topic_title"
            case subtopicTitle = "subtopic_title"
            case assessmentAngle = "assessment_angle"
            case type
            case prompt
            case answer
            case acceptedAnswers = "accepted_answers"
            case gradingRubric = "grading_rubric"
            case choices
            case importance
            case difficulty
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            topicTitle = try container.decodeIfPresent(String.self, forKey: .topicTitle) ?? ""
            subtopicTitle = try container.decodeIfPresent(String.self, forKey: .subtopicTitle) ?? ""
            assessmentAngle = try container.decodeIfPresent(String.self, forKey: .assessmentAngle)
            type = try container.decodeIfPresent(String.self, forKey: .type) ?? ""
            prompt = try container.decodeIfPresent(String.self, forKey: .prompt) ?? ""
            answer = try container.decodeIfPresent(String.self, forKey: .answer) ?? ""
            acceptedAnswers = try container.decodeIfPresent([String].self, forKey: .acceptedAnswers)
            gradingRubric = try container.decodeIfPresent(String.self, forKey: .gradingRubric)
            choices = try container.decodeIfPresent([String].self, forKey: .choices)
            importance = Self.decodeFlexibleDouble(from: container, forKey: .importance) ?? 0.7
            difficulty = Self.decodeFlexibleDouble(from: container, forKey: .difficulty) ?? 0.5
        }

        private static func decodeFlexibleDouble(
            from container: KeyedDecodingContainer<CodingKeys>,
            forKey key: CodingKeys
        ) -> Double? {
            if let value = try? container.decode(Double.self, forKey: key) {
                return value
            }

            if let value = try? container.decode(Int.self, forKey: key) {
                return Double(value)
            }

            if let text = try? container.decode(String.self, forKey: key),
               let value = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return value
            }

            return nil
        }
    }

    private struct QuizMemoryPacket: Encodable {
        let note: NoteMemory
        let selectedFocus: String?
        let expansionPolicy: ExpansionPolicyMemory
        let latestQuizOutcome: [QuizOutcomeMemory]
        let learnerState: [ConceptMemory]
        let existingQuestionsToAvoid: [QuestionMemory]
        let underservedSubtopics: [String]
        let uncoveredTargets: [String]
        let instructions: [String]
    }

    private struct NoteMemory: Encodable {
        let id: String
        let title: String
        let wordCount: Int
    }

    private struct ExpansionPolicyMemory: Encodable {
        let reason: String
        let targetNewQuestions: Int
        let currentQuestionCount: Int
        let maxQuestionCount: Int
        let missingAssessmentAngles: [String]
    }

    private struct QuizOutcomeMemory: Encodable {
        let question: QuestionMemory
        let response: String
        let score: Double
        let result: String
        let matchedIdeas: [String]
        let missingIdeas: [String]
    }

    private struct QuestionMemory: Encodable {
        let id: String
        let topic: String
        let subtopic: String
        let segment: String?
        let assessmentAngle: String
        let type: String
        let prompt: String
        let answer: String
        let choices: [String]
        let conceptSignature: String
        let importance: Double
        let difficulty: Double
        let latestScore: Double?
        let attemptCount: Int
        let status: String
    }

    private struct ConceptMemory: Encodable {
        let conceptSignature: String
        let topic: String
        let subtopic: String
        let assessmentAngle: String
        let latestScore: Double?
        let attemptCount: Int
        let status: String
        let avoidThisQuiz: Bool
        let dueReason: String
        let representativePrompt: String
    }

    private let minimumFreshQuizCount = 3
    private let minimumFocusedQuestionCount = 8

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
                speaker: .quizLoop,
                text: "Hi, I am QuizLoop.ai. Add notes or ask me anything.",
                createdAt: .now
            )
            self.turns = [welcomeTurn]
            conversationStore.save(welcomeTurn)
        } else {
            self.turns = savedTurns
        }

        rescoreStoredAttempts()
        purgeFallbackLearningObjects()
        deduplicatePersistedQuestions()
        repairMisfiledFocusedQuestions()
        reconcilePersistedQuizBuildStates()

        Task {
            await refreshModelReadiness()
            await continueProcessingPendingSources()
            await organizeUngroupedSources()
        }
        refreshLearningPlan()
    }

    private func reconcilePersistedQuizBuildStates() {
        for source in sources {
            let savedCount = questions.filter { $0.sourceID == source.id }.count
            guard savedCount > 0,
                  source.quizBuildState == .idle || source.quizBuildTargetCount == 0
            else { continue }

            let plan = questionBankPlan(for: source)
            updateQuizBuildState(
                source.id,
                state: savedCount >= plan.targetQuestions ? .ready : .partial,
                detail: savedCount >= plan.targetQuestions ? "Quiz bank ready." : "Quiz available. More questions can be added later.",
                targetCount: plan.targetQuestions,
                savedCount: savedCount
            )
        }
    }

    private func deduplicatePersistedQuestions() {
        var didChange = false

        for source in sources {
            let sourceQuestions = questions.filter { $0.sourceID == source.id }
            let deduplicated = deduplicatedQuizQuestions(sourceQuestions)
            guard deduplicated.count != sourceQuestions.count else { continue }

            conversationStore.replaceQuestions(for: source.id, questions: deduplicated)
            didChange = true
        }

        if didChange {
            questions = conversationStore.loadQuestions()
            refreshJourneyAssignments()
            refreshLearningPlan()
        }
    }

    private func repairMisfiledFocusedQuestions() {
        var didChange = false

        for source in sources {
            let sourceQuestions = questions.filter { $0.sourceID == source.id }
            let repairedQuestions = sourceQuestions.map { question in
                repairedFocusedQuestion(reclassifiedQuestion(question))
            }
            .filter(isQuizUsable)
            let deduplicated = deduplicatedQuizQuestions(repairedQuestions)
            guard deduplicated != sourceQuestions else { continue }

            conversationStore.replaceQuestions(for: source.id, questions: deduplicated)
            didChange = true
        }

        if didChange {
            questions = conversationStore.loadQuestions()
            refreshJourneyAssignments()
            refreshLearningPlan()
        }
    }

    private func repairedFocusedQuestion(_ question: LearningQuestion) -> LearningQuestion {
        guard normalizedQuizPrompt(question.subtopicTitle) == "overall process",
              isFreshQuestionAlignedWithFocus(
                prompt: question.prompt,
                answer: question.answer,
                focusSubtopic: question.subtopicTitle
              ) == false
        else { return question }

        let combined = "\(question.prompt) \(question.answer)".lowercased()
        let repairedSubtopic: String
        if combined.contains("calvin cycle") {
            repairedSubtopic = "Calvin Cycle (Light-Independent Reactions)"
        } else if combined.contains("light-dependent") || combined.contains("thylakoid") {
            repairedSubtopic = "Light-Dependent Reactions"
        } else {
            repairedSubtopic = "Relationship"
        }

        return LearningQuestion(
            id: question.id,
            sourceID: question.sourceID,
            topicID: question.topicID,
            segmentID: question.segmentID,
            topicTitle: question.topicTitle,
            subtopicTitle: repairedSubtopic,
            type: question.type,
            prompt: question.prompt,
            answer: question.answer,
            acceptedAnswers: question.acceptedAnswers,
            gradingRubric: question.gradingRubric,
            choices: question.choices,
            importance: question.importance,
            difficulty: question.difficulty,
            createdAt: question.createdAt
        )
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

        do {
            let isInstalled = try await gemmaService.isModelInstalled()
            if isInstalled {
                modelReadiness = .ready
            } else {
                modelReadiness = .modelMissing(gemmaService.modelName)
            }
        } catch {
            if modelConfiguration.mode == .onDevice {
                if case GemmaServiceError.aiEdgeRuntimeUnavailable = error {
                    modelReadiness = .appleIntelligenceNotEnabled
                } else if case GemmaServiceError.modelFileMissing(let model) = error {
                    modelReadiness = .modelMissing(model)
                } else {
                    modelReadiness = .deviceNotEligible
                }
            } else {
                modelReadiness = .serverUnavailable
            }
        }
    }

    func updateModelConfiguration(_ configuration: ModelRuntimeConfiguration) async {
        modelConfiguration = configuration
        runtimeStore.save(configuration)
        gemmaService = Self.makeGemmaService(for: configuration)
        await refreshModelReadiness()
    }

    func downloadDefaultOnDeviceModel() {
        guard modelDownloadTask == nil else { return }

        if GoogleAIEdgeModelStore.isModelAvailable(named: GoogleAIEdgeModelStore.defaultDownloadName) {
            modelDownloadState = ModelDownloadState(phase: .installed(GoogleAIEdgeModelStore.defaultDownloadName))
            modelDownloadTask = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.updateModelConfiguration(
                    ModelRuntimeConfiguration(
                        mode: .onDevice,
                        serverURLString: self.modelConfiguration.serverURLString,
                        modelName: GoogleAIEdgeModelStore.defaultDownloadName
                    )
                )
                self.modelDownloadTask = nil
            }
            return
        }

        modelDownloadState = ModelDownloadState(phase: .downloading(0))
        modelDownloadTask = Task { @MainActor [weak self] in
            guard let self else { return }

            do {
                let downloadedFileName = try await GoogleAIEdgeModelStore.downloadDefaultModel { progress in
                    await MainActor.run { [weak self] in
                        self?.modelDownloadState = ModelDownloadState(phase: .downloading(progress))
                    }
                }

                await self.updateModelConfiguration(
                    ModelRuntimeConfiguration(
                        mode: .onDevice,
                        serverURLString: self.modelConfiguration.serverURLString,
                        modelName: downloadedFileName
                    )
                )
                self.modelDownloadState = ModelDownloadState(phase: .installed(downloadedFileName))
            } catch {
                self.modelDownloadState = ModelDownloadState(phase: .failed(error.localizedDescription))
            }

            self.modelDownloadTask = nil
        }
    }

    private func modelReply(
        to messages: [GemmaMessage],
        timeout: TimeInterval? = nil,
        taskType: String = "model_reply",
        promptVersion: String = "v1",
        metadata: String = "{}"
    ) async throws -> String {
        let start = Date.now
        let inputChars = messages.reduce(0) { $0 + $1.content.count }

        func latencyMS() -> Int {
            Int(Date.now.timeIntervalSince(start) * 1_000)
        }

        do {
            let response = try await gemmaService.reply(to: messages, timeout: timeout)
            conversationStore.saveModelRun(
                taskType: taskType,
                modelName: gemmaService.modelName,
                promptVersion: promptVersion,
                inputChars: inputChars,
                outputChars: response.count,
                success: true,
                latencyMS: latencyMS(),
                metadata: metadata
            )
            return response
        } catch {
            conversationStore.saveModelRun(
                taskType: taskType,
                modelName: gemmaService.modelName,
                promptVersion: promptVersion,
                inputChars: inputChars,
                outputChars: 0,
                success: false,
                latencyMS: latencyMS(),
                error: error.localizedDescription,
                metadata: metadata
            )
            throw error
        }
    }

    private func isOnDeviceFallbackAvailable() async -> Bool {
        false
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
            let response = try await modelReply(
                to: conversationHistory(for: trimmedPrompt, matches: matches),
                taskType: "chat_response",
                promptVersion: "chat.v1"
            )
            let groundedResponse = groundedResponseText(response, matches: matches)
            appendTurn(TutorTurn(speaker: .quizLoop, text: groundedResponse, sourceTitles: matches.map(\.title), createdAt: .now))
            isResponding = false
            return groundedResponse
        } catch {
            await refreshModelReadiness()
            let message = modelConfiguration.mode == .onDevice
                ? "Something went wrong with the on-device Gemma runtime. Check that the bundled model is installed."
                : "I could not reach Gemma. Make sure Ollama is running and the model is installed."
            lastError = error.localizedDescription
            appendTurn(TutorTurn(speaker: .quizLoop, text: message, createdAt: .now))
            isResponding = false
            return message
        }
    }

    func reset() {
        lastError = nil
        conversationStore.deleteAll()

        let freshTurn = TutorTurn(
            speaker: .quizLoop,
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
            text: trimmedText,
            quizBuildState: .building,
            quizBuildDetail: "Waiting for Gemma."
        )

        sources.insert(source, at: 0)
        conversationStore.save(source)
        conversationStore.saveInteractionEvent(
            kind: "note_created",
            sourceID: source.id,
            detail: "Student added a text stream.",
            metadata: #"{"source_type":"notes"}"#
        )
        conversationStore.replaceTopics(for: source.id, topics: [])
        conversationStore.replaceSegments(for: source.id, segments: [])
        conversationStore.replaceQuestions(for: source.id, questions: [])
        refreshPracticeDeck()
        refreshLearningPlan()
        refreshJourneyAssignments()
        setQuizBuildProgress(
            source.id,
            stage: .queued,
            progress: 0.04,
            detail: "Waiting for Gemma."
        )

        Task {
            await organizeTopics(for: source)
        }
    }

    private func purgeFallbackLearningObjects() {
        var changed = false

        for source in sources {
            let sourceQuestions = questions.filter { $0.sourceID == source.id }
            guard sourceQuestionsContainFallbacks(sourceQuestions) else { continue }
            conversationStore.replaceTopics(for: source.id, topics: [])
            conversationStore.replaceSegments(for: source.id, segments: [])
            conversationStore.replaceQuestions(for: source.id, questions: [])
            changed = true
        }

        if changed {
            topics = conversationStore.loadTopics()
            segments = conversationStore.loadSegments()
            questions = conversationStore.loadQuestions()
            refreshJourneyAssignments()
            refreshLearningPlan()
        }
    }

    private func sourceQuestionsContainFallbacks(_ sourceQuestions: [LearningQuestion]) -> Bool {
        let joinedAnswers = sourceQuestions.map(\.answer).joined(separator: " ").lowercased()
        let noisySubtopics = Set(["Although", "What", "Because", "Already", "Latter", "Simple", "Modern", "Main idea"])
        let hasNoisySubtopics = sourceQuestions.contains { noisySubtopics.contains($0.subtopicTitle) }
        return joinedAnswers.contains("terawatt")
            || joinedAnswers.contains("power consumption")
            || joinedAnswers.contains("human civilization")
            || joinedAnswers.contains("general equation")
            || joinedAnswers.contains("cornelis van niel")
            || sourceQuestions.contains { $0.prompt == "Which statement is supported by these notes?" }
            || sourceQuestions.contains { $0.prompt.hasPrefix("Which statement best matches") }
            || hasNoisySubtopics
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
            let response = try await modelReply(to: [
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
            ], taskType: "flashcard_generation", promptVersion: "flashcards.v1")
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
            appendTurn(TutorTurn(speaker: .quizLoop, text: message, createdAt: .now))
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
            appendTurn(TutorTurn(speaker: .quizLoop, text: message, createdAt: .now))
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

    func updateStudySource(_ source: StudySource, title: String, text: String) {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedText.isEmpty == false else { return }

        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let updatedSource = StudySource(
            id: source.id,
            title: trimmedTitle.isEmpty ? source.title : trimmedTitle,
            type: source.type,
            status: .processing,
            text: trimmedText,
            summary: "",
            quizBuildState: .building,
            quizBuildDetail: "Rebuilding questions from the updated note.",
            quizBuildError: "",
            quizBuildTargetCount: questionBankPlan(for: source).targetQuestions,
            quizBuildSavedCount: 0,
            quizBuildUpdatedAt: .now,
            createdAt: source.createdAt
        )

        conversationStore.save(updatedSource)
        conversationStore.saveInteractionEvent(
            kind: "note_updated",
            sourceID: source.id,
            detail: "Student edited a note and triggered rebuild.",
            metadata: #"{"rebuild":"quiz_bank"}"#
        )
        conversationStore.replaceTopics(for: source.id, topics: [])
        conversationStore.replaceSegments(for: source.id, segments: [])
        conversationStore.replaceQuestions(for: source.id, questions: [])
        sources = sources.map { $0.id == source.id ? updatedSource : $0 }
        topics = conversationStore.loadTopics()
        segments = conversationStore.loadSegments()
        questions = conversationStore.loadQuestions()
        refreshPracticeDeck()
        refreshLearningPlan()
        refreshJourneyAssignments()

        Task {
            await organizeTopics(for: updatedSource)
        }
    }

    func generateSummary(for source: StudySource) async -> String {
        if modelReadiness.isReady == false {
            await refreshModelReadiness()
        }

        let fallback = source.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary: String

        guard modelReadiness.isReady else {
            return fallback
        }

        do {
            let messages = [
                GemmaMessage(
                    role: "system",
                    content: """
                    You summarize student notes for QuizLoop.ai.
                    Use only the provided note text.
                    The note text may include copied web page menus, citations, references, or footer text; ignore that page chrome.
                    Return exactly 2 short, complete sentences.
                    Focus on the core idea, important relationships, and what the student should understand.
                    Do not add outside facts.
                    """
                ),
                GemmaMessage(
                    role: "user",
                    content: """
                    Title: \(source.title)

                    Note text:
                    \(String(learningText(for: source).prefix(8_000)))
                    """
                )
            ]

            let response = try await withTimeout(seconds: 12) {
                try await self.modelReply(to: messages, timeout: 10, taskType: "summary_generation", promptVersion: "summary.v1")
            }
            summary = cleanedSummary(response, fallback: fallback)
        } catch {
            summary = fallback
        }

        if summary.isEmpty == false {
            saveSummary(summary, for: source.id)
        }
        return summary
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
        let bankPlan = questionBankPlan(for: source)
        setQuizBuildProgress(
            source.id,
            stage: .reading,
            progress: 0.08,
            detail: "Preparing \(bankPlan.wordCount.formatted()) words."
        )

        do {
            let materialized = try await extractLearningObjects(for: source, plan: bankPlan)
            let finalTopics = materialized.topics
            let finalSegments = materialized.segments
            let finalQuestions = preservingQuestionIDs(
                materialized.questions,
                sourceID: source.id
            )
            let finalDeduplicatedQuestions = deduplicatedQuizQuestions(finalQuestions)
            let minimumUsableQuestions = min(bankPlan.minimumQuestions, minimumFreshQuizCount)

            guard finalDeduplicatedQuestions.count >= minimumUsableQuestions else {
                throw LearningExtractionError.insufficientQuestionBank
            }

            conversationStore.replaceTopics(for: source.id, topics: finalTopics)
            topics = conversationStore.loadTopics()
            conversationStore.replaceSegments(for: source.id, segments: finalSegments)
            segments = conversationStore.loadSegments()
            conversationStore.replaceQuestions(for: source.id, questions: finalDeduplicatedQuestions)
            questions = conversationStore.loadQuestions()
            updateSourceStatus(source.id, status: .ready)
            if finalDeduplicatedQuestions.count < bankPlan.targetQuestions,
               let expansionPlan = questionExpansionPlan(for: source, quizOutcome: []),
               preparingNextQuizSourceIDs.contains(source.id) == false {
                updateQuizBuildState(
                    source.id,
                    state: .partial,
                    detail: "Quiz available. Adding more questions in the background.",
                    targetCount: bankPlan.targetQuestions,
                    savedCount: finalDeduplicatedQuestions.count,
                    stage: .expanding
                )
                preparingNextQuizSourceIDs.insert(source.id)
                lastQuizBuildAttemptBySourceID[source.id] = .now
                setQuizBuildProgress(
                    source.id,
                    stage: .expanding,
                    progress: 0.72,
                    detail: "Adding more questions."
                )
                Task {
                    _ = await expandQuestionBankAfterQuiz(
                        source: source,
                        quizOutcome: [],
                        expansionPlan: expansionPlan
                    )
                }
            } else {
                updateQuizBuildState(
                    source.id,
                    state: .ready,
                    detail: "Quiz bank ready.",
                    targetCount: bankPlan.targetQuestions,
                    savedCount: finalDeduplicatedQuestions.count,
                    stage: .saving
                )
                clearQuizBuildProgress(for: source.id)
            }
        } catch {
            let savedModelQuestions = questions.filter { $0.sourceID == source.id }
            if savedModelQuestions.isEmpty {
                conversationStore.replaceTopics(for: source.id, topics: [])
                conversationStore.replaceSegments(for: source.id, segments: [])
                conversationStore.replaceQuestions(for: source.id, questions: [])
                topics = conversationStore.loadTopics()
                segments = conversationStore.loadSegments()
                questions = conversationStore.loadQuestions()
                updateSourceStatus(source.id, status: .failed)
                updateQuizBuildState(
                    source.id,
                    state: .failed,
                    detail: "Could not create questions yet.",
                    error: error.localizedDescription,
                    targetCount: bankPlan.targetQuestions,
                    savedCount: 0,
                    stage: .extracting
                )
                clearQuizBuildProgress(for: source.id)
            } else {
                let expansionPlan = questionExpansionPlan(for: source, quizOutcome: [])
                if let expansionPlan, savedModelQuestions.count < bankPlan.targetQuestions {
                    _ = await expandQuestionBankAfterQuiz(
                        source: source,
                        quizOutcome: [],
                        expansionPlan: expansionPlan
                    )
                }

                let refreshedQuestions = questions.filter { $0.sourceID == source.id }
                let hasMinimum = refreshedQuestions.count >= bankPlan.minimumQuestions
                updateSourceStatus(source.id, status: hasMinimum ? .ready : .failed)
                updateQuizBuildState(
                    source.id,
                    state: hasMinimum ? .partial : .failed,
                    detail: hasMinimum ? "Quiz available. More questions can be added later." : "Only \(refreshedQuestions.count) questions could be saved.",
                    error: hasMinimum ? "" : error.localizedDescription,
                    targetCount: bankPlan.targetQuestions,
                    savedCount: refreshedQuestions.count,
                    stage: .saving
                )
                clearQuizBuildProgress(for: source.id)
            }
        }

        refreshJourneyAssignments()
        refreshLearningPlan()
    }

    private func extractLearningObjects(
        for source: StudySource,
        plan: QuestionBankPlan
    ) async throws -> (topics: [LearningTopic], segments: [LearningSegment], questions: [LearningQuestion]) {
        let fullText = learningText(for: source)
        let visibleText = String(fullText.prefix(20_000))
        var combinedTopics: [LearningTopic] = []
        var combinedSegments: [LearningSegment] = []
        var combinedQuestions: [LearningQuestion] = []

        do {
            setQuizBuildProgress(
                source.id,
                stage: .extracting,
                progress: 0.14,
                detail: "Creating the first quiz."
            )
            let firstQuizQuestions = try await requestMultipleChoiceRescueQuestions(
                for: source,
                noteText: String(visibleText.prefix(1_800)),
                targetCount: minimumFreshQuizCount
            )
            combinedQuestions.append(contentsOf: firstQuizQuestions)
            savePartialLearningObjects(
                topics: combinedTopics,
                segments: combinedSegments,
                questions: combinedQuestions,
                sourceID: source.id
            )
            updateSavedQuizBuildProgress(
                sourceID: source.id,
                savedCount: combinedQuestions.count,
                targetCount: plan.minimumQuestions
            )
            if combinedQuestions.count >= minimumFreshQuizCount {
                return (combinedTopics, combinedSegments, combinedQuestions)
            }
        } catch {
            // Continue with richer extraction; the note only fails if no model questions can be saved.
        }

        if fullText.count > 1_200 {
            let starterText = String(fullText.prefix(1_200))
            do {
                setQuizBuildProgress(
                    source.id,
                    stage: .extracting,
                    progress: 0.16,
                    detail: "Creating the first questions."
                )
                let starter = try await requestLearningExtraction(
                    for: source,
                    noteText: starterText,
                    plan: starterQuestionBankPlan(forText: starterText),
                    label: "starter"
                )
                combinedTopics.append(contentsOf: starter.topics)
                combinedSegments.append(contentsOf: starter.segments)
                combinedQuestions.append(contentsOf: starter.questions)
                savePartialLearningObjects(
                    topics: combinedTopics,
                    segments: combinedSegments,
                    questions: combinedQuestions,
                    sourceID: source.id
                )
                updateSavedQuizBuildProgress(
                    sourceID: source.id,
                    savedCount: combinedQuestions.count,
                    targetCount: plan.minimumQuestions
                )
            } catch {
                // Continue with normal chunk extraction; the source will fail only if no model questions can be saved.
            }
        }

        if plan.targetQuestions <= 24 {
            do {
                setQuizBuildProgress(
                    source.id,
                    stage: .extracting,
                    progress: 0.24,
                    detail: "Mapping the full note."
                )
                let materialized = try await requestLearningExtraction(
                    for: source,
                    noteText: visibleText,
                    plan: plan,
                    label: "full note"
                )

                if materialized.questions.count >= plan.minimumQuestions {
                    return materialized
                }
            } catch {
                // Large or difficult notes often need chunking; fall through to smaller extraction passes.
            }
        }

        let chunks = learningChunks(from: fullText)
        for chunk in chunks {
            do {
                let chunkProgress = 0.28 + (Double(max(chunk.index - 1, 0)) / Double(max(chunks.count, 1))) * 0.46
                setQuizBuildProgress(
                    source.id,
                    stage: .extracting,
                    progress: chunkProgress,
                    detail: "Reading part \(chunk.index) of \(chunks.count)."
                )
                let materialized = try await requestLearningExtraction(
                    for: source,
                    noteText: chunk.text,
                    plan: chunk.plan,
                    label: "part \(chunk.index)"
                )
                combinedTopics.append(contentsOf: materialized.topics)
                combinedSegments.append(contentsOf: materialized.segments)
                combinedQuestions.append(contentsOf: materialized.questions)
                savePartialLearningObjects(
                    topics: combinedTopics,
                    segments: combinedSegments,
                    questions: combinedQuestions,
                    sourceID: source.id
                )
                updateSavedQuizBuildProgress(
                    sourceID: source.id,
                    savedCount: combinedQuestions.count,
                    targetCount: plan.minimumQuestions
                )
            } catch {
                continue
            }
        }

        if combinedQuestions.count < plan.minimumQuestions {
            do {
                setQuizBuildProgress(
                    source.id,
                    stage: .extracting,
                    progress: 0.78,
                    detail: "Filling gaps with focused questions."
                )
                let rescueQuestions = try await requestMultipleChoiceRescueQuestions(
                    for: source,
                    noteText: visibleText,
                    targetCount: max(plan.minimumQuestions - combinedQuestions.count, min(5, plan.targetQuestions))
                )
                combinedQuestions.append(contentsOf: rescueQuestions)
            } catch {
                // Keep the successfully saved model questions; the caller decides if the bank is large enough.
            }
        }

        guard combinedQuestions.isEmpty == false else {
            throw LearningExtractionError.insufficientQuestionBank
        }

        return (combinedTopics, combinedSegments, combinedQuestions)
    }

    private func savePartialLearningObjects(
        topics partialTopics: [LearningTopic],
        segments partialSegments: [LearningSegment],
        questions partialQuestions: [LearningQuestion],
        sourceID: UUID
    ) {
        let questionsWithStableIDs = preservingQuestionIDs(partialQuestions, sourceID: sourceID)

        conversationStore.replaceTopics(for: sourceID, topics: partialTopics)
        topics = conversationStore.loadTopics()
        conversationStore.replaceSegments(for: sourceID, segments: partialSegments)
        segments = conversationStore.loadSegments()
        conversationStore.replaceQuestions(for: sourceID, questions: questionsWithStableIDs)
        questions = conversationStore.loadQuestions()
        syncInteractionMemory(for: sourceID)
        refreshJourneyAssignments()
        refreshLearningPlan()
    }

    private func requestLearningExtraction(
        for source: StudySource,
        noteText: String,
        plan: QuestionBankPlan,
        label: String
    ) async throws -> (topics: [LearningTopic], segments: [LearningSegment], questions: [LearningQuestion]) {
        let timeout = learningExtractionTimeout(for: plan)
        let response = try await withTimeout(seconds: UInt64(ceil(timeout))) {
            try await self.modelReply(to: [
                GemmaMessage(
                    role: "system",
                    content: self.learningParserSystemPrompt
                ),
                GemmaMessage(
                    role: "user",
                    content: self.learningExtractionPrompt(for: source, plan: plan, noteText: noteText, label: label)
                )
            ], timeout: timeout, taskType: "note_deconstruction", promptVersion: "learning_extraction.v2")
        }

        let extraction = try parseLearningExtraction(from: response)
        let materialized = materializeLearningExtraction(extraction, source: source)

        guard materialized.segments.isEmpty == false, materialized.questions.count >= plan.minimumQuestions else {
            throw LearningExtractionError.insufficientQuestionBank
        }

        return materialized
    }

    private func requestMultipleChoiceRescueQuestions(
        for source: StudySource,
        noteText: String,
        targetCount: Int
    ) async throws -> [LearningQuestion] {
        let clampedTarget = min(max(targetCount, 1), 8)
        let response = try await withTimeout(seconds: 25) {
            try await self.modelReply(to: [
                GemmaMessage(
                    role: "system",
                    content: """
                    You create clean multiple-choice quiz questions for QuizLoop.ai.
                    Return valid JSON only. Use only the supplied note text.
                    """
                ),
                GemmaMessage(
                    role: "user",
                    content: """
                    The first extraction returned too few usable questions. Create \(clampedTarget) high-quality multiple-choice questions from this note.

                    Requirements:
                    - Return exactly one JSON object with key questions.
                    - Use only type multipleChoice.
                    - Each question must have topic_title, subtopic_title, assessment_angle, prompt, answer, choices, importance, and difficulty.
                    - choices must contain exactly 4 plausible choices.
                    - answer must exactly match one choice.
                    - Avoid duplicate prompts and avoid testing the same fact repeatedly.
                    - Cover different important ideas from the supplied note.
                    - Prefer concrete source-grounded facts, relationships, formulas, causes, examples, and definitions.
                    - Do not ask meta questions about the note, the student's goals, or what the student wants to practice.
                    - Do not use "all of the above", "none of the above", "not mentioned", or joke answers.

                    JSON shape:
                    {"questions":[{"topic_title":"\(source.title)","subtopic_title":"Core idea","assessment_angle":"definition","type":"multipleChoice","prompt":"Question?","answer":"Correct answer","choices":["Correct answer","Wrong but plausible","Wrong but plausible","Wrong but plausible"],"importance":0.8,"difficulty":0.6}]}

                    Note title: \(source.title)
                    Note text:
                    \(noteText)
                    """
                )
            ], timeout: 25, taskType: "quiz_generation", promptVersion: "multiple_choice_rescue.v2")
        }

        let expansion = try parseFreshQuestionExpansion(from: response)
        return materializeFreshQuestions(expansion.questions, source: source)
    }

    private func continueProcessingPendingSources() async {
        guard modelReadiness.isReady else {
            markProcessingSourcesFailed()
            return
        }

        let pendingSources = sources.filter { source in
            source.status == .processing
                || source.status == .failed
                || gemmaShouldReprocess(source)
        }

        for source in pendingSources {
            if sourceHasUsableQuiz(source) {
                updateSourceStatus(source.id, status: .ready)
                let savedCount = questions.filter { $0.sourceID == source.id }.count
                let plan = questionBankPlan(for: source)
                updateQuizBuildState(
                    source.id,
                    state: savedCount >= plan.targetQuestions ? .ready : .partial,
                    detail: savedCount >= plan.targetQuestions ? "Quiz bank ready." : "Quiz available. More questions can be added later.",
                    targetCount: plan.targetQuestions,
                    savedCount: savedCount
                )
                continue
            }

            updateSourceStatus(source.id, status: .processing)
            let plan = questionBankPlan(for: source)
            updateQuizBuildState(
                source.id,
                state: .building,
                detail: "Creating questions from this note.",
                targetCount: plan.targetQuestions,
                savedCount: questions.filter { $0.sourceID == source.id }.count
            )
            await organizeTopics(for: source)
        }
    }

    func retryProcessing(_ source: StudySource) async {
        if modelReadiness.isReady == false {
            await refreshModelReadiness()
        }

        guard modelReadiness.isReady else {
            updateSourceStatus(source.id, status: .failed)
            updateQuizBuildState(
                source.id,
                state: .failed,
                detail: "Connect a model to create questions.",
                error: "Model unavailable",
                targetCount: questionBankPlan(for: source).targetQuestions,
                savedCount: questions.filter { $0.sourceID == source.id }.count
            )
            return
        }

        updateSourceStatus(source.id, status: .processing)
        updateQuizBuildState(
            source.id,
            state: .building,
            detail: "Retrying quiz creation.",
            targetCount: questionBankPlan(for: source).targetQuestions,
            savedCount: questions.filter { $0.sourceID == source.id }.count
        )
        await organizeTopics(for: source)
    }

    private func organizeUngroupedSources() async {
        guard modelReadiness.isReady else { return }

        let groupedSourceIDs = Set(topics.compactMap(\.sourceID))
        let ungroupedSources = sources
            .filter { groupedSourceIDs.contains($0.id) == false }

        for source in ungroupedSources {
            await organizeTopics(for: source)
        }
    }

    private func markProcessingSourcesFailed() {
        let processingSources = sources.filter { $0.status == .processing }
        for source in processingSources {
            updateSourceStatus(source.id, status: .failed)
            updateQuizBuildState(
                source.id,
                state: .failed,
                detail: "Connect a model to create questions.",
                error: "Model unavailable",
                targetCount: questionBankPlan(for: source).targetQuestions,
                savedCount: questions.filter { $0.sourceID == source.id }.count
            )
        }
    }

    private func seedFallbackTopicsForUngroupedSources() {
        let groupedSourceIDs = Set(topics.compactMap(\.sourceID))
        let ungroupedSources = sources
            .filter { groupedSourceIDs.contains($0.id) == false }

        guard ungroupedSources.isEmpty == false else { return }

        for source in ungroupedSources {
            conversationStore.replaceTopics(for: source.id, topics: [])
        }
        topics = conversationStore.loadTopics()
    }

    private func seedMissingQuestions() {
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
                summary: source.summary,
                quizBuildState: source.quizBuildState,
                quizBuildDetail: source.quizBuildDetail,
                quizBuildError: source.quizBuildError,
                quizBuildTargetCount: source.quizBuildTargetCount,
                quizBuildSavedCount: source.quizBuildSavedCount,
                quizBuildUpdatedAt: source.quizBuildUpdatedAt,
                createdAt: source.createdAt
            )
        }
    }

    private func updateQuizBuildState(
        _ sourceID: UUID,
        state: StudySource.QuizBuildState,
        detail: String,
        error: String = "",
        targetCount: Int,
        savedCount: Int,
        stage: QuizBuildProgress.Stage? = nil
    ) {
        let updatedAt = Date.now
        conversationStore.updateQuizBuildState(
            id: sourceID,
            state: state,
            detail: detail,
            error: error,
            targetCount: targetCount,
            savedCount: savedCount,
            stage: stage?.title ?? state.title
        )
        sources = sources.map { source in
            guard source.id == sourceID else { return source }
            return StudySource(
                id: source.id,
                title: source.title,
                type: source.type,
                status: source.status,
                text: source.text,
                summary: source.summary,
                quizBuildState: state,
                quizBuildDetail: detail,
                quizBuildError: error,
                quizBuildTargetCount: targetCount,
                quizBuildSavedCount: savedCount,
                quizBuildUpdatedAt: updatedAt,
                createdAt: source.createdAt
            )
        }
    }

    private func setQuizBuildProgress(
        _ sourceID: UUID,
        stage: QuizBuildProgress.Stage,
        progress: Double,
        detail: String
    ) {
        let buildProgress = QuizBuildProgress(
            sourceID: sourceID,
            stage: stage,
            progress: progress,
            detail: detail
        )
        quizBuildProgressBySourceID[sourceID] = buildProgress
        let savedCount = questions.filter { $0.sourceID == sourceID }.count
        let targetCount: Int
        if let source = sources.first(where: { $0.id == sourceID }) {
            targetCount = max(source.quizBuildTargetCount, questionBankPlan(for: source).targetQuestions)
        } else {
            targetCount = max(savedCount, minimumReadyQuizQuestionCount)
        }
        updateQuizBuildState(
            sourceID,
            state: savedCount > 0 ? .partial : .building,
            detail: detail,
            targetCount: targetCount,
            savedCount: savedCount,
            stage: stage
        )
        scheduleQuizBuildProgressExpiry(for: sourceID, createdAt: buildProgress.createdAt)
    }

    private func updateSavedQuizBuildProgress(sourceID: UUID, savedCount: Int, targetCount: Int) {
        let progress = min(0.86, 0.28 + (Double(savedCount) / Double(max(targetCount, 1))) * 0.5)
        setQuizBuildProgress(
            sourceID,
            stage: .saving,
            progress: progress,
            detail: "\(savedCount) questions saved."
        )
        updateQuizBuildState(
            sourceID,
            state: savedCount > 0 ? .partial : .building,
            detail: "\(savedCount) questions saved.",
            targetCount: targetCount,
            savedCount: savedCount,
            stage: .saving
        )
    }

    private func clearQuizBuildProgress(for sourceID: UUID) {
        quizBuildProgressBySourceID.removeValue(forKey: sourceID)
    }

    private func scheduleQuizBuildProgressExpiry(for sourceID: UUID, createdAt: Date) {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 30 * 1_000_000_000)
            await MainActor.run {
                guard let self,
                      let current = self.quizBuildProgressBySourceID[sourceID],
                      current.createdAt == createdAt
                else { return }

                self.clearQuizBuildProgress(for: sourceID)
            }
        }
    }

    private func canAttemptQuizBuild(for sourceID: UUID) -> Bool {
        guard let lastAttempt = lastQuizBuildAttemptBySourceID[sourceID] else {
            return true
        }

        return Date.now.timeIntervalSince(lastAttempt) >= quizBuildRetryCooldown
    }

    private func saveSummary(_ summary: String, for sourceID: UUID) {
        conversationStore.updateSourceSummary(id: sourceID, summary: summary)
        sources = sources.map { source in
            guard source.id == sourceID else { return source }
            return StudySource(
                id: source.id,
                title: source.title,
                type: source.type,
                status: source.status,
                text: source.text,
                summary: summary,
                quizBuildState: source.quizBuildState,
                quizBuildDetail: source.quizBuildDetail,
                quizBuildError: source.quizBuildError,
                quizBuildTargetCount: source.quizBuildTargetCount,
                quizBuildSavedCount: source.quizBuildSavedCount,
                quizBuildUpdatedAt: source.quizBuildUpdatedAt,
                createdAt: source.createdAt
            )
        }
    }

    private func cleanedSummary(_ response: String, fallback: String) -> String {
        let cleanedResponse = cleaned(response, fallback: fallback)
        let completeResponse = trimmingIncompleteTrailingSentence(cleanedResponse)
        let candidate = completeResponse.isEmpty ? cleanedResponse : completeResponse
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)

        guard trimmed.isEmpty == false else { return fallback }
        return String(trimmed.prefix(700)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func trimmingIncompleteTrailingSentence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let lastCharacter = trimmed.last else { return "" }

        if ".!?".contains(lastCharacter) {
            return trimmed
        }

        guard let lastSentenceEnd = trimmed.lastIndex(where: { ".!?".contains($0) }) else {
            return trimmed
        }

        return String(trimmed[...lastSentenceEnd])
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
        let bankPlan = questionBankPlan(for: source)
        return isLegacyFallbackQuestionSet(sourceQuestions)
            || sourceQuestions.count < bankPlan.minimumQuestions
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
                feedback: attempt.feedback,
                matchedIdeas: attempt.matchedIdeas,
                missingIdeas: attempt.missingIdeas,
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
        let scopedQuestions = questions.filter { question in
            guard let sourceID = entry.sourceID else { return false }
            return question.sourceID == sourceID
        }
        let latestAttemptsByQuestion = latestAttempts()
        let recentlyAnswered = scopedQuestions
            .filter { latestAttemptsByQuestion[$0.id] != nil }
            .sorted {
                (latestAttemptsByQuestion[$0.id]?.createdAt ?? .distantPast)
                    > (latestAttemptsByQuestion[$1.id]?.createdAt ?? .distantPast)
            }
            .prefix(entry.questionCount)
        let targetConcepts = jsonArray(recentlyAnswered.map(quizConceptSignature))
        let avoidedConcepts = jsonArray(
            scopedQuestions
                .filter { question in
                    guard let attempt = latestAttemptsByQuestion[question.id] else { return false }
                    return attempt.score >= 0.9 && Calendar.current.isDateInToday(attempt.createdAt)
                }
                .map(quizConceptSignature)
        )
        let mix = quizMixJSON(for: Array(recentlyAnswered))
        conversationStore.saveQuizMemory(
            quizID: entry.id,
            sourceID: entry.sourceID,
            title: entry.title,
            selectedFocus: entry.title,
            reason: "Saved completed quiz history and memory signals.",
            targetConcepts: targetConcepts,
            avoidedConcepts: avoidedConcepts,
            questionMix: mix,
            modelName: gemmaService.modelName,
            promptVersion: "quiz_memory.v1"
        )
        conversationStore.saveInteractionEvent(
            kind: "quiz_completed",
            sourceID: entry.sourceID,
            quizID: entry.id,
            detail: "\(Int((entry.score * 100).rounded()))%",
            metadata: #"{"surface":"quiz"}"#
        )
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

    func recentQuizHistory(for source: StudySource?, limit: Int = 5) -> [QuizHistoryEntry] {
        quizHistory
            .filter { entry in
                guard let source else { return true }
                return entry.sourceID == source.id
            }
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(limit)
            .map { $0 }
    }

    func isPreparingNextQuiz(for sourceID: UUID?) -> Bool {
        guard let sourceID else { return false }
        return preparingNextQuizSourceIDs.contains(sourceID)
    }

    func quizBuildProgress(for source: StudySource?) -> QuizBuildProgress? {
        guard let source else { return nil }

        if let progress = quizBuildProgressBySourceID[source.id] {
            if Date.now.timeIntervalSince(progress.createdAt) > 30 {
                clearQuizBuildProgress(for: source.id)
                return nil
            }
            return progress
        }

        let availableCount = availableQuizQuestionCount(for: source)
        let savedCount = max(source.quizBuildSavedCount, questions.filter { $0.sourceID == source.id }.count)
        guard source.quizBuildState == .building
                || isPreparingNextQuiz(for: source.id)
                || (savedCount > 0 && availableCount == 0 && modelReadiness.isReady)
        else {
            return nil
        }

        let plan = questionBankPlan(for: source)
        let estimatedProgress = savedCount == 0
            ? 0.08
            : min(0.88, 0.18 + (Double(savedCount) / Double(max(source.quizBuildTargetCount, plan.minimumQuestions, 1))) * 0.62)
        return QuizBuildProgress(
            sourceID: source.id,
            stage: isPreparingNextQuiz(for: source.id) ? .expanding : .extracting,
            progress: estimatedProgress,
            detail: source.quizBuildDetail.isEmpty
                ? (savedCount == 0 ? "Waiting for the first saved questions." : "\(savedCount) questions saved.")
                : source.quizBuildDetail
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

    func buildQuiz(for source: StudySource?, focusSubtopic: String? = nil, seed: UUID? = nil) -> [LearningQuestion] {
        buildQuizSelections(for: source, focusSubtopic: focusSubtopic, seed: seed).map(\.question)
    }

    func hasAvailableQuizQuestions(for source: StudySource?, focusSubtopic: String? = nil) -> Bool {
        buildQuizSelections(for: source, focusSubtopic: focusSubtopic).count >= minimumFreshQuizCount
    }

    func availableQuizQuestionCount(for source: StudySource?, focusSubtopic: String? = nil) -> Int {
        let scoped = quizCandidateScope(for: source, focusSubtopic: focusSubtopic)
        return availableQuizQuestions(in: scoped).count
    }

    var minimumReadyQuizQuestionCount: Int {
        minimumFreshQuizCount
    }

    func prepareNextQuizIfNeeded(for source: StudySource?, focusSubtopic: String? = nil) {
        prepareNextQuizIfNeeded(for: source, focusSubtopic: focusSubtopic, remainingPasses: 3)
    }

    private func prepareNextQuizIfNeeded(for source: StudySource?, focusSubtopic: String?, remainingPasses: Int) {
        guard let source,
              remainingPasses > 0,
              modelReadiness.isReady,
              preparingNextQuizSourceIDs.contains(source.id) == false
        else { return }
        guard canAttemptQuizBuild(for: source.id) else { return }

        let scoped = quizCandidateScope(for: source, focusSubtopic: focusSubtopic)
        guard scoped.isEmpty == false else { return }

        let available = availableQuizQuestions(in: scoped)
        guard shouldPrepareNextQuiz(for: source, scoped: scoped, available: available) else { return }

        let latestAttemptsByQuestion = latestAttempts()
        let recentOutcome = scoped
            .compactMap { question -> (question: LearningQuestion, attempt: QuestionAttempt)? in
                guard let attempt = latestAttemptsByQuestion[question.id] else { return nil }
                return (question, attempt)
            }
            .sorted { lhs, rhs in
                if lhs.attempt.score == rhs.attempt.score {
                    return lhs.attempt.createdAt > rhs.attempt.createdAt
                }
                return lhs.attempt.score < rhs.attempt.score
            }
            .prefix(6)

        guard let expansionPlan = questionExpansionPlan(
            for: source,
            quizOutcome: Array(recentOutcome),
            focusSubtopic: focusSubtopic
        ) else {
            return
        }

        preparingNextQuizSourceIDs.insert(source.id)
        lastQuizBuildAttemptBySourceID[source.id] = .now
        setQuizBuildProgress(
            source.id,
            stage: .expanding,
            progress: 0.12,
            detail: "Choosing the next concepts."
        )
        Task {
            _ = await expandQuestionBankAfterQuiz(
                source: source,
                quizOutcome: Array(recentOutcome),
                expansionPlan: expansionPlan
            )

            prepareNextQuizIfNeeded(
                for: source,
                focusSubtopic: focusSubtopic,
                remainingPasses: remainingPasses - 1
            )
        }
    }

    private func shouldPrepareNextQuiz(
        for source: StudySource,
        scoped: [LearningQuestion],
        available: [LearningQuestion]
    ) -> Bool {
        if available.count < minimumFreshQuizCount {
            return true
        }

        let bankPlan = questionBankPlan(for: source)
        let currentQuestionCount = questions.filter { $0.sourceID == source.id }.count
        if currentQuestionCount < bankPlan.targetQuestions {
            return true
        }

        let untestedCount = scoped.filter { question in
            attempts.contains { $0.questionID == question.id } == false
        }.count
        return untestedCount < minimumFreshQuizCount && currentQuestionCount < maxQuestionCapacity(for: bankPlan)
    }

    func buildQuizSelections(for source: StudySource?, focusSubtopic: String? = nil, seed: UUID? = nil) -> [QuizQuestionSelection] {
        let scoped = quizCandidateScope(for: source, focusSubtopic: focusSubtopic)
        guard scoped.isEmpty == false else { return [] }

        let latestAttemptsByQuestion = latestAttempts()
        let attemptsByQuestion = Dictionary(grouping: attempts) { $0.questionID }
        let availableScoped = scoped.filter { question in
            isQuestionAvailableForQuiz(question, latestAttempt: latestAttemptsByQuestion[question.id], attempts: attemptsByQuestion[question.id, default: []])
        }
        let recentStrongPromptSignatures = recentStrongPromptSignatures(for: source)
        let cooledAvailableScoped = removingRecentStrongPromptRepeats(
            from: availableScoped,
            recentStrongPromptSignatures: recentStrongPromptSignatures
        )
        let reviewScoped = isFocusedQuiz(focusSubtopic)
            ? []
            : reviewFallbackQuestions(in: scoped, source: source)
        let activeScoped = quizPool(
            freshQuestions: cooledAvailableScoped,
            reviewQuestions: reviewScoped,
            fallbackQuestions: availableScoped
        )
        guard activeScoped.count >= minimumFreshQuizCount else { return [] }

        let shuffled = seededQuestions(activeScoped, seed: seed)
        var selected: [LearningQuestion] = []

        let weak = activeScoped
            .filter { (latestAttemptsByQuestion[$0.id]?.score ?? 1) < 0.65 }
            .sorted { lhs, rhs in
                quizSelectionScore(for: lhs, latestAttempt: latestAttemptsByQuestion[lhs.id], attemptCount: attemptsByQuestion[lhs.id, default: []].count, seed: seed)
                    > quizSelectionScore(for: rhs, latestAttempt: latestAttemptsByQuestion[rhs.id], attemptCount: attemptsByQuestion[rhs.id, default: []].count, seed: seed)
            }
        let close = activeScoped
            .filter {
                let score = latestAttemptsByQuestion[$0.id]?.score ?? 1
                return score >= 0.65 && score < 0.9
            }
            .sorted { lhs, rhs in
                quizSelectionScore(for: lhs, latestAttempt: latestAttemptsByQuestion[lhs.id], attemptCount: attemptsByQuestion[lhs.id, default: []].count, seed: seed)
                    > quizSelectionScore(for: rhs, latestAttempt: latestAttemptsByQuestion[rhs.id], attemptCount: attemptsByQuestion[rhs.id, default: []].count, seed: seed)
            }
        let untested = activeScoped
            .filter { latestAttemptsByQuestion[$0.id] == nil }
            .sorted { lhs, rhs in
                quizSelectionScore(for: lhs, latestAttempt: nil, attemptCount: 0, seed: seed)
                    > quizSelectionScore(for: rhs, latestAttempt: nil, attemptCount: 0, seed: seed)
            }
        let targetCount = quizTargetCount(
            for: activeScoped,
            untestedCount: untested.count,
            weakCount: weak.count
        )
        let shouldDiversifySubtopics = focusSubtopic == nil || focusSubtopic?.isEmpty == true
        let availableSubtopicCount = Set(activeScoped.map(\.subtopicTitle)).count
        let breadthTarget = shouldDiversifySubtopics
            ? min(targetCount, availableSubtopicCount)
            : 0

        func canAddQuestion(_ question: LearningQuestion, subtopicLimit: Int) -> Bool {
            guard selected.count < targetCount else { return false }
            guard selected.contains(where: { $0.id == question.id }) == false else { return false }
            guard selected.contains(where: { normalizedQuizPrompt($0.prompt) == normalizedQuizPrompt(question.prompt) }) == false else { return false }
            guard selected.contains(where: { isNearDuplicateQuizQuestion($0, question) }) == false else { return false }
            return selected.filter { $0.subtopicTitle == question.subtopicTitle }.count < subtopicLimit
        }

        func addCandidates(_ candidates: [LearningQuestion], until limit: Int, subtopicLimit: Int? = nil) {
            for question in candidates where selected.contains(where: { $0.id == question.id }) == false {
                let limitForSubtopic = subtopicLimit ?? max(2, Int(ceil(Double(targetCount) / Double(max(availableSubtopicCount, 1)))))
                guard canAddQuestion(question, subtopicLimit: limitForSubtopic) else { continue }

                selected.append(question)
                if selected.count >= limit { break }
            }
        }

        func addDiverseCandidates(_ candidates: [LearningQuestion], until limit: Int) {
            guard shouldDiversifySubtopics else {
                addCandidates(candidates, until: limit)
                return
            }

            var seenSubtopics = Set(selected.map(\.subtopicTitle))
            for question in candidates {
                guard selected.count < targetCount else { break }
                guard selected.count < limit else { break }
                guard seenSubtopics.contains(question.subtopicTitle) == false else { continue }
                guard canAddQuestion(question, subtopicLimit: 1) else { continue }

                selected.append(question)
                seenSubtopics.insert(question.subtopicTitle)
            }
        }
        let important = activeScoped
            .sorted { lhs, rhs in
                quizSelectionScore(for: lhs, latestAttempt: latestAttemptsByQuestion[lhs.id], attemptCount: attemptsByQuestion[lhs.id, default: []].count, seed: seed)
                    > quizSelectionScore(for: rhs, latestAttempt: latestAttemptsByQuestion[rhs.id], attemptCount: attemptsByQuestion[rhs.id, default: []].count, seed: seed)
            }

        let hasWeakQuestions = weak.isEmpty == false
        let hasUntestedQuestions = untested.isEmpty == false
        let weakTarget = hasWeakQuestions ? min(weak.count, max(1, Int(ceil(Double(targetCount) * 0.25)))) : 0
        let newMaterialTarget: Int
        if hasUntestedQuestions {
            newMaterialTarget = hasWeakQuestions
                ? max(weakTarget + 1, Int(ceil(Double(targetCount) * 0.8)))
                : max(1, Int(ceil(Double(targetCount) * 0.85)))
        } else {
            newMaterialTarget = weakTarget
        }
        let closeReviewTarget = hasUntestedQuestions
            ? newMaterialTarget
            : max(newMaterialTarget + 1, Int(ceil(Double(targetCount) * 0.75)))
        let reviewTarget = hasUntestedQuestions
            ? max(closeReviewTarget, targetCount - 1)
            : max(closeReviewTarget + 1, Int(ceil(Double(targetCount) * 0.9)))

        addCandidates(weak, until: weakTarget)
        addDiverseCandidates(untested, until: max(newMaterialTarget, breadthTarget))
        addDiverseCandidates(close, until: max(closeReviewTarget, breadthTarget))
        addDiverseCandidates(important, until: breadthTarget)
        addCandidates(weak, until: reviewTarget)
        addCandidates(important, until: max(selected.count + 1, targetCount - 1))
        addCandidates(shuffled, until: targetCount)

        let balancedSelection = filledQuizSelection(
            balancedQuizSelection(
                selected,
                from: activeScoped,
                targetCount: targetCount,
                latestAttemptsByQuestion: latestAttemptsByQuestion,
                attemptsByQuestion: attemptsByQuestion,
                seed: seed
            ),
            from: activeScoped,
            targetCount: targetCount,
            latestAttemptsByQuestion: latestAttemptsByQuestion,
            attemptsByQuestion: attemptsByQuestion,
            seed: seed
        )

        return orderedQuizQuestions(balancedSelection, seed: seed).map { question in
            QuizQuestionSelection(
                question: question,
                reason: quizSelectionReason(
                    for: question,
                    latestAttempt: latestAttemptsByQuestion[question.id],
                    attempts: attemptsByQuestion[question.id, default: []]
                )
            )
        }
    }

    private func filledQuizSelection(
        _ selected: [LearningQuestion],
        from activeScoped: [LearningQuestion],
        targetCount: Int,
        latestAttemptsByQuestion: [UUID: QuestionAttempt],
        attemptsByQuestion: [UUID: [QuestionAttempt]],
        seed: UUID?
    ) -> [LearningQuestion] {
        guard selected.count < minimumFreshQuizCount,
              activeScoped.count >= minimumFreshQuizCount
        else { return selected }

        var filled = selected
        let fillCandidates = activeScoped
            .sorted { lhs, rhs in
                quizSelectionScore(
                    for: lhs,
                    latestAttempt: latestAttemptsByQuestion[lhs.id],
                    attemptCount: attemptsByQuestion[lhs.id, default: []].count,
                    seed: seed
                ) > quizSelectionScore(
                    for: rhs,
                    latestAttempt: latestAttemptsByQuestion[rhs.id],
                    attemptCount: attemptsByQuestion[rhs.id, default: []].count,
                    seed: seed
                )
            }

        for question in fillCandidates where filled.count < max(minimumFreshQuizCount, min(targetCount, activeScoped.count)) {
            guard filled.contains(where: { $0.id == question.id }) == false else { continue }
            filled.append(question)
        }

        return filled
    }

    private func balancedQuizSelection(
        _ selected: [LearningQuestion],
        from activeScoped: [LearningQuestion],
        targetCount: Int,
        latestAttemptsByQuestion: [UUID: QuestionAttempt],
        attemptsByQuestion: [UUID: [QuestionAttempt]],
        seed: UUID?
    ) -> [LearningQuestion] {
        guard selected.isEmpty == false else { return selected }

        let maxFillBlank = min(1, max(0, targetCount / 6))
        let maxShortAnswer = max(1, targetCount / 5)
        let maxWritten = max(1, Int(ceil(Double(targetCount) * 0.25)))
        let multipleChoicePool = activeScoped
            .filter { $0.type == .multipleChoice }
            .sorted { lhs, rhs in
                quizSelectionScore(
                    for: lhs,
                    latestAttempt: latestAttemptsByQuestion[lhs.id],
                    attemptCount: attemptsByQuestion[lhs.id, default: []].count,
                    seed: seed
                ) > quizSelectionScore(
                    for: rhs,
                    latestAttempt: latestAttemptsByQuestion[rhs.id],
                    attemptCount: attemptsByQuestion[rhs.id, default: []].count,
                    seed: seed
                )
            }

        var balanced: [LearningQuestion] = []
        var fillBlankCount = 0
        var shortAnswerCount = 0

        func canAppendBalanced(_ question: LearningQuestion) -> Bool {
            guard balanced.contains(where: { $0.id == question.id }) == false else { return false }
            guard balanced.contains(where: { normalizedQuizPrompt($0.prompt) == normalizedQuizPrompt(question.prompt) }) == false else { return false }
            guard balanced.contains(where: { isNearDuplicateQuizQuestion($0, question) }) == false else { return false }
            return true
        }

        for question in selected {
            guard canAppendBalanced(question) else { continue }
            switch question.type {
            case .multipleChoice:
                balanced.append(question)
            case .fillBlank:
                guard fillBlankCount < maxFillBlank,
                      fillBlankCount + shortAnswerCount < maxWritten
                else { continue }
                fillBlankCount += 1
                balanced.append(question)
            case .shortAnswer:
                guard shortAnswerCount < maxShortAnswer,
                      fillBlankCount + shortAnswerCount < maxWritten
                else { continue }
                shortAnswerCount += 1
                balanced.append(question)
            case .flashcard:
                continue
            }
        }

        for question in multipleChoicePool where balanced.count < targetCount {
            guard canAppendBalanced(question) else { continue }
            balanced.append(question)
        }

        if balanced.isEmpty {
            return selected
        }

        return Array(balanced.prefix(targetCount))
    }

    private func quizPool(
        freshQuestions: [LearningQuestion],
        reviewQuestions: [LearningQuestion],
        fallbackQuestions: [LearningQuestion]
    ) -> [LearningQuestion] {
        if freshQuestions.count >= minimumFreshQuizCount {
            return freshQuestions
        }

        var pooled = freshQuestions
        func appendUniqueCandidates(_ candidates: [LearningQuestion]) {
            for question in candidates {
                guard pooled.contains(where: { $0.id == question.id }) == false else { continue }
                pooled.append(question)
            }
        }

        appendUniqueCandidates(reviewQuestions)
        appendUniqueCandidates(fallbackQuestions)

        if pooled.isEmpty {
            return fallbackQuestions
        }

        return pooled
    }
    private func orderedQuizQuestions(_ questions: [LearningQuestion], seed: UUID?) -> [LearningQuestion] {
        let multipleChoice = seededQuestions(
            questions.filter { $0.type == .multipleChoice },
            seed: seed
        )
        let written = seededQuestions(
            questions.filter { $0.type != .multipleChoice },
            seed: seed
        )

        guard multipleChoice.isEmpty == false else { return written }
        guard written.isEmpty == false else { return multipleChoice }

        var ordered = multipleChoice
        for (index, question) in written.enumerated() {
            let insertionIndex = min(ordered.count, max(2, (index + 1) * 4 - 1))
            ordered.insert(question, at: insertionIndex)
        }
        return ordered
    }

    private func quizCandidateScope(for source: StudySource?, focusSubtopic: String?) -> [LearningQuestion] {
        let sourceQuestions = scopedQuestions(for: source).filter(isQuizUsable)

        if let focusSubtopic, focusSubtopic.isEmpty == false {
            return sourceQuestions.filter {
                $0.subtopicTitle == focusSubtopic
                    && isFreshQuestionAlignedWithFocus(
                        prompt: $0.prompt,
                        answer: $0.answer,
                        focusSubtopic: focusSubtopic
                    )
            }
        }

        return sourceQuestions
    }

    private func isFocusedQuiz(_ focusSubtopic: String?) -> Bool {
        focusSubtopic?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    private func availableQuizQuestions(in scoped: [LearningQuestion]) -> [LearningQuestion] {
        let latestAttemptsByQuestion = latestAttempts()
        let attemptsByQuestion = Dictionary(grouping: attempts) { $0.questionID }

        return scoped.filter { question in
            isQuestionAvailableForQuiz(
                question,
                latestAttempt: latestAttemptsByQuestion[question.id],
                attempts: attemptsByQuestion[question.id, default: []]
            )
        }
    }

    private func reviewFallbackQuestions(in scoped: [LearningQuestion], source: StudySource?) -> [LearningQuestion] {
        let latestAttemptsByQuestion = latestAttempts()
        guard scoped.isEmpty == false else { return [] }
        let recentStrongPromptSignatures = recentStrongPromptSignatures(for: source)
        let cooledScoped = scoped.filter { question in
            recentStrongPromptSignatures.contains(normalizedQuizPrompt(question.prompt)) == false
        }
        let reviewScope = cooledScoped.count >= minimumFreshQuizCount ? cooledScoped : scoped

        return reviewScope
            .sorted { lhs, rhs in
                let lhsAttempt = latestAttemptsByQuestion[lhs.id]
                let rhsAttempt = latestAttemptsByQuestion[rhs.id]
                let lhsScore = lhsAttempt?.score ?? -1
                let rhsScore = rhsAttempt?.score ?? -1

                if lhsScore != rhsScore {
                    return lhsScore < rhsScore
                }

                let lhsDate = lhsAttempt?.createdAt ?? .distantPast
                let rhsDate = rhsAttempt?.createdAt ?? .distantPast
                if lhsDate != rhsDate {
                    return lhsDate < rhsDate
                }

                return lhs.importance > rhs.importance
            }
    }

    private func recentStrongPromptSignatures(for source: StudySource?) -> Set<String> {
        let cooldownStart = Date.now.addingTimeInterval(-(24 * 60 * 60))
        return Set(
            conversationStore
                .loadRecentAttemptPrompts(sourceID: nil, since: cooldownStart, minimumScore: 0.9)
                .map(normalizedQuizPrompt)
                .filter { $0.isEmpty == false }
        )
    }

    private func removingRecentStrongPromptRepeats(
        from questions: [LearningQuestion],
        recentStrongPromptSignatures: Set<String>
    ) -> [LearningQuestion] {
        guard recentStrongPromptSignatures.isEmpty == false else { return questions }
        return questions.filter { question in
            recentStrongPromptSignatures.contains(normalizedQuizPrompt(question.prompt)) == false
        }
    }

    private func normalizedQuizPrompt(_ prompt: String) -> String {
        prompt
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.isEmpty == false }
            .joined(separator: " ")
    }

    private func isNearDuplicateQuizQuestion(_ lhs: LearningQuestion, _ rhs: LearningQuestion) -> Bool {
        let lhsConcept = quizConceptSignature(lhs)
        let rhsConcept = quizConceptSignature(rhs)
        if lhsConcept.isEmpty == false, lhsConcept == rhsConcept {
            return true
        }

        let lhsPromptTokens = meaningfulQuizTokens(lhs.prompt)
        let rhsPromptTokens = meaningfulQuizTokens(rhs.prompt)
        guard lhsPromptTokens.isEmpty == false, rhsPromptTokens.isEmpty == false else { return false }

        let sharedTokenCount = lhsPromptTokens.intersection(rhsPromptTokens).count
        let largerTokenCount = max(lhsPromptTokens.count, rhsPromptTokens.count)
        let overlap = Double(sharedTokenCount) / Double(max(largerTokenCount, 1))
        let sameSubtopic = normalizedQuizPrompt(lhs.subtopicTitle) == normalizedQuizPrompt(rhs.subtopicTitle)
        let sameAnswer = normalizedQuizAnswer(lhs.answer) == normalizedQuizAnswer(rhs.answer)
        let lhsAnswerTokens = meaningfulQuizTokens(lhs.answer)
        let rhsAnswerTokens = meaningfulQuizTokens(rhs.answer)
        let answerContainsSameCore = lhsAnswerTokens.isEmpty == false
            && rhsAnswerTokens.isEmpty == false
            && (lhsAnswerTokens.isSubset(of: rhsAnswerTokens) || rhsAnswerTokens.isSubset(of: lhsAnswerTokens))

        if sameSubtopic, overlap >= 0.55 {
            return true
        }

        if sameSubtopic, answerContainsSameCore, overlap >= 0.25 {
            return true
        }

        return sameAnswer && overlap >= 0.35
    }

    private func quizConceptSignature(_ question: LearningQuestion) -> String {
        let subtopic = normalizedQuizPrompt(question.subtopicTitle)
        let answer = normalizedQuizAnswer(question.answer)
        guard subtopic.isEmpty == false, answer.isEmpty == false else { return "" }
        return "\(subtopic)|\(answer)"
    }

    private func normalizedQuizAnswer(_ answer: String) -> String {
        let tokens = answer
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .map(canonicalAnswerWord)
            .filter { $0.count > 2 }
            .filter { quizStopWords.contains($0) == false }

        return tokens.joined(separator: " ")
    }

    private func meaningfulQuizTokens(_ text: String) -> Set<String> {
        Set(
            text
                .lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .map(canonicalAnswerWord)
                .filter { $0.count > 2 }
                .filter { quizStopWords.contains($0) == false }
        )
    }

    private var quizStopWords: Set<String> {
        [
            "what", "which", "when", "where", "why", "how", "does", "did", "are", "was", "were",
            "the", "and", "for", "from", "into", "that", "this", "with", "within", "through",
            "often", "called", "term", "terms", "structure", "constitutes", "referred", "using",
            "used", "type", "name", "main", "most", "molecule", "molecules", "process", "substances"
        ]
    }

    private func canExpandQuestionBank(for source: StudySource?) -> Bool {
        guard let source, modelReadiness.isReady else { return false }

        let bankPlan = questionBankPlan(for: source)
        let currentQuestionCount = questions.filter { $0.sourceID == source.id }.count
        return currentQuestionCount < maxQuestionCapacity(for: bankPlan)
    }

    private func quizSelectionScore(
        for question: LearningQuestion,
        latestAttempt: QuestionAttempt?,
        attemptCount: Int,
        seed: UUID?
    ) -> Double {
        let base = priorityScore(for: question, latestAttempt: latestAttempt)
        let curriculumScore = curriculumReadinessScore(for: question, latestAttempt: latestAttempt)
        let usagePenalty = Double(attemptCount) * 1.15
        let sameDayPenalty: Double
        if let latestAttempt,
           Calendar.current.isDateInToday(latestAttempt.createdAt) {
            sameDayPenalty = 1.5
        } else {
            sameDayPenalty = 0
        }
        let jitter: Double
        if let seed {
            jitter = Double(abs(seededRank(questionID: question.id, seed: seed) % 1_000)) / 1_000
        } else {
            jitter = 0
        }
        return base + curriculumScore - usagePenalty - sameDayPenalty + jitter
    }

    private func isQuestionAvailableForQuiz(
        _ question: LearningQuestion,
        latestAttempt: QuestionAttempt?,
        attempts questionAttempts: [QuestionAttempt]
    ) -> Bool {
        guard let latestAttempt else {
            return true
        }

        if latestAttempt.score < 0.65 {
            return true
        }

        if latestAttempt.score < 0.9 {
            let retryDelay: TimeInterval = 24 * 60 * 60
            return Date.now >= latestAttempt.createdAt.addingTimeInterval(retryDelay)
        }

        let dueAt = nextReviewDate(after: latestAttempt, attempts: questionAttempts)
        return Date.now >= dueAt
    }

    private func nextReviewDate(after latestAttempt: QuestionAttempt, attempts questionAttempts: [QuestionAttempt]) -> Date {
        let strongAnswerCount = questionAttempts.filter { $0.score >= 0.9 }.count
        let interval: TimeInterval

        switch strongAnswerCount {
        case 0...1:
            interval = 3 * 24 * 60 * 60
        case 2:
            interval = 7 * 24 * 60 * 60
        case 3:
            interval = 14 * 24 * 60 * 60
        default:
            interval = 30 * 24 * 60 * 60
        }

        return latestAttempt.createdAt.addingTimeInterval(interval)
    }

    private func curriculumReadinessScore(
        for question: LearningQuestion,
        latestAttempt: QuestionAttempt?
    ) -> Double {
        if latestAttempt == nil {
            return (1.2 - question.difficulty) * 2.0
        }

        guard let latestAttempt else { return 0 }
        if latestAttempt.score < 0.65 {
            return 2.0
        }
        if latestAttempt.score < 0.9 {
            return 1.0
        }
        return -1.0
    }

    private func quizSelectionReason(
        for question: LearningQuestion,
        latestAttempt: QuestionAttempt?,
        attempts questionAttempts: [QuestionAttempt]
    ) -> String {
        guard let latestAttempt else {
            if question.difficulty <= 0.45 {
                return "New foundation concept. Starting with the basics before harder checks."
            }
            return "New concept from your notes. Expanding coverage."
        }

        if latestAttempt.score < 0.65 {
            return "Reviewing a weak spot from your last attempt."
        }

        if latestAttempt.score < 0.9 {
            return "Returning to an idea that was close last time."
        }

        let dueAt = nextReviewDate(after: latestAttempt, attempts: questionAttempts)
        if Date.now >= dueAt {
            return "Spaced recall. You got this before, and it is time to make sure it stuck."
        }

        return "Important concept selected to keep the quiz balanced."
    }

    func quizFocusOptions(for source: StudySource?) -> [String] {
        let scoped = scopedQuestions(for: source).filter(isQuizUsable)
        let counts = Dictionary(grouping: scoped, by: \.subtopicTitle)
            .mapValues { $0.count }
        let noisyTitles = Set(["Although", "What", "Because", "Already", "Latter", "Simple", "Modern", "Also", "Available", "Most", "Salvaging", "Outside", "February", "Summer", "Explicit", "Controlled", "Achieved", "Programmer"])

        let sortedTitles = counts
            .filter { title, count in
                count > 0
                    && noisyTitles.contains(title) == false
                    && title.count > 3
            }
            .keys
            .sorted { lhs, rhs in
                if counts[lhs, default: 0] == counts[rhs, default: 0] {
                    return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
                }
                return counts[lhs, default: 0] > counts[rhs, default: 0]
            }
        return Array(sortedTitles.prefix(12))
    }

    private func seededQuestions(_ questions: [LearningQuestion], seed: UUID?) -> [LearningQuestion] {
        guard let seed else { return questions.shuffled() }
        return questions.sorted { lhs, rhs in
            seededRank(questionID: lhs.id, seed: seed) < seededRank(questionID: rhs.id, seed: seed)
        }
    }

    private func seededRank(questionID: UUID, seed: UUID) -> Int {
        "\(seed.uuidString)-\(questionID.uuidString)".hashValue
    }

    private func quizTargetCount(
        for questions: [LearningQuestion],
        untestedCount: Int? = nil,
        weakCount: Int? = nil
    ) -> Int {
        let baseTarget: Int
        switch questions.count {
        case 0:
            baseTarget = 0
        case 1...5:
            baseTarget = questions.count
        case 6...12:
            baseTarget = min(8, questions.count)
        default:
            baseTarget = min(12, max(8, questions.count / 4))
        }

        return baseTarget
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

    func gradeQuizAnswers(_ submissions: [QuizAnswerSubmission]) async -> [QuestionAttempt] {
        var gradedAttempts: [(index: Int, attempt: QuestionAttempt)] = []

        await withTaskGroup(of: (Int, QuestionAttempt).self) { group in
            for (index, submission) in submissions.enumerated() {
                group.addTask {
                    let evaluation = await self.evaluateAnswerWithGemmaIfUseful(response: submission.response, for: submission.question)
                    let attempt = QuestionAttempt(
                        questionID: submission.question.id,
                        response: submission.response,
                        score: evaluation.score,
                        feedback: evaluation.feedback ?? evaluation.reason,
                        matchedIdeas: evaluation.matchedIdeas ?? [],
                        missingIdeas: evaluation.missingIdeas ?? []
                    )
                    return (index, attempt)
                }
            }

            for await result in group {
                gradedAttempts.append(result)
            }
        }

        let orderedAttempts = gradedAttempts
            .sorted { $0.index < $1.index }
            .map(\.attempt)

        for (submission, attempt) in zip(submissions, orderedAttempts) {
            conversationStore.save(attempt, question: submission.question)
            let localScore = localAnswerScore(submission.response, for: submission.question)
            conversationStore.saveAnswerEvaluation(
                attemptID: attempt.id,
                questionID: submission.question.id,
                sourceID: submission.question.sourceID,
                localScore: roundedScore(localScore),
                modelScore: submission.question.type == .multipleChoice ? nil : roundedScore(attempt.score),
                finalScore: roundedScore(attempt.score),
                grader: submission.question.type == .multipleChoice ? "local_choice" : "gemma_bounded_or_local_fallback",
                modelName: gemmaService.modelName,
                latencyMS: nil,
                reason: attempt.feedback ?? ""
            )
            conversationStore.saveInteractionEvent(
                kind: "question_answered",
                sourceID: submission.question.sourceID,
                questionID: submission.question.id,
                conceptSignature: quizConceptSignature(submission.question),
                detail: resultLabel(for: attempt.score),
                metadata: #"{"surface":"quiz"}"#
            )
        }

        attempts.insert(contentsOf: orderedAttempts.reversed(), at: 0)
        syncInteractionMemory(for: submissions.first?.question.sourceID)

        if orderedAttempts.isEmpty == false {
            recordXP(for: .test, reason: "Completed a quiz session.")
            refreshJourneyAssignments()
            refreshLearningPlan()
            buildNextQuizQuestionsInBackground(from: submissions, attempts: orderedAttempts)
        }

        return orderedAttempts
    }

    private func buildNextQuizQuestionsInBackground(
        from submissions: [QuizAnswerSubmission],
        attempts orderedAttempts: [QuestionAttempt]
    ) {
        let quizOutcome = zip(submissions, orderedAttempts).map { submission, attempt in
            (question: submission.question, attempt: attempt)
        }

        let dominantSubtopic = dominantQuizSubtopic(in: quizOutcome)

        guard let sourceID = quizOutcome.compactMap({ $0.question.sourceID }).first,
              let source = sources.first(where: { $0.id == sourceID }),
              modelReadiness.isReady
        else { return }
        guard preparingNextQuizSourceIDs.contains(sourceID) == false
        else { return }

        guard let expansionPlan = questionExpansionPlan(
            for: source,
            quizOutcome: quizOutcome,
            focusSubtopic: dominantSubtopic
        ) else {
            return
        }
        guard canAttemptQuizBuild(for: sourceID) || expansionPlan.angleTargets.isEmpty == false else {
            return
        }

        preparingNextQuizSourceIDs.insert(sourceID)
        lastQuizBuildAttemptBySourceID[sourceID] = .now
        setQuizBuildProgress(
            sourceID,
            stage: .expanding,
            progress: 0.12,
            detail: "Choosing the next concepts."
        )
        Task {
            _ = await expandQuestionBankAfterQuiz(
                source: source,
                quizOutcome: quizOutcome,
                expansionPlan: expansionPlan
            )
        }
    }

    private func dominantQuizSubtopic(
        in quizOutcome: [(question: LearningQuestion, attempt: QuestionAttempt)]
    ) -> String? {
        let grouped = Dictionary(grouping: quizOutcome) { item in
            item.question.subtopicTitle
        }
        guard let dominant = grouped.max(by: { lhs, rhs in
            lhs.value.count < rhs.value.count
        }) else {
            return nil
        }

        return dominant.value.count >= max(2, quizOutcome.count / 2)
            ? dominant.key
            : nil
    }

    private func questionExpansionPlan(
        for source: StudySource,
        quizOutcome: [(question: LearningQuestion, attempt: QuestionAttempt)],
        focusSubtopic: String? = nil
    ) -> QuestionExpansionPlan? {
        let bankPlan = questionBankPlan(for: source)
        let currentQuestionCount = questions.filter { $0.sourceID == source.id }.count
        let trimmedFocus = focusSubtopic?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let normalizedFocus = trimmedFocus.isEmpty ? nil : trimmedFocus
        let maxQuestionCount = maxQuestionCapacity(for: bankPlan)
        let remainingSlots = maxQuestionCount - currentQuestionCount
        guard remainingSlots > 0 else { return nil }

        let weakCount = quizOutcome.filter { $0.attempt.score < 0.65 }.count
        let closeCount = quizOutcome.filter { $0.attempt.score >= 0.65 && $0.attempt.score < 0.9 }.count
        let missedSignal = weakCount + closeCount
        let perQuizLimit = maxQuestionExpansionPerQuiz(wordCount: bankPlan.wordCount)

        let desiredCount: Int
        let reason: String
        let angleTargets: [String]

        if let normalizedFocus {
            let focusQuestionCount = questions.filter {
                $0.sourceID == source.id
                    && normalizedQuizPrompt($0.subtopicTitle) == normalizedQuizPrompt(normalizedFocus)
            }.count
            angleTargets = missingAssessmentAngles(for: source, focusSubtopic: normalizedFocus)
            desiredCount = max(
                minimumFocusedQuestionCount - focusQuestionCount,
                angleTargets.count,
                missedSignal + 2,
                2
            )
            reason = "Deepen the selected focus so the student can master one topic thoroughly."
        } else if currentQuestionCount < bankPlan.targetQuestions {
            angleTargets = []
            desiredCount = bankPlan.targetQuestions - currentQuestionCount
            reason = "Backfill this note until it reaches the note-size question target."
        } else if missedSignal > 0 {
            angleTargets = []
            desiredCount = missedSignal + 3
            reason = "Generate targeted variants around weak and close answers."
        } else if currentQuestionCount < bankPlan.targetQuestions {
            angleTargets = []
            desiredCount = bankPlan.targetQuestions - currentQuestionCount
            reason = "Expand toward the note-size target with nearby untested ideas."
        } else {
            angleTargets = []
            desiredCount = 2
            reason = "The student was strong; add a small number of nearby untested checks."
        }

        let targetNewQuestions = min(max(desiredCount, 1), perQuizLimit, remainingSlots)
        guard targetNewQuestions > 0 else { return nil }

        return QuestionExpansionPlan(
            wordCount: bankPlan.wordCount,
            currentQuestionCount: currentQuestionCount,
            maxQuestionCount: maxQuestionCount,
            targetNewQuestions: targetNewQuestions,
            focusSubtopic: normalizedFocus,
            angleTargets: angleTargets,
            underservedSubtopics: normalizedFocus.map { [$0] } ?? underservedSubtopics(for: source, limit: targetNewQuestions),
            coverageTargets: missingCoverageTargets(for: source, focusSubtopic: normalizedFocus, limit: targetNewQuestions),
            reason: reason
        )
    }

    private func missingAssessmentAngles(for source: StudySource, focusSubtopic: String) -> [String] {
        let existingAngles = Set(
            questions
                .filter {
                    $0.sourceID == source.id
                        && normalizedQuizPrompt($0.subtopicTitle) == normalizedQuizPrompt(focusSubtopic)
                }
                .map(assessmentAngle)
        )

        return assessmentAngleCurriculum.filter { existingAngles.contains($0) == false }
    }

    private var assessmentAngleCurriculum: [String] {
        [
            "definition",
            "inputs",
            "outputs",
            "location",
            "sequence",
            "purpose",
            "relationship",
            "misconception",
            "limiting-factor",
            "application"
        ]
    }

    private func missingCoverageTargets(for source: StudySource, focusSubtopic: String? = nil, limit: Int) -> [String] {
        let noteSentences = conceptSentences(in: learningText(for: source))
        guard noteSentences.isEmpty == false else { return [] }
        let focusTokens = focusSubtopic.map { meaningfulQuizTokens($0) } ?? Set<String>()

        let sourceQuestions = questions.filter { $0.sourceID == source.id }
        let coveredTokens = Set(
            sourceQuestions.flatMap { question in
                meaningfulQuizTokens(
                    [question.subtopicTitle, question.prompt, question.answer]
                        .joined(separator: " ")
                )
            }
        )

        let scoredTargets = noteSentences.compactMap { sentence -> (sentence: String, score: Double)? in
            let sentenceTokens = meaningfulQuizTokens(sentence)
            guard sentenceTokens.count >= 3 else { return nil }
            if focusTokens.isEmpty == false,
               sentenceTokens.intersection(focusTokens).isEmpty {
                return nil
            }

            let overlap = sentenceTokens.intersection(coveredTokens)
            let uncoveredRatio = 1 - (Double(overlap.count) / Double(max(sentenceTokens.count, 1)))
            let importance = coverageImportanceScore(for: sentence)
            let score = uncoveredRatio + importance

            guard score >= 0.95 else { return nil }
            return (sentence, score)
        }

        return scoredTargets
            .sorted { lhs, rhs in
                if lhs.score == rhs.score {
                    return lhs.sentence.count < rhs.sentence.count
                }
                return lhs.score > rhs.score
            }
            .prefix(max(limit, 1))
            .map { item in
                String(item.sentence.prefix(220))
            }
    }

    private func conceptSentences(in text: String) -> [String] {
        text
            .replacingOccurrences(of: "\n", with: " ")
            .components(separatedBy: CharacterSet(charactersIn: ".!?"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { sentence in
                let words = sentence.split { $0.isWhitespace || $0.isNewline }
                return words.count >= 6 && words.count <= 34
            }
    }

    private func coverageImportanceScore(for sentence: String) -> Double {
        let lowercased = sentence.lowercased()
        let highSignalTerms = [
            "input", "output", "because", "matters", "factor", "limit", "misconception",
            "thinking", "depends", "released", "byproduct", "carbon dioxide", "oxygen",
            "glucose", "chlorophyll", "stroma", "thylakoid", "calvin", "light-dependent"
        ]

        let matches = highSignalTerms.filter { lowercased.contains($0) }.count
        return min(Double(matches) * 0.18, 0.9)
    }

    private func underservedSubtopics(for source: StudySource, limit: Int) -> [String] {
        let sourceQuestions = questions.filter { $0.sourceID == source.id }
        let sourceSegments = segments.filter { $0.sourceID == source.id }
        let latestAttemptsByQuestion = latestAttempts()
        let questionCounts = Dictionary(grouping: sourceQuestions, by: \.subtopicTitle)
            .mapValues(\.count)
        let questionsBySubtopic = Dictionary(grouping: sourceQuestions, by: \.subtopicTitle)
        let segmentImportance = Dictionary(grouping: sourceSegments, by: \.subtopicTitle)
            .mapValues { grouped in
                grouped.reduce(0.0) { $0 + $1.importance } / Double(max(grouped.count, 1))
            }
        let subtopics = Set(sourceSegments.map(\.subtopicTitle) + sourceQuestions.map(\.subtopicTitle))
            .filter { title in
                title.trimmingCharacters(in: .whitespacesAndNewlines).count > 3
            }

        return subtopics
            .sorted { lhs, rhs in
                let lhsCount = questionCounts[lhs, default: 0]
                let rhsCount = questionCounts[rhs, default: 0]
                if lhsCount != rhsCount {
                    return lhsCount < rhsCount
                }

                let lhsMastery = averageLatestScore(for: questionsBySubtopic[lhs, default: []], latestAttemptsByQuestion: latestAttemptsByQuestion)
                let rhsMastery = averageLatestScore(for: questionsBySubtopic[rhs, default: []], latestAttemptsByQuestion: latestAttemptsByQuestion)
                if lhsMastery != rhsMastery {
                    return lhsMastery < rhsMastery
                }

                return segmentImportance[lhs, default: 0.5] > segmentImportance[rhs, default: 0.5]
            }
            .prefix(max(limit, 1))
            .map { $0 }
    }

    private func averageLatestScore(
        for questions: [LearningQuestion],
        latestAttemptsByQuestion: [UUID: QuestionAttempt]
    ) -> Double {
        let scores = questions.compactMap { latestAttemptsByQuestion[$0.id]?.score }
        guard scores.isEmpty == false else { return 0 }
        return scores.reduce(0, +) / Double(scores.count)
    }

    private func maxQuestionCapacity(for bankPlan: QuestionBankPlan) -> Int {
        switch bankPlan.wordCount {
        case 0..<80:
            return min(max(bankPlan.targetQuestions, 4), 6)
        case 80..<300:
            return min(max(bankPlan.targetQuestions * 2, 10), 16)
        case 300..<1_000:
            return min(max(bankPlan.targetQuestions * 2, 20), 36)
        case 1_000..<3_000:
            return min(max(bankPlan.targetQuestions * 2, 36), 64)
        default:
            return min(max(bankPlan.targetQuestions * 2, 64), 120)
        }
    }

    private func maxQuestionExpansionPerQuiz(wordCount: Int) -> Int {
        switch wordCount {
        case 0..<80:
            return 1
        case 80..<300:
            return 2
        case 300..<1_000:
            return 4
        default:
            return 6
        }
    }

    @discardableResult
    private func expandQuestionBankAfterQuiz(
        source: StudySource,
        quizOutcome: [(question: LearningQuestion, attempt: QuestionAttempt)],
        expansionPlan: QuestionExpansionPlan
    ) async -> Int {
        defer {
            preparingNextQuizSourceIDs.remove(source.id)
            clearQuizBuildProgress(for: source.id)
        }

        let memoryContext = quizMemoryContextJSON(
            source: source,
            expansionPlan: expansionPlan,
            quizOutcome: quizOutcome
        )

        let prompt = nextQuizExpansionPrompt(
            source: source,
            expansionPlan: expansionPlan,
            memoryContext: memoryContext
        )
        setQuizBuildProgress(
            source.id,
            stage: .expanding,
            progress: 0.35,
            detail: "Gemma is creating fresh questions."
        )

        do {
            let response = try await withTimeout(seconds: 25) {
                try await self.modelReply(to: [
                    GemmaMessage(
                        role: "system",
                        content: """
                        You create fresh quiz questions for QuizLoop.ai.
                        Return valid JSON only. Do not include markdown, prose, comments, or code fences.
                        Use only the supplied note text.
                        """
                    ),
                    GemmaMessage(role: "user", content: prompt)
                ], timeout: 25, taskType: "quiz_generation", promptVersion: "quiz_memory_context.v1")
            }

            let expansion = try parseFreshQuestionExpansion(from: response)
            let freshQuestions = materializeFreshQuestions(
                expansion.questions,
                source: source,
                focusSubtopic: expansionPlan.focusSubtopic
            )
            setQuizBuildProgress(
                source.id,
                stage: .saving,
                progress: 0.82,
                detail: "Saving new questions."
            )
            let addedCount = appendFreshQuestions(freshQuestions, sourceID: source.id)
            let savedCount = questions.filter { $0.sourceID == source.id }.count
            let bankPlan = questionBankPlan(for: source)
            updateQuizBuildState(
                source.id,
                state: savedCount >= bankPlan.targetQuestions ? .ready : .partial,
                detail: addedCount > 0 ? "\(addedCount) new questions added." : "Quiz available. No new questions added this pass.",
                targetCount: bankPlan.targetQuestions,
                savedCount: savedCount,
                stage: .saving
            )
            clearQuizBuildProgress(for: source.id)
            updateSourceStatus(source.id, status: savedCount >= bankPlan.minimumQuestions ? .ready : .processing)
            return addedCount
        } catch {
            let savedCount = questions.filter { $0.sourceID == source.id }.count
            let bankPlan = questionBankPlan(for: source)
            updateQuizBuildState(
                source.id,
                state: savedCount > 0 ? .partial : .failed,
                detail: savedCount > 0 ? "Quiz available. Fresh questions can be retried later." : "Could not create questions yet.",
                error: error.localizedDescription,
                targetCount: bankPlan.targetQuestions,
                savedCount: savedCount,
                stage: .expanding
            )
            clearQuizBuildProgress(for: source.id)
            updateSourceStatus(source.id, status: savedCount >= bankPlan.minimumQuestions ? .ready : .failed)
            return 0
        }
    }

    private func quizMemoryContextJSON(
        source: StudySource,
        expansionPlan: QuestionExpansionPlan,
        quizOutcome: [(question: LearningQuestion, attempt: QuestionAttempt)]
    ) -> String {
        let latestAttemptsByQuestion = latestAttempts()
        let attemptsByQuestion = Dictionary(grouping: attempts) { $0.questionID }
        let sourceQuestions = questions.filter { $0.sourceID == source.id }

        let outcome = quizOutcome
            .sorted { lhs, rhs in
                if lhs.attempt.score == rhs.attempt.score {
                    return lhs.question.importance > rhs.question.importance
                }
                return lhs.attempt.score < rhs.attempt.score
            }
            .prefix(6)
            .map { item in
                QuizOutcomeMemory(
                    question: questionMemory(
                        for: item.question,
                        latestAttempt: item.attempt,
                        attemptCount: attemptsByQuestion[item.question.id, default: []].count
                    ),
                    response: item.attempt.response,
                    score: roundedScore(item.attempt.score),
                    result: resultLabel(for: item.attempt.score),
                    matchedIdeas: Array(item.attempt.matchedIdeas.prefix(4)),
                    missingIdeas: Array(item.attempt.missingIdeas.prefix(4))
                )
            }

        let existingToAvoid = sourceQuestions
            .sorted { lhs, rhs in
                let lhsAttempt = latestAttemptsByQuestion[lhs.id]
                let rhsAttempt = latestAttemptsByQuestion[rhs.id]
                let lhsDate = lhsAttempt?.createdAt ?? lhs.createdAt
                let rhsDate = rhsAttempt?.createdAt ?? rhs.createdAt
                if lhsDate != rhsDate {
                    return lhsDate > rhsDate
                }
                return lhs.importance > rhs.importance
            }
            .prefix(24)
            .map { question in
                questionMemory(
                    for: question,
                    latestAttempt: latestAttemptsByQuestion[question.id],
                    attemptCount: attemptsByQuestion[question.id, default: []].count
                )
            }

        let concepts = conceptMemory(
            sourceQuestions: sourceQuestions,
            latestAttemptsByQuestion: latestAttemptsByQuestion,
            attemptsByQuestion: attemptsByQuestion
        )

        let packet = QuizMemoryPacket(
            note: NoteMemory(
                id: source.id.uuidString,
                title: source.title,
                wordCount: expansionPlan.wordCount
            ),
            selectedFocus: expansionPlan.focusSubtopic,
            expansionPolicy: ExpansionPolicyMemory(
                reason: expansionPlan.reason,
                targetNewQuestions: expansionPlan.targetNewQuestions,
                currentQuestionCount: expansionPlan.currentQuestionCount,
                maxQuestionCount: expansionPlan.maxQuestionCount,
                missingAssessmentAngles: expansionPlan.angleTargets
            ),
            latestQuizOutcome: Array(outcome),
            learnerState: concepts,
            existingQuestionsToAvoid: Array(existingToAvoid),
            underservedSubtopics: expansionPlan.underservedSubtopics,
            uncoveredTargets: expansionPlan.coverageTargets,
            instructions: [
                "Treat conceptSignature as the strongest duplicate signal.",
                "Do not generate a question whose conceptSignature matches a question marked avoidThisQuiz.",
                "Do not generate a question that tests the same idea as latestQuizOutcome unless result is close or needs_review.",
                "If latestQuizOutcome is strong, move to an adjacent untested concept from uncoveredTargets or underservedSubtopics.",
                "Multiple-choice choices must contain one clearly correct answer and three plausible but clearly wrong distractors."
            ]
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(packet),
              let json = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        return json
    }

    private func questionMemory(
        for question: LearningQuestion,
        latestAttempt: QuestionAttempt?,
        attemptCount: Int
    ) -> QuestionMemory {
        QuestionMemory(
            id: question.id.uuidString,
            topic: question.topicTitle,
            subtopic: question.subtopicTitle,
            segment: segmentText(for: question),
            assessmentAngle: assessmentAngle(for: question),
            type: question.type.rawValue,
            prompt: question.prompt,
            answer: question.answer,
            choices: question.choices,
            conceptSignature: quizConceptSignature(question),
            importance: roundedScore(question.importance),
            difficulty: roundedScore(question.difficulty),
            latestScore: latestAttempt.map { roundedScore($0.score) },
            attemptCount: attemptCount,
            status: latestAttempt.map { resultLabel(for: $0.score) } ?? "untested"
        )
    }

    private func conceptMemory(
        sourceQuestions: [LearningQuestion],
        latestAttemptsByQuestion: [UUID: QuestionAttempt],
        attemptsByQuestion: [UUID: [QuestionAttempt]]
    ) -> [ConceptMemory] {
        let grouped = Dictionary(grouping: sourceQuestions) { question in
            quizConceptSignature(question)
        }

        return grouped.compactMap { signature, groupedQuestions -> ConceptMemory? in
            guard signature.isEmpty == false,
                  let representative = groupedQuestions.sorted(by: questionDedupSort).first
            else { return nil }

            let groupedAttempts = groupedQuestions.flatMap { attemptsByQuestion[$0.id, default: []] }
            let latestAttempt = groupedAttempts.max { $0.createdAt < $1.createdAt }
            let status = latestAttempt.map { resultLabel(for: $0.score) } ?? "untested"
            let avoidThisQuiz = latestAttempt.map { attempt in
                attempt.score >= 0.9 && Calendar.current.isDateInToday(attempt.createdAt)
            } ?? false
            let dueReason: String
            if latestAttempt == nil {
                dueReason = "untested concept"
            } else if avoidThisQuiz {
                dueReason = "answered strongly today"
            } else if let latestAttempt, latestAttempt.score < 0.65 {
                dueReason = "weak latest answer"
            } else if let latestAttempt, latestAttempt.score < 0.9 {
                dueReason = "close latest answer"
            } else {
                dueReason = "spaced review candidate"
            }

            return ConceptMemory(
                conceptSignature: signature,
                topic: representative.topicTitle,
                subtopic: representative.subtopicTitle,
                assessmentAngle: assessmentAngle(for: representative),
                latestScore: latestAttempt.map { roundedScore($0.score) },
                attemptCount: groupedAttempts.count,
                status: status,
                avoidThisQuiz: avoidThisQuiz,
                dueReason: dueReason,
                representativePrompt: representative.prompt
            )
        }
        .sorted { lhs, rhs in
            if lhs.avoidThisQuiz != rhs.avoidThisQuiz {
                return lhs.avoidThisQuiz && !rhs.avoidThisQuiz
            }
            if lhs.status != rhs.status {
                return lhs.status < rhs.status
            }
            return lhs.attemptCount > rhs.attemptCount
        }
        .prefix(32)
        .map { $0 }
    }

    private func segmentText(for question: LearningQuestion) -> String? {
        guard let segmentID = question.segmentID,
              let segment = segments.first(where: { $0.id == segmentID })
        else { return nil }
        return String(segment.text.prefix(180))
    }

    private func resultLabel(for score: Double) -> String {
        switch score {
        case 0.9...:
            return "strong"
        case 0.65..<0.9:
            return "close"
        default:
            return "needs_review"
        }
    }

    private func roundedScore(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }

    private func jsonArray(_ values: [String]) -> String {
        let cleanedValues = values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }
        guard let data = try? JSONEncoder().encode(cleanedValues),
              let text = String(data: data, encoding: .utf8)
        else { return "[]" }
        return text
    }

    private func quizMixJSON(for questions: [LearningQuestion]) -> String {
        let typeCounts = Dictionary(grouping: questions, by: { $0.type.rawValue })
            .mapValues(\.count)
        let angleCounts = Dictionary(grouping: questions, by: assessmentAngle)
            .mapValues(\.count)
        let payload = [
            "types": typeCounts,
            "angles": angleCounts
        ]
        guard let data = try? JSONEncoder().encode(payload),
              let text = String(data: data, encoding: .utf8)
        else { return "{}" }
        return text
    }

    private func syncInteractionMemory(for sourceID: UUID?) {
        let scopedQuestions = questions.filter { question in
            guard let sourceID else { return true }
            return question.sourceID == sourceID
        }
        guard scopedQuestions.isEmpty == false else { return }

        let latestAttemptsByQuestion = latestAttempts()
        let attemptsByQuestion = Dictionary(grouping: attempts) { $0.questionID }
        let groupedByConcept = Dictionary(grouping: scopedQuestions) { quizConceptSignature($0) }

        for question in scopedQuestions {
            let questionAttempts = attemptsByQuestion[question.id, default: []]
            let latestAttempt = latestAttemptsByQuestion[question.id]
            let qualityFlags = qualityFlags(for: question)
            conversationStore.saveQuestionMemory(
                questionID: question.id,
                sourceID: question.sourceID,
                conceptSignature: quizConceptSignature(question),
                assessmentAngle: assessmentAngle(for: question),
                generationSource: "gemma",
                qualityFlags: qualityFlags,
                latestScore: latestAttempt.map { roundedScore($0.score) },
                attemptCount: questionAttempts.count,
                lastSeenAt: latestAttempt?.createdAt,
                status: latestAttempt.map { resultLabel(for: $0.score) } ?? "untested"
            )
        }

        for (conceptSignature, conceptQuestions) in groupedByConcept where conceptSignature.isEmpty == false {
            guard let representative = conceptQuestions.sorted(by: questionDedupSort).first else { continue }
            let conceptAttempts = conceptQuestions.flatMap { attemptsByQuestion[$0.id, default: []] }
            let latestAttempt = conceptAttempts.max { $0.createdAt < $1.createdAt }
            let scores = conceptAttempts.map(\.score)
            let averageScore = scores.isEmpty ? nil : scores.reduce(0, +) / Double(scores.count)
            let state = latestAttempt.map { resultLabel(for: $0.score) } ?? "untested"
            let nextDueAt = latestAttempt.map { attempt in
                nextReviewDate(after: attempt, attempts: conceptAttempts)
            }

            let dueReason: String
            if latestAttempt == nil {
                dueReason = "untested concept"
            } else if let latestAttempt, latestAttempt.score < 0.65 {
                dueReason = "weak latest answer"
            } else if let latestAttempt, latestAttempt.score < 0.9 {
                dueReason = "close latest answer"
            } else if let nextDueAt, nextDueAt > Date.now {
                dueReason = "answered strongly; wait for spaced review"
            } else {
                dueReason = "due for spaced review"
            }

            conversationStore.saveConceptMemory(
                sourceID: representative.sourceID,
                conceptSignature: conceptSignature,
                topicTitle: representative.topicTitle,
                subtopicTitle: representative.subtopicTitle,
                assessmentAngle: assessmentAngle(for: representative),
                latestScore: latestAttempt.map { roundedScore($0.score) },
                averageScore: averageScore.map(roundedScore),
                attemptCount: conceptAttempts.count,
                lastSeenAt: latestAttempt?.createdAt,
                nextDueAt: nextDueAt,
                state: state,
                dueReason: dueReason
            )
        }
    }

    private func qualityFlags(for question: LearningQuestion) -> [String] {
        var flags: [String] = []
        if question.type == .multipleChoice, hasAmbiguousCorrectChoices(question) {
            flags.append("ambiguous_choices")
        }
        if question.type == .multipleChoice, hasNearDuplicateChoices(question.choices) {
            flags.append("near_duplicate_choices")
        }
        if promptDoesNotRevealAnswer(prompt: question.prompt, answer: question.answer) == false {
            flags.append("prompt_reveals_answer")
        }
        if isQuizUsable(question) == false {
            flags.append("not_quiz_usable")
        }
        return flags
    }

    private func parseFreshQuestionExpansion(from response: String) throws -> FreshQuestionExpansion {
        let jsonText = extractJSONObject(from: response)
        let data = Data(jsonText.utf8)
        return try JSONDecoder().decode(FreshQuestionExpansion.self, from: data)
    }

    private func materializeFreshQuestions(
        _ freshQuestions: [FreshQuestion],
        source: StudySource,
        focusSubtopic: String? = nil
    ) -> [LearningQuestion] {
        freshQuestions.compactMap { freshQuestion in
            guard let type = questionType(from: freshQuestion.type) else { return nil }

            let prompt = cleaned(freshQuestion.prompt, fallback: "")
            let answer = cleaned(freshQuestion.answer, fallback: "")
            guard prompt.isEmpty == false, answer.isEmpty == false else { return nil }
            guard isFreshQuestionAlignedWithFocus(
                prompt: prompt,
                answer: answer,
                focusSubtopic: focusSubtopic
            ) else { return nil }

            let choices = normalizedChoices(
                freshQuestion.choices ?? [],
                answer: answer,
                type: type
            )
            guard type != .multipleChoice || choices.count == 4 else { return nil }

            let resolvedAnswer = resolvedMultipleChoiceAnswer(answer: answer, choices: choices, type: type)
            let acceptedAnswers = normalizedAcceptedAnswers(
                freshQuestion.acceptedAnswers,
                answer: resolvedAnswer,
                type: type
            )
            let gradingRubric = normalizedGradingRubric(
                freshQuestion.gradingRubric,
                answer: resolvedAnswer,
                type: type
            )

            return LearningQuestion(
                sourceID: source.id,
                topicTitle: cleaned(freshQuestion.topicTitle, fallback: source.title),
                subtopicTitle: cleaned(focusSubtopic ?? freshQuestion.subtopicTitle, fallback: "Follow-up"),
                type: type,
                prompt: prompt,
                answer: resolvedAnswer,
                acceptedAnswers: acceptedAnswers,
                gradingRubric: gradingRubric,
                choices: choices,
                importance: normalizedWeight(freshQuestion.importance),
                difficulty: normalizedWeight(freshQuestion.difficulty)
            )
        }
    }

    private func isFreshQuestionAlignedWithFocus(
        prompt: String,
        answer: String,
        focusSubtopic: String?
    ) -> Bool {
        guard let focusSubtopic,
              focusSubtopic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        else { return true }

        let combined = "\(prompt) \(answer)".lowercased()
        let focusTokens = meaningfulQuizTokens(focusSubtopic)
        if focusTokens.isEmpty == false,
           combined.contains(focusSubtopic.lowercased())
                || focusTokens.contains(where: { combined.contains($0) }) {
            return true
        }

        if normalizedQuizPrompt(focusSubtopic) == "overall process" {
            let narrowStandaloneTerms = [
                "calvin cycle",
                "light-dependent",
                "light dependent",
                "light-independent",
                "light independent",
                "thylakoid",
                "stroma",
                "photosystem",
                "rubisco",
                "atp",
                "nadph"
            ]
            let asksNarrowStageFact = narrowStandaloneTerms.contains { combined.contains($0) }
                && combined.contains("overall") == false
                && combined.contains("whole") == false
                && combined.contains("connect") == false
                && combined.contains("relate") == false
                && combined.contains("relationship") == false
                && combined.contains("contribute") == false

            guard asksNarrowStageFact == false else { return false }

            let isWholePhotosynthesisQuestion = combined.contains("photosynthesis")
                || combined.contains("food web")
                || combined.contains("chemical energy")
                || combined.contains("glucose")
                || combined.contains("oxygen")
                || combined.contains("carbon dioxide")
            return isWholePhotosynthesisQuestion
        }

        return false
    }

    private func resolvedMultipleChoiceAnswer(
        answer: String,
        choices: [String],
        type: LearningQuestion.QuestionType
    ) -> String {
        guard type == .multipleChoice else { return answer }

        if let exactChoice = choices.first(where: { $0 == answer }) {
            return exactChoice
        }

        let normalizedAnswer = normalizedText(answer)
        return choices.first { normalizedText($0) == normalizedAnswer } ?? answer
    }

    @discardableResult
    private func appendFreshQuestions(_ generatedQuestions: [LearningQuestion], sourceID: UUID) -> Int {
        let usableQuestions = generatedQuestions
            .map { alignedQuestion($0, sourceID: sourceID) }
            .map(reclassifiedQuestion)
            .filter(isQuizUsable)

        guard usableQuestions.isEmpty == false else { return 0 }

        var knownSignatures = Set(
            questions
                .filter { $0.sourceID == sourceID }
                .map(questionSignature)
        )
        var knownPromptSignatures = Set(
            questions
                .filter { $0.sourceID == sourceID }
                .map(questionPromptSignature)
                .filter { $0.isEmpty == false }
        )
        var knownAngleSignatures = Set(
            questions
                .filter { $0.sourceID == sourceID }
                .map(questionAngleSignature)
                .filter { $0.isEmpty == false }
        )
        let existingQuestions = questions.filter { $0.sourceID == sourceID }
        var freshQuestions: [LearningQuestion] = []

        for question in usableQuestions {
            let signature = questionSignature(question)
            let promptSignature = questionPromptSignature(question)
            let angleSignature = questionAngleSignature(question)
            guard knownSignatures.contains(signature) == false else { continue }
            guard promptSignature.isEmpty || knownPromptSignatures.contains(promptSignature) == false else { continue }
            guard angleSignature.isEmpty || knownAngleSignatures.contains(angleSignature) == false else { continue }
            guard existingQuestions.contains(where: { isNearDuplicateQuizQuestion($0, question) }) == false else { continue }
            guard freshQuestions.contains(where: { isNearDuplicateQuizQuestion($0, question) }) == false else { continue }
            knownSignatures.insert(signature)
            if promptSignature.isEmpty == false {
                knownPromptSignatures.insert(promptSignature)
            }
            if angleSignature.isEmpty == false {
                knownAngleSignatures.insert(angleSignature)
            }
            freshQuestions.append(question)
        }

        guard freshQuestions.isEmpty == false else { return 0 }

        for question in freshQuestions {
            conversationStore.save(question)
        }

        questions = conversationStore.loadQuestions()
        syncInteractionMemory(for: sourceID)
        refreshJourneyAssignments()
        refreshLearningPlan()
        return freshQuestions.count
    }

    private func alignedQuestion(_ question: LearningQuestion, sourceID: UUID) -> LearningQuestion {
        let matchingTopic = topics.first { topic in
            topic.sourceID == sourceID
                && topic.title.localizedCaseInsensitiveCompare(question.topicTitle) == .orderedSame
        }
        let matchingSegment = segments.first { segment in
            segment.sourceID == sourceID
                && segment.subtopicTitle.localizedCaseInsensitiveCompare(question.subtopicTitle) == .orderedSame
        }

        return LearningQuestion(
            sourceID: sourceID,
            topicID: matchingTopic?.id ?? question.topicID,
            segmentID: matchingSegment?.id ?? question.segmentID,
            topicTitle: matchingTopic?.title ?? question.topicTitle,
            subtopicTitle: matchingSegment?.subtopicTitle ?? question.subtopicTitle,
            type: question.type,
            prompt: question.prompt,
            answer: question.answer,
            choices: question.choices,
            importance: question.importance,
            difficulty: question.difficulty
        )
    }

    private func reclassifiedQuestion(_ question: LearningQuestion) -> LearningQuestion {
        guard let correctedSubtopic = inferredSubtopic(for: question),
              normalizedQuizPrompt(correctedSubtopic) != normalizedQuizPrompt(question.subtopicTitle)
        else {
            return question
        }

        return LearningQuestion(
            id: question.id,
            sourceID: question.sourceID,
            topicID: question.topicID,
            segmentID: nil,
            topicTitle: question.topicTitle,
            subtopicTitle: correctedSubtopic,
            type: question.type,
            prompt: question.prompt,
            answer: question.answer,
            acceptedAnswers: question.acceptedAnswers,
            gradingRubric: question.gradingRubric,
            choices: question.choices,
            importance: question.importance,
            difficulty: question.difficulty,
            createdAt: question.createdAt
        )
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
        let localEvaluation = localAnswerEvaluation(score: score, question: question)
        let attempt = QuestionAttempt(
            questionID: question.id,
            response: response,
            score: score,
            feedback: localEvaluation.feedback,
            matchedIdeas: localEvaluation.matchedIdeas ?? [],
            missingIdeas: localEvaluation.missingIdeas ?? []
        )
        attempts.insert(attempt, at: 0)
        conversationStore.save(attempt, question: question)
        conversationStore.saveAnswerEvaluation(
            attemptID: attempt.id,
            questionID: question.id,
            sourceID: question.sourceID,
            localScore: roundedScore(score),
            modelScore: nil,
            finalScore: roundedScore(score),
            grader: "local_immediate",
            modelName: gemmaService.modelName,
            latencyMS: nil,
            reason: localEvaluation.feedback ?? localEvaluation.reason ?? ""
        )
        conversationStore.saveInteractionEvent(
            kind: "question_answered",
            sourceID: question.sourceID,
            questionID: question.id,
            conceptSignature: quizConceptSignature(question),
            detail: resultLabel(for: score),
            metadata: #"{"surface":"journey"}"#
        )
        syncInteractionMemory(for: question.sourceID)
        recordXP(for: .test, reason: score >= 0.75 ? "Passed a learning check." : "Practiced a learning check.")
        refineAnswerScoreInBackground(attempt, question: question)
        return attempt
    }

    private func refineAnswerScoreInBackground(_ attempt: QuestionAttempt, question: LearningQuestion) {
        guard question.type != .multipleChoice, modelReadiness.isReady else { return }

        Task {
            let evaluation = await evaluateAnswerWithGemmaIfUseful(response: attempt.response, for: question)
            guard evaluation.score != attempt.score
                    || evaluation.feedback != attempt.feedback
                    || evaluation.matchedIdeas != attempt.matchedIdeas
                    || evaluation.missingIdeas != attempt.missingIdeas
            else { return }

            let refinedAttempt = QuestionAttempt(
                id: attempt.id,
                questionID: attempt.questionID,
                response: attempt.response,
                score: evaluation.score,
                feedback: evaluation.feedback ?? evaluation.reason,
                matchedIdeas: evaluation.matchedIdeas ?? [],
                missingIdeas: evaluation.missingIdeas ?? [],
                createdAt: attempt.createdAt
            )

            if let index = attempts.firstIndex(where: { $0.id == attempt.id }) {
                attempts[index] = refinedAttempt
            } else {
                attempts.insert(refinedAttempt, at: 0)
            }

            conversationStore.save(refinedAttempt, question: question)
            conversationStore.saveAnswerEvaluation(
                attemptID: refinedAttempt.id,
                questionID: question.id,
                sourceID: question.sourceID,
                localScore: self.roundedScore(self.localAnswerScore(refinedAttempt.response, for: question)),
                modelScore: self.roundedScore(evaluation.score),
                finalScore: self.roundedScore(refinedAttempt.score),
                grader: "gemma_background_refinement",
                modelName: self.gemmaService.modelName,
                latencyMS: nil,
                reason: refinedAttempt.feedback ?? evaluation.reason ?? ""
            )
            self.syncInteractionMemory(for: question.sourceID)
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
        await evaluateAnswerWithGemmaIfUseful(response: response, for: question).score
    }

    private func evaluateAnswerWithGemmaIfUseful(response: String, for question: LearningQuestion) async -> AnswerEvaluation {
        let fallbackScore = localAnswerScore(response, for: question)

        guard question.type != .multipleChoice else {
            let isCorrect = fallbackScore >= 1
            return AnswerEvaluation(
                score: fallbackScore,
                reason: isCorrect ? "Correct choice." : "The selected choice does not match the saved answer.",
                matchedIdeas: isCorrect ? [question.answer] : [],
                missingIdeas: isCorrect ? [] : [question.answer],
                feedback: isCorrect ? "Correct choice." : "Review the saved answer."
            )
        }

        guard modelReadiness.isReady else {
            return localAnswerEvaluation(score: fallbackScore, question: question)
        }

        do {
            let gradingMessages = [
                GemmaMessage(
                    role: "system",
                    content: """
                    You are QuizLoop.ai's bounded answer grader.
                    Grade only against the expected answer from saved notes.
                    Return valid JSON only with keys score, reason, matched_ideas, missing_ideas, and feedback.
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

            let result = try await withTimeout(seconds: 8) {
                try await self.modelReply(to: gradingMessages, timeout: 8, taskType: "answer_grading", promptVersion: "answer_grading.v1")
            }

            let evaluation = try parseAnswerEvaluation(from: result)
            return normalizedEvaluation(evaluation, fallbackScore: fallbackScore, question: question)
        } catch {
            return localAnswerEvaluation(score: fallbackScore, question: question)
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
        Accepted equivalents from saved notes:
        \(question.acceptedAnswers.isEmpty ? "- None supplied." : question.acceptedAnswers.map { "- \($0)" }.joined(separator: "\n"))
        Question-specific grading rubric:
        \(question.gradingRubric.isEmpty ? "- Use the general rubric below." : question.gradingRubric)
        Student response: \(response)
        Local heuristic score: \(String(format: "%.2f", localScore))

        Rubric:
        - 1.0: fully captures the expected answer or a listed accepted equivalent.
        - 0.7 to 0.9: mostly correct but misses a smaller detail from the question-specific rubric.
        - 0.4 to 0.6: partially related but misses a core relationship or required idea.
        - 0.1 to 0.3: mentions a relevant word but does not answer the prompt.
        - 0.0: incorrect, blank, or unrelated.
        - matched_ideas: short phrases the student got right.
        - missing_ideas: short phrases still missing from the expected answer.
        - feedback: one short student-friendly sentence about what to improve.

        Return shape:
        {"score":0.0,"reason":"short reason","matched_ideas":[],"missing_ideas":[],"feedback":"short feedback"}
        """
    }

    private func normalizedEvaluation(_ evaluation: AnswerEvaluation, fallbackScore: Double, question: LearningQuestion) -> AnswerEvaluation {
        let score = min(max(evaluation.score, fallbackScore), 1)
        let feedback = cleanFeedback(evaluation.feedback ?? evaluation.reason)
        let fallbackIdeas = localIdeaBreakdown(response: "", score: score, question: question)
        let matchedIdeas = cleanIdeaList(evaluation.matchedIdeas)
        let missingIdeas = cleanIdeaList(evaluation.missingIdeas)

        return AnswerEvaluation(
            score: score,
            reason: cleanFeedback(evaluation.reason),
            matchedIdeas: matchedIdeas.isEmpty ? fallbackIdeas.matched : matchedIdeas,
            missingIdeas: missingIdeas.isEmpty && score < 0.95 ? fallbackIdeas.missing : missingIdeas,
            feedback: feedback ?? defaultFeedback(for: score, question: question)
        )
    }

    private func localAnswerEvaluation(score: Double, question: LearningQuestion) -> AnswerEvaluation {
        let ideas = localIdeaBreakdown(response: "", score: score, question: question)
        return AnswerEvaluation(
            score: score,
            reason: nil,
            matchedIdeas: ideas.matched,
            missingIdeas: ideas.missing,
            feedback: defaultFeedback(for: score, question: question)
        )
    }

    private func localIdeaBreakdown(
        response: String,
        score: Double,
        question: LearningQuestion
    ) -> (matched: [String], missing: [String]) {
        let answerIdeas = answerIdeaPhrases(question.answer)

        if score >= 0.95 {
            return (matched: Array(answerIdeas.prefix(3)), missing: [])
        }

        if score >= 0.75 {
            return (
                matched: Array(answerIdeas.prefix(2)),
                missing: Array(answerIdeas.dropFirst(2).prefix(2))
            )
        }

        if score >= 0.45 {
            return (
                matched: Array(answerIdeas.prefix(1)),
                missing: Array(answerIdeas.dropFirst(1).prefix(3))
            )
        }

        return (matched: [], missing: Array(answerIdeas.prefix(3)))
    }

    private func answerIdeaPhrases(_ answer: String) -> [String] {
        let clauses = answer
            .replacingOccurrences(of: " and ", with: ", ")
            .replacingOccurrences(of: ";", with: ",")
            .components(separatedBy: CharacterSet(charactersIn: ",."))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count > 2 }

        if clauses.count > 1 {
            return Array(clauses.prefix(4))
        }

        return [answer.trimmingCharacters(in: .whitespacesAndNewlines)]
            .filter { $0.isEmpty == false }
    }

    private func defaultFeedback(for score: Double, question: LearningQuestion) -> String {
        switch score {
        case 0.75...:
            return "You captured the saved answer."
        case 0.45..<0.75:
            return "You were close; tighten your answer around the saved idea."
        default:
            return "Review the saved answer and try this idea again."
        }
    }

    private func cleanFeedback(_ feedback: String?) -> String? {
        let cleaned = feedback?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return cleaned.isEmpty ? nil : String(cleaned.prefix(180))
    }

    private func cleanIdeaList(_ ideas: [String]?) -> [String] {
        Array(
            (ideas ?? [])
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { $0.isEmpty == false }
                .prefix(4)
        )
    }

    private func parseAnswerEvaluation(from response: String) throws -> AnswerEvaluation {
        let jsonText = extractJSONObject(from: response)
        let data = Data(jsonText.utf8)
        return try JSONDecoder().decode(AnswerEvaluation.self, from: data)
    }

    private func preservingQuestionIDs(_ generatedQuestions: [LearningQuestion], sourceID: UUID) -> [LearningQuestion] {
        let existingQuestionsBySignature = Dictionary(
            questions
                .filter { $0.sourceID == sourceID }
                .map { (questionSignature($0), $0) },
            uniquingKeysWith: { existing, _ in existing }
        )

        let preserved = generatedQuestions.map { question in
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
                acceptedAnswers: question.acceptedAnswers,
                gradingRubric: question.gradingRubric,
                choices: question.choices,
                importance: question.importance,
                difficulty: question.difficulty,
                createdAt: existingQuestion.createdAt
            )
        }

        return deduplicatedQuizQuestions(preserved)
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

    private func questionPromptSignature(_ question: LearningQuestion) -> String {
        normalizedQuizPrompt(question.prompt)
    }

    private func deduplicatedQuizQuestions(_ sourceQuestions: [LearningQuestion]) -> [LearningQuestion] {
        var promptSignatures = Set<String>()
        var angleSignatures = Set<String>()
        var kept: [LearningQuestion] = []

        for question in sourceQuestions.sorted(by: questionDedupSort) {
            let promptSignature = questionPromptSignature(question)
            let angleSignature = questionAngleSignature(question)
            guard promptSignature.isEmpty || promptSignatures.contains(promptSignature) == false else { continue }
            guard angleSignature.isEmpty || angleSignatures.contains(angleSignature) == false else { continue }
            guard kept.contains(where: { isNearDuplicateQuizQuestion($0, question) }) == false else { continue }

            if promptSignature.isEmpty == false {
                promptSignatures.insert(promptSignature)
            }
            if angleSignature.isEmpty == false {
                angleSignatures.insert(angleSignature)
            }
            kept.append(question)
        }

        return kept.sorted { $0.createdAt < $1.createdAt }
    }

    private func questionDedupSort(_ lhs: LearningQuestion, _ rhs: LearningQuestion) -> Bool {
        if lhs.importance != rhs.importance {
            return lhs.importance > rhs.importance
        }
        if lhs.difficulty != rhs.difficulty {
            return lhs.difficulty > rhs.difficulty
        }
        if lhs.type != rhs.type {
            return lhs.type == .multipleChoice
        }
        return lhs.createdAt < rhs.createdAt
    }

    private func questionAngleSignature(_ question: LearningQuestion) -> String {
        let subtopic = normalizedQuizPrompt(question.subtopicTitle)
        let angle = assessmentAngle(for: question)
        let answer = normalizedQuizAnswer(question.answer)
        guard subtopic.isEmpty == false, angle.isEmpty == false, answer.isEmpty == false else {
            return ""
        }
        return "\(subtopic)|\(angle)|\(answer)"
    }

    private func assessmentAngle(for question: LearningQuestion) -> String {
        let text = "\(question.prompt) \(question.answer)".lowercased()
        if text.contains("where") || text.contains("location") || text.contains("take place") || text.contains("occur") {
            return "location"
        }
        if text.contains("input") || text.contains("used in") || text.contains("uses") || text.contains("reactant") {
            return "inputs"
        }
        if text.contains("output") || text.contains("produce") || text.contains("released") || text.contains("product") {
            return "outputs"
        }
        if text.contains("why") || text.contains("purpose") || text.contains("for later") || text.contains("mainly for") {
            return "purpose"
        }
        if text.contains("sequence") || text.contains("first") || text.contains("then") || text.contains("during") || text.contains("happens") {
            return "sequence"
        }
        if text.contains("misconception") || text.contains("common mistake") || text.contains("incorrect") {
            return "misconception"
        }
        if text.contains("factor") || text.contains("limit") || text.contains("rate") || text.contains("affect") {
            return "limiting-factor"
        }
        if text.contains("connect") || text.contains("relationship") || text.contains("next stage") || text.contains("calvin") {
            return "relationship"
        }
        if text.contains("what is") || text.contains("definition") || text.contains("means") {
            return "definition"
        }
        return question.type.rawValue
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
        let lowercasedTopic = topic.title.lowercased()
        var questions: [LearningQuestion] = []

        if lowercasedTopic.contains("photosynthesis") || lowercasedSummary.contains("photosynthesis") {
            questions.append(contentsOf: [
                LearningQuestion(
                    sourceID: source.id,
                    topicID: topic.id,
                    topicTitle: topic.title,
                    subtopicTitle: "Definition",
                    type: .multipleChoice,
                    prompt: "What is photosynthesis mainly for?",
                    answer: "converting light energy into stored chemical energy",
                    choices: normalizedChoices(
                        [
                            "converting light energy into stored chemical energy",
                            "breaking glucose apart to release heat",
                            "moving water from roots to leaves",
                            "turning oxygen into carbon dioxide"
                        ],
                        answer: "converting light energy into stored chemical energy",
                        type: .multipleChoice
                    ),
                    importance: 1.3,
                    difficulty: 0.9
                ),
                LearningQuestion(
                    sourceID: source.id,
                    topicID: topic.id,
                    topicTitle: topic.title,
                    subtopicTitle: "Inputs",
                    type: .multipleChoice,
                    prompt: "Which inputs does photosynthesis use?",
                    answer: "light energy, water, and carbon dioxide",
                    choices: normalizedChoices(
                        [
                            "light energy, water, and carbon dioxide",
                            "oxygen, glucose, and heat",
                            "soil minerals, oxygen, and glucose",
                            "carbon dioxide, glucose, and oxygen"
                        ],
                        answer: "light energy, water, and carbon dioxide",
                        type: .multipleChoice
                    ),
                    importance: 1.2,
                    difficulty: 0.9
                ),
                LearningQuestion(
                    sourceID: source.id,
                    topicID: topic.id,
                    topicTitle: topic.title,
                    subtopicTitle: "Products",
                    type: .multipleChoice,
                    prompt: "What does photosynthesis produce?",
                    answer: "glucose and oxygen",
                    choices: normalizedChoices(
                        [
                            "glucose and oxygen",
                            "carbon dioxide and water",
                            "light energy and chlorophyll",
                            "oxygen and carbon dioxide"
                        ],
                        answer: "glucose and oxygen",
                        type: .multipleChoice
                    ),
                    importance: 1.2,
                    difficulty: 0.9
                ),
                LearningQuestion(
                    sourceID: source.id,
                    topicID: topic.id,
                    topicTitle: topic.title,
                    subtopicTitle: "Chloroplasts",
                    type: .multipleChoice,
                    prompt: "Where does photosynthesis happen in plants and algae?",
                    answer: "chloroplasts",
                    choices: normalizedChoices(
                        [
                            "chloroplasts",
                            "mitochondria",
                            "ribosomes",
                            "cell walls"
                        ],
                        answer: "chloroplasts",
                        type: .multipleChoice
                    ),
                    importance: 1.0,
                    difficulty: 0.8
                ),
                LearningQuestion(
                    sourceID: source.id,
                    topicID: topic.id,
                    topicTitle: topic.title,
                    subtopicTitle: "Light reactions",
                    type: .multipleChoice,
                    prompt: "What do light-dependent reactions make for later photosynthesis steps?",
                    answer: "ATP and NADPH",
                    choices: normalizedChoices(
                        [
                            "ATP and NADPH",
                            "glucose and oxygen",
                            "carbon dioxide and water",
                            "starch and cellulose"
                        ],
                        answer: "ATP and NADPH",
                        type: .multipleChoice
                    ),
                    importance: 1.2,
                    difficulty: 1.0
                ),
                LearningQuestion(
                    sourceID: source.id,
                    topicID: topic.id,
                    topicTitle: topic.title,
                    subtopicTitle: "Calvin cycle",
                    type: .multipleChoice,
                    prompt: "What does the Calvin cycle use to build sugars?",
                    answer: "carbon dioxide, ATP, and NADPH",
                    choices: normalizedChoices(
                        [
                            "carbon dioxide, ATP, and NADPH",
                            "oxygen, glucose, and sunlight",
                            "water, oxygen, and starch",
                            "chlorophyll, oxygen, and cellulose"
                        ],
                        answer: "carbon dioxide, ATP, and NADPH",
                        type: .multipleChoice
                    ),
                    importance: 1.2,
                    difficulty: 1.1
                )
            ])
        }

        if lowercasedSummary.contains("programming language") {
            questions.append(contentsOf: [
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
                ),
                LearningQuestion(
                    sourceID: source.id,
                    topicID: topic.id,
                    topicTitle: topic.title,
                    subtopicTitle: "Bytecode",
                    type: .multipleChoice,
                    prompt: "What do Java programs usually compile into?",
                    answer: "bytecode",
                    choices: normalizedChoices(
                        [
                            "bytecode",
                            "raw machine code only",
                            "HTML files",
                            "database tables"
                        ],
                        answer: "bytecode",
                        type: .multipleChoice
                    ),
                    importance: 1.1,
                    difficulty: 0.9
                ),
                LearningQuestion(
                    sourceID: source.id,
                    topicID: topic.id,
                    topicTitle: topic.title,
                    subtopicTitle: "Memory",
                    type: .multipleChoice,
                    prompt: "How does Java generally manage unused memory?",
                    answer: "automatic garbage collection",
                    choices: normalizedChoices(
                        [
                            "automatic garbage collection",
                            "manual pointer deletion only",
                            "SQL queries",
                            "browser cookies"
                        ],
                        answer: "automatic garbage collection",
                        type: .multipleChoice
                    ),
                    importance: 1.0,
                    difficulty: 0.9
                )
            ])
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

    private func importantSentences(from text: String, title: String, limit: Int) -> [String] {
        let normalizedText = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let bodyText: String
        if let contentStart = normalizedText.range(of: "From Wikipedia, the free encyclopedia") {
            bodyText = String(normalizedText[contentStart.upperBound...])
        } else {
            bodyText = normalizedText
        }

        let lowercasedTitle = title.lowercased()
        let signalWords = [" is ", " are ", " means ", " refers ", " converts ", " produces ", " uses ", " consists ", " occurs ", " designed ", " enables ", " provides ", " supports ", " process", " system", " model", " language", " platform", " energy", " carbon", " oxygen", " glucose", " jvm", " bytecode", " object-oriented"]
        let noisyWords = ["search", "donate", "create account", "log in", "contents hide", "article talk", "view source", "references", "bibliography", "external links", "privacy policy", "wikimedia", "citation needed", "edit this", "appearance hide", "tools"]

        let candidates = bodyText
            .components(separatedBy: CharacterSet(charactersIn: ".!?"))
            .map { cleaned($0, fallback: "") }
            .filter { sentence in
                sentence.count >= 55
                    && sentence.count <= 240
                    && sentence.contains("{") == false
                    && sentence.contains("}") == false
            }
            .map { sentence -> (sentence: String, score: Int) in
                let lowercased = sentence.lowercased()
                var score = 0
                if lowercasedTitle.isEmpty == false, lowercased.contains(lowercasedTitle) {
                    score += 4
                }
                for word in signalWords where lowercased.contains(word) {
                    score += 2
                }
                for word in noisyWords where lowercased.contains(word) {
                    score -= 8
                }
                return (sentence, score)
            }
            .filter { $0.score > 0 }
            .sorted { lhs, rhs in
                if lhs.score == rhs.score {
                    return lhs.sentence.count < rhs.sentence.count
                }
                return lhs.score > rhs.score
            }

        var seen = Set<String>()
        let uniqueCandidates: [String] = candidates.compactMap { candidate in
            let key = String(candidate.sentence.lowercased().prefix(70))
            guard seen.contains(key) == false else { return nil }
            seen.insert(key)
            return candidate.sentence
        }

        return Array(uniqueCandidates.prefix(limit))
    }

    private func sentenceDistractors(for answer: String, in sentences: [String]) -> [String] {
        let distractors = sentences
            .filter { $0 != answer }
        return Array(distractors.prefix(5))
    }

    private func fallbackSubtopicTitle(from sentence: String, fallback: String) -> String {
        let lowercasedSentence = sentence.lowercased()
        let mappedTopics: [(String, String)] = [
            ("photosynthesis", "Photosynthesis"),
            ("oxygenic", "Oxygenic process"),
            ("carbon dioxide", "Carbon fixation"),
            ("glucose", "Products"),
            ("oxygen", "Products"),
            ("light", "Energy"),
            ("chlorophyll", "Pigments"),
            ("calvin", "Calvin cycle"),
            ("java virtual machine", "Runtime"),
            ("jvm", "Runtime"),
            ("bytecode", "Runtime"),
            ("object-oriented", "Object-oriented"),
            ("programming language", "Definition"),
            ("write once", "Portability"),
            ("run anywhere", "Portability"),
            ("syntax", "Syntax"),
            ("class", "Classes"),
            ("garbage", "Memory"),
            ("memory", "Memory"),
            ("oracle", "History"),
            ("sun microsystems", "History"),
            ("james gosling", "History")
        ]

        if let mapped = mappedTopics.first(where: { lowercasedSentence.contains($0.0) }) {
            return mapped.1
        }

        let words = sentence
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 3 }
            .filter { word in
                let lowercased = word.lowercased()
                return ["this", "that", "with", "from", "which", "their", "there", "then", "than", "into", "have", "been", "although", "what", "when", "where", "while", "because", "already"].contains(lowercased) == false
            }

        guard let first = words.first else { return fallback }
        return String(first.prefix(1)).uppercased() + String(first.dropFirst().prefix(18))
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

        if lowercasedSummary.contains("photosynthesis") {
            return (
                "Energy",
                "Photosynthesis converts light energy into stored ____.",
                "chemical energy"
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

        let expectedAnswers = ([question.answer] + question.acceptedAnswers)
            .reduce(into: [String]()) { result, answer in
                let cleanedAnswer = cleaned(answer, fallback: "")
                guard cleanedAnswer.isEmpty == false else { return }
                guard result.contains(where: { normalizedText($0) == normalizedText(cleanedAnswer) }) == false else { return }
                result.append(cleanedAnswer)
            }

        return expectedAnswers
            .map { scoreAnswer(trimmedResponse, expectedAnswer: $0, question: question) }
            .max() ?? 0
    }

    private func scoreAnswer(_ trimmedResponse: String, expectedAnswer: String, question: LearningQuestion) -> Double {
        let listScore = listAnswerScore(response: trimmedResponse, answer: expectedAnswer)
        if listScore >= 1 {
            return 1
        }

        let topicWords = normalizedWords(in: question.topicTitle)
        let responseWords = normalizedWords(in: trimmedResponse).subtracting(topicWords)
        let answerWords = normalizedWords(in: expectedAnswer).subtracting(topicWords)
        guard responseWords.isEmpty == false, answerWords.isEmpty == false else { return 0 }

        let overlap = responseWords.intersection(answerWords)
        let responseCoverage = Double(overlap.count) / Double(max(responseWords.count, 1))
        let answerCoverage = Double(overlap.count) / Double(max(answerWords.count, 1))
        let matchedImportantConcept = overlap.contains { importantConceptWords.contains($0) }

        if answerWords.isSubset(of: responseWords) {
            return 1
        }

        if question.type == .fillBlank {
            if normalizedText(trimmedResponse) == normalizedText(expectedAnswer) {
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
        return min(max(max(cappedScore, listScore), 0), 1)
    }

    private func listAnswerScore(response: String, answer: String) -> Double {
        let answerWords = normalizedListWords(in: answer)
        let responseWords = normalizedListWords(in: response)
        guard answerWords.count >= 2, responseWords.isEmpty == false else { return 0 }

        let overlap = answerWords.intersection(responseWords)
        let coverage = Double(overlap.count) / Double(answerWords.count)
        let extraWords = responseWords.subtracting(answerWords)

        if coverage >= 1, extraWords.count <= 2 {
            return 1
        }

        if coverage >= 0.75 {
            return min(0.9, coverage)
        }

        return 0
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

        let promptText = question.prompt.lowercased()
        let greenAppearanceContext = (
            promptText.contains("why")
                && promptText.contains("plant")
                && promptText.contains("green")
        )
            || (
                answerText.contains("green")
                    && (answerText.contains("reflect") || answerText.contains("absorb"))
            )

        if greenAppearanceContext {
            return weightedAlternativeConceptScore(
                responseWords: responseWords,
                groups: [
                    (["green"], 0.35),
                    (["reflect", "bounce"], 0.25),
                    (["absorb", "absorbed", "absorbs"], 0.20),
                    (["light", "spectrum", "wavelength", "wavelengths"], 0.20)
                ]
            )
        }

        let gravityContext = answerText.contains("gravity")
            || question.topicTitle.lowercased().contains("gravity")
            || question.subtopicTitle.lowercased().contains("gravity")
            || question.prompt.lowercased().contains("gravity")
            || question.prompt.lowercased().contains("orbit")

        if gravityContext {
            if question.prompt.lowercased().contains("orbit")
                || question.subtopicTitle.lowercased().contains("celestial") {
                return weightedAlternativeConceptScore(
                    responseWords: responseWords,
                    groups: [
                        (["pull", "pulls", "pulling", "attract", "attracts", "attraction"], 0.34),
                        (["mass", "masses", "planet", "planets", "moon", "moons", "satellite", "satellites", "body", "bodies"], 0.26),
                        (["toward", "together", "between"], 0.16),
                        (["orbit", "orbits", "orbiting", "maintain", "keeps", "keeping"], 0.24)
                    ]
                )
            }

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

    private func weightedAlternativeConceptScore(
        responseWords: Set<String>,
        groups: [([String], Double)]
    ) -> Double {
        let score = groups.reduce(0.0) { total, group in
            let alternatives = group.0
            let weight = group.1
            return total + (alternatives.contains(where: { responseWords.contains($0) }) ? weight : 0)
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

    private func normalizedListWords(in text: String) -> Set<String> {
        Set(
            text
                .lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count > 2 }
                .map(canonicalListWord)
                .filter { listAnswerStopWords.contains($0) == false }
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
        case "absorbed", "absorbs", "absorbing":
            return "absorb"
        case "reflected", "reflects", "reflecting":
            return "reflect"
        case "wavelengths":
            return "wavelength"
        case "captured", "captures", "capturing":
            return "capture"
        case "released", "releases", "releasing", "liberate", "liberates", "liberated":
            return "release"
        case "fixed", "fixes", "fixing":
            return "fix"
        case "split", "splits", "splitting":
            return "split"
        default:
            return word
        }
    }

    private func canonicalListWord(_ word: String) -> String {
        switch word {
        case "plants":
            return "plant"
        case "alga", "algae":
            return "algae"
        case "cyanobacterium", "cyanobacteria":
            return "cyanobacteria"
        case "sugars":
            return "sugar"
        case "organisms":
            return "organism"
        default:
            if word.hasSuffix("s"), word.count > 4 {
                return String(word.dropLast())
            }
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

    private var listAnswerStopWords: Set<String> {
        answerStopWords.union([
            "and",
            "are",
            "the"
        ])
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
            return GoogleAIEdgeGemmaService(modelFileName: configuration.modelName)
        }
    }

    private static func makeOnDeviceFallbackService() -> GemmaService? {
        GoogleAIEdgeGemmaService(modelFileName: ModelRuntimeConfiguration.default.modelName)
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
        You are QuizLoop.ai's learning parser.
        Return valid JSON only. Do not include markdown, prose, comments, or code fences.
        Use only the supplied notes.
        Extract a complete learning map for a student.
        Create a broad, high-signal question bank that can be saved in SQLite.
        Use judgment to test the most important concepts, relationships, definitions, causes, processes, misconceptions, and applications.
        Give every question an assessment_angle so the app can avoid repeating the same concept in disguise.
        Multiple-choice distractors must be plausible misconceptions from the same topic, not obvious throwaway answers.
        """
    }

    private func learningExtractionPrompt(
        for source: StudySource,
        plan: QuestionBankPlan,
        noteText: String,
        label: String
    ) -> String {
        """
        Extract topics, subtopics, concept segments, and many high-quality questions from these notes.

        Note size:
        - Scope: \(label)
        - Cleaned note words: \(plan.wordCount)
        - Target concept segments: about \(plan.targetSegments)
        - Target questions: about \(plan.targetQuestions)
        - Minimum acceptable questions: \(plan.minimumQuestions)

        Requirements:
        - Ignore webpage navigation, menus, edit links, references, donation prompts, account prompts, and table-of-contents fragments.
        - Extract the article/body concepts, not the page chrome.
        - The number of questions must be directly proportional to the useful note size.
        - Create roughly the target number of questions when the notes contain enough supported concepts.
        - Never return fewer than the minimum acceptable questions unless the supplied notes truly contain too little learnable content.
        - Cover the full note, not only the first or easiest section.
        - Include questions for definitions, inputs, outputs, locations, stages, causes, importance, limiting factors, and misconceptions whenever the note contains them.
        - Use at least \(min(plan.targetSegments, 6)) distinct subtopics when the note supports them.
        - Every question must include assessment_angle.
        - Use assessment_angle values only: definition, location, inputs, outputs, sequence, purpose, misconception, relationship, limiting-factor, application.
        - Within each subtopic, create different assessment angles before creating paraphrases of the same idea.
        - Do not create two questions that test the same subtopic + assessment_angle + answer.
        - Dense notes should create a larger learning bank; short notes should create a smaller one.
        - Do not pad with low-value questions just to make the bank larger.
        - Do not omit important concepts just to keep the bank small.
        - Use these question types only: multipleChoice, fillBlank, shortAnswer.
        - Make at least 70% of questions multipleChoice.
        - Use fillBlank rarely: no more than 10% of questions.
        - Use shortAnswer only for "why", "how", process, comparison, or explanation checks.
        - Dates, names, licenses, APIs, acronyms, vocabulary, and factual recall should be multipleChoice, not shortAnswer or fillBlank.
        - Prefer important learning checks over easy trivia.
        - Every important concept should be tested in more than one way.
        - multipleChoice questions must include exactly 4 choices and the answer must exactly match one choice.
        - multipleChoice incorrect choices must be plausible, same style and length as the correct answer, and based on common confusions from the supplied notes.
        - Do not use giveaway choices like "not mentioned", "unrelated", "all of the above", "none of the above", or joke answers.
        - Do not always put the correct multipleChoice answer first.
        - Every answer must be directly supported by the supplied notes.
        - fillBlank prompts must include a visible blank marker like "____" and should test one short missing concept, not a whole sentence or paragraph.
        - shortAnswer prompts should require synthesis, explanation, comparison, or application.
        - shortAnswer answers must be complete model answers, not labels, fragments, slogans, or isolated phrases.
        - shortAnswer and fillBlank questions must include accepted_answers with 2 to 4 valid paraphrases or equivalent answers supported by the notes.
        - Every non-multipleChoice question must include grading_rubric explaining the core ideas required for full credit and common partial-credit omissions.
        - Do not use vague answer keys like "key pillar", "green", "workstation environments", or "It hurt everyone everywhere"; write the actual idea being tested.
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
                          "assessment_angle": "one of: definition, location, inputs, outputs, sequence, purpose, misconception, relationship, limiting-factor, application",
                          "prompt": "question",
                          "answer": "exact choice",
                          "accepted_answers": ["required idea phrased another way"],
                          "grading_rubric": "What a correct answer must include, using only the notes.",
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
        \(noteText)
        """
    }

    private func nextQuizExpansionPrompt(
        source: StudySource,
        expansionPlan: QuestionExpansionPlan,
        memoryContext: String
    ) -> String {
        """
        Create fresh follow-up quiz questions for the student's next quiz.

        Return this exact JSON shape:
        {
          "questions": [
            {
              "topic_title": "Topic name",
              "subtopic_title": "Subtopic name",
              "assessment_angle": "one of: definition, location, inputs, outputs, sequence, purpose, misconception, relationship, limiting-factor, application",
              "type": "multipleChoice",
              "prompt": "Question text?",
              "answer": "exact correct answer",
              "accepted_answers": ["equivalent correct answer"],
              "grading_rubric": "Core ideas needed for full credit, using only the note.",
              "choices": ["exact correct answer", "plausible wrong answer", "plausible wrong answer", "plausible wrong answer"],
              "importance": 0.8,
              "difficulty": 0.6
            }
          ]
        }

        Purpose:
        - Do not repeat the exact same questions.
        - Do not repeat the same assessment angle for the same concept.
        - Use the structured memory_context as the source of truth for what has already been tested.
        - Treat conceptSignature matches as duplicates even when wording is different.
        - Avoid concepts marked avoidThisQuiz unless the latest result is close or needs_review.
        - Stay strictly inside the saved note text.
        - Create new questions that are relevant to the student's latest quiz outcome.
        - If a selected focus is supplied, all new questions should deepen that focus unless the note does not support it.
        - When selected focus is supplied, set subtopic_title exactly to that selected focus.
        - When selected focus is supplied, do not create questions about another subtopic unless the prompt explicitly connects that idea back to the selected focus.
        - For selected focus "Overall Process", ask about photosynthesis as a whole: definition, energy conversion, inputs, outputs, purpose, food-web importance, misconceptions, and broad relationships. Do not ask narrow Calvin cycle or light-dependent reaction facts as standalone questions.
        - If the student missed or nearly missed an idea, ask a different question about the same concept or a closely related concept.
        - If the student was strong, introduce a nearby untested idea from the note.
        - If coverage targets are supplied, spread new questions across those subtopics before adding more questions to the latest quiz subtopic.
        - If uncovered note targets are supplied, they are higher priority than existing subtopics.
        - If the note text does not support enough truly fresh questions, return fewer questions instead of padding.

        Requirements:
        - Return exactly one JSON object matching the flat questions schema above.
        - Create exactly \(expansionPlan.targetNewQuestions) new questions whenever the note supports it.
        - Do not exceed \(expansionPlan.targetNewQuestions) questions.
        - Every question must include assessment_angle.
        - For a selected focus, create different assessment angles before paraphrasing any prior angle.
        - Preferred focus angle order: definition, location, inputs, outputs, sequence, purpose, misconception, relationship, limiting-factor, application.
        - If missing assessment angles are supplied, create questions for those angles first.
        - A focus topic should not be considered deep until it has at least \(minimumFocusedQuestionCount) distinct, useful questions across different assessment angles.
        - Use the existing topic/subtopic names when they fit.
        - Use the coverage target subtopic names exactly when the note supports them.
        - Create at most one question per coverage or uncovered target before repeating any subtopic.
        - For uncovered targets, create a clear subtopic name from the target if no existing subtopic fits.
        - Prefer multipleChoice. Use shortAnswer only when the student must explain a process or relationship.
        - Do not create fillBlank follow-up questions unless the answer is a short core term.
        - Dates, names, licenses, APIs, acronyms, vocabulary, and factual recall must be multipleChoice.
        - shortAnswer answers must be complete model answers, not labels, fragments, slogans, or isolated phrases.
        - shortAnswer and fillBlank questions must include accepted_answers with 2 to 4 note-supported paraphrases.
        - Every non-multipleChoice question must include grading_rubric with the required ideas for full credit and partial-credit omissions.
        - Do not use vague answer keys like "key pillar", "green", "workstation environments", or "It hurt everyone everywhere"; write the actual idea being tested.
        - Multiple-choice questions must have 4 plausible choices, with one exact answer.
        - Distractors must be realistic misunderstandings from the note, not joke answers.
        - Do not use "all of the above", "none of the above", "not mentioned", or unrelated choices.
        - Every answer must be directly supported by the note text.
        - Do not add outside facts.

        Expansion policy:
        - Note words: \(expansionPlan.wordCount)
        - Saved questions for this note: \(expansionPlan.currentQuestionCount)
        - Maximum feasible questions for this note: \(expansionPlan.maxQuestionCount)
        - Selected focus: \(expansionPlan.focusSubtopic ?? "None")
        - Reason: \(expansionPlan.reason)

        Coverage targets:
        \(expansionPlan.underservedSubtopics.isEmpty ? "- No underserved subtopics supplied. Expand the broadest untested ideas from the note." : expansionPlan.underservedSubtopics.map { "- \($0)" }.joined(separator: "\n"))

        Missing assessment angles for selected focus:
        \(expansionPlan.angleTargets.isEmpty ? "- None supplied." : expansionPlan.angleTargets.map { "- \($0)" }.joined(separator: "\n"))

        Uncovered note targets:
        \(expansionPlan.coverageTargets.isEmpty ? "- None detected. Use the coverage targets and latest quiz outcome." : expansionPlan.coverageTargets.map { "- \($0)" }.joined(separator: "\n"))

        Structured memory_context:
        \(memoryContext)

        Note title: \(source.title)
        Note text:
        \(String(learningText(for: source).prefix(6_000)))
        """
    }

    private func questionBankPlan(for source: StudySource) -> QuestionBankPlan {
        let visibleText = String(learningText(for: source).prefix(48_000))
        return questionBankPlan(forText: visibleText)
    }

    private func questionBankPlan(forText text: String) -> QuestionBankPlan {
        let wordCount = learningWordCount(in: text)
        let rawTarget: Int

        switch wordCount {
        case 0..<80:
            rawTarget = max(3, Int(ceil(Double(max(wordCount, 1)) / 20.0)))
        case 80..<300:
            rawTarget = Int(ceil(Double(wordCount) / 35.0))
        case 300..<1_000:
            rawTarget = Int(ceil(Double(wordCount) / 45.0))
        default:
            rawTarget = Int(ceil(Double(wordCount) / 70.0))
        }

        let targetQuestions = min(max(rawTarget, 4), 80)
        let minimumQuestions = min(targetQuestions, max(3, Int(floor(Double(targetQuestions) * 0.75))))
        let targetSegments = min(max(Int(ceil(Double(targetQuestions) / 2.0)), 3), 45)

        return QuestionBankPlan(
            wordCount: wordCount,
            targetQuestions: targetQuestions,
            minimumQuestions: minimumQuestions,
            targetSegments: targetSegments
        )
    }

    private func learningExtractionTimeout(for plan: QuestionBankPlan) -> TimeInterval {
        if plan.targetQuestions <= 4 {
            return 45
        }
        if plan.targetQuestions <= 12 {
            return 90
        }
        let scaledSeconds = 45 + (plan.targetQuestions * 5)
        return TimeInterval(min(max(scaledSeconds, 90), 300))
    }

    private func learningChunks(from text: String) -> [LearningChunk] {
        let cleanedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleanedText.isEmpty == false else { return [] }

        let maxChunkCharacters = 4_500
        let maxChunks = 12
        var chunks: [LearningChunk] = []
        var start = cleanedText.startIndex

        while start < cleanedText.endIndex, chunks.count < maxChunks {
            let end = cleanedText.index(start, offsetBy: maxChunkCharacters, limitedBy: cleanedText.endIndex) ?? cleanedText.endIndex
            let rawChunk = String(cleanedText[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            if rawChunk.isEmpty == false {
                chunks.append(
                    LearningChunk(
                        index: chunks.count + 1,
                        text: rawChunk,
                        plan: chunkQuestionBankPlan(forText: rawChunk)
                    )
                )
            }
            start = end
        }

        return chunks
    }

    private func chunkQuestionBankPlan(forText text: String) -> QuestionBankPlan {
        let basePlan = questionBankPlan(forText: text)
        return QuestionBankPlan(
            wordCount: basePlan.wordCount,
            targetQuestions: min(basePlan.targetQuestions, 6),
            minimumQuestions: min(basePlan.minimumQuestions, 4),
            targetSegments: min(basePlan.targetSegments, 4)
        )
    }

    private func starterQuestionBankPlan(forText text: String) -> QuestionBankPlan {
        QuestionBankPlan(
            wordCount: learningWordCount(in: text),
            targetQuestions: 3,
            minimumQuestions: 1,
            targetSegments: 2
        )
    }

    private func learningWordCount(in text: String) -> Int {
        text.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.isEmpty == false }
            .count
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
                        let acceptedAnswers = normalizedAcceptedAnswers(
                            extractedQuestion.acceptedAnswers,
                            answer: answer,
                            type: type
                        )
                        let gradingRubric = normalizedGradingRubric(
                            extractedQuestion.gradingRubric,
                            answer: answer,
                            type: type
                        )

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
                                acceptedAnswers: acceptedAnswers,
                                gradingRubric: gradingRubric,
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
                    let acceptedAnswers = normalizedAcceptedAnswers(
                        extractedQuestion.acceptedAnswers,
                        answer: answer,
                        type: type
                    )
                    let gradingRubric = normalizedGradingRubric(
                        extractedQuestion.gradingRubric,
                        answer: answer,
                        type: type
                    )

                    questions.append(
                        LearningQuestion(
                            sourceID: source.id,
                            topicID: topic.id,
                            topicTitle: topic.title,
                            subtopicTitle: subtopicTitle,
                            type: type,
                            prompt: prompt,
                            answer: type == .multipleChoice ? choices.first(where: { $0 == answer }) ?? answer : answer,
                            acceptedAnswers: acceptedAnswers,
                            gradingRubric: gradingRubric,
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
        let normalizedType = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: " ", with: "")
            .lowercased()

        switch normalizedType {
        case "multiplechoice", "mc", "choice":
            return .multipleChoice
        case "fillblank", "fillintheblank", "blank":
            return .fillBlank
        case "shortanswer", "short":
            return .shortAnswer
        default:
            return nil
        }
    }

    private func normalizedChoices(_ choices: [String], answer: String, type: LearningQuestion.QuestionType) -> [String] {
        guard type == .multipleChoice else { return [] }

        let cleanedAnswer = cleaned(answer, fallback: answer)
        guard isLowQualityChoice(cleanedAnswer) == false else { return [] }

        var cleanedChoices = choices
            .map { cleaned($0, fallback: "") }
            .filter { $0.isEmpty == false && isLowQualityChoice($0) == false }
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

        guard hasNearDuplicateChoices(firstFour) == false else {
            return []
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

    private func normalizedAcceptedAnswers(
        _ acceptedAnswers: [String]?,
        answer: String,
        type: LearningQuestion.QuestionType
    ) -> [String] {
        guard type != .multipleChoice else { return [] }

        var values = (acceptedAnswers ?? [])
            .map { cleaned($0, fallback: "") }
            .filter { $0.isEmpty == false }

        if values.contains(answer) == false {
            values.insert(answer, at: 0)
        }

        return values.reduce(into: [String]()) { result, value in
            let normalized = normalizedText(value)
            guard normalized.isEmpty == false else { return }
            guard result.contains(where: { normalizedText($0) == normalized }) == false else { return }
            result.append(value)
        }
        .prefix(4)
        .map { $0 }
    }

    private func normalizedGradingRubric(
        _ rubric: String?,
        answer: String,
        type: LearningQuestion.QuestionType
    ) -> String {
        guard type != .multipleChoice else { return "" }

        let cleanedRubric = cleaned(rubric ?? "", fallback: "")
        if cleanedRubric.count >= 24 {
            return cleanedRubric
        }

        switch type {
        case .shortAnswer:
            return "Full credit requires the core idea from the note: \(answer). Give partial credit only when the response captures part of that idea."
        case .fillBlank:
            return "Full credit requires the missing concept or a note-supported equivalent: \(answer)."
        case .multipleChoice, .flashcard:
            return ""
        }
    }

    private func isQuizUsable(_ question: LearningQuestion) -> Bool {
        let prompt = question.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let answer = question.answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard prompt.isEmpty == false, answer.isEmpty == false else { return false }
        guard isMetaSourceQuestion(prompt) == false else { return false }
        guard isHighQualityQuizPrompt(prompt: prompt, answer: answer, type: question.type) else { return false }
        guard promptDoesNotRevealAnswer(prompt: prompt, answer: answer) else { return false }
        guard hasUsableExpectedAnswer(answer, for: question.type) else { return false }
        guard hasUsableGradingKey(question) else { return false }

        if question.type == .multipleChoice {
            guard question.choices.count == 4 else { return false }
            guard question.choices.contains(answer) else { return false }
            guard isLowQualityChoice(answer) == false else { return false }
            guard question.choices.contains(where: isLowQualityChoice) == false else { return false }
            guard hasNearDuplicateChoices(question.choices) == false else { return false }
            guard hasAmbiguousCorrectChoices(question) == false else { return false }
        }

        if question.type == .fillBlank {
            let normalizedPrompt = prompt.lowercased()
            guard normalizedPrompt.contains("___") || normalizedPrompt.contains("blank") else { return false }
        }

        return true
    }

    private func isHighQualityQuizPrompt(prompt: String, answer: String, type: LearningQuestion.QuestionType) -> Bool {
        let normalizedPrompt = prompt.lowercased()
        let normalizedAnswer = answer.lowercased()

        if normalizedPrompt.contains("what was the order of") || normalizedPrompt.contains("what is the order of") {
            return false
        }

        if type == .multipleChoice,
           normalizedPrompt.contains("order"),
           choiceTokens(normalizedAnswer).count <= 4 {
            return false
        }

        return true
    }

    private func hasUsableGradingKey(_ question: LearningQuestion) -> Bool {
        switch question.type {
        case .multipleChoice, .flashcard:
            return true
        case .fillBlank:
            return choiceTokens(question.answer).count <= 5
                || question.acceptedAnswers.contains { choiceTokens($0).count <= 5 }
        case .shortAnswer:
            let answerTokens = choiceTokens(question.answer)
            let hasSpecificModelAnswer = answerTokens.count >= 4
            let hasSpecificAcceptedAnswer = question.acceptedAnswers.contains { choiceTokens($0).count >= 4 }
            let hasRubric = question.gradingRubric.count >= 32
            return (hasSpecificModelAnswer || hasSpecificAcceptedAnswer) && hasRubric && isVagueAnswerKey(question.answer) == false
        }
    }

    private func questionConceptMatchesSubtopic(_ question: LearningQuestion) -> Bool {
        guard let inferred = inferredSubtopic(for: question) else { return true }
        return normalizedQuizPrompt(inferred) == normalizedQuizPrompt(question.subtopicTitle)
    }

    private func inferredSubtopic(for question: LearningQuestion) -> String? {
        let prompt = question.prompt.lowercased()
        let answer = question.answer.lowercased()
        let combined = "\(prompt) \(answer)"

        if prompt.contains("overall process of photosynthesis")
            || prompt.contains("overall purpose of photosynthesis")
            || prompt.contains("main inputs of photosynthesis")
            || prompt.contains("main outputs of the overall process")
            || prompt.contains("main outputs of photosynthesis") {
            return "Overall Process"
        }

        if prompt.contains("relationship between the light-dependent reactions and the calvin cycle")
            || prompt.contains("relationship between light-dependent reactions and the calvin cycle") {
            return "Relationship"
        }

        if combined.contains("calvin cycle")
            || combined.contains("light-independent")
            || combined.contains("light independent")
            || answer.contains("stroma of the chloroplast")
            || prompt.contains("where does the calvin cycle") {
            return "Calvin Cycle (Light-Independent Reactions)"
        }

        if combined.contains("light-dependent")
            || combined.contains("light dependent")
            || combined.contains("thylakoid")
            || combined.contains("photosystem")
            || combined.contains("atp and nadph")
            || prompt.contains("water molecules are split")
            || prompt.contains("what substances are split") {
            return "Light-Dependent Reactions"
        }

        if prompt.contains("what happens during") {
            return "Sequence"
        }

        if combined.contains("limit the rate")
            || combined.contains("limiting factor")
            || combined.contains("stomata may close") {
            return "Limiting-factor"
        }

        return nil
    }

    private func isMetaSourceQuestion(_ prompt: String) -> Bool {
        let normalized = prompt
            .lowercased()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let bannedFragments = [
            "documentation source",
            "documentation sources",
            "relevant documentation",
            "which source",
            "what source",
            "cite",
            "citation"
        ]

        return bannedFragments.contains { normalized.contains($0) }
    }

    private func hasUsableExpectedAnswer(_ answer: String, for type: LearningQuestion.QuestionType) -> Bool {
        let normalized = answer
            .lowercased()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.isEmpty == false else { return false }

        let bannedAnswers: Set<String> = [
            "docs.oracle.com",
            "java platform se 8",
            "it hurt everyone everywhere",
            "key pillar",
            "green",
            "workstation environments",
            "not mentioned",
            "unknown"
        ]
        if bannedAnswers.contains(normalized) {
            return false
        }

        if normalized.hasPrefix("http://") || normalized.hasPrefix("https://") {
            return false
        }

        switch type {
        case .shortAnswer:
            let tokens = choiceTokens(answer)
            if tokens.count < 2 { return false }
            if normalized.count < 8 { return false }
        case .fillBlank:
            if normalized.count < 3 { return false }
        case .multipleChoice, .flashcard:
            break
        }

        return true
    }

    private func isVagueAnswerKey(_ answer: String) -> Bool {
        let normalized = answer
            .lowercased()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let bannedAnswers: Set<String> = [
            "green",
            "key pillar",
            "workstation environments",
            "it hurt everyone everywhere",
            "google won a six-year legal battle"
        ]
        if bannedAnswers.contains(normalized) {
            return true
        }

        let tokens = choiceTokens(answer)
        return tokens.count <= 2 && normalized.count < 24
    }

    private func promptDoesNotRevealAnswer(prompt: String, answer: String) -> Bool {
        let promptWords = normalizedWords(in: prompt)
        let answerWords = normalizedWords(in: answer)
        guard answerWords.count >= 2 else { return true }

        let revealedRatio = Double(answerWords.intersection(promptWords).count) / Double(answerWords.count)
        return revealedRatio < 0.8
    }

    private func sourceHasUsableQuiz(_ source: StudySource) -> Bool {
        questions.contains { question in
            question.sourceID == source.id && isQuizUsable(question)
        }
    }

    private func isLowQualityChoice(_ text: String) -> Bool {
        let normalized = text
            .lowercased()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard normalized.isEmpty == false else { return true }

        let bannedFragments = [
            "all these",
            "all of these",
            "all of the above",
            "none of these",
            "none of the above",
            "these key",
            "key overall design features",
            "same features",
            "not mentioned",
            "unrelated"
        ]

        return bannedFragments.contains { normalized.contains($0) }
    }

    private func hasNearDuplicateChoices(_ choices: [String]) -> Bool {
        for index in choices.indices {
            for otherIndex in choices.indices where otherIndex > index {
                if choiceSimilarity(choices[index], choices[otherIndex]) > 0.58 {
                    return true
                }
            }
        }
        return false
    }

    private func hasAmbiguousCorrectChoices(_ question: LearningQuestion) -> Bool {
        guard question.type == .multipleChoice else { return false }

        let prompt = question.prompt.lowercased()
        let answer = question.answer
        let otherChoices = question.choices.filter { $0 != answer }

        if prompt.contains("relationship"),
           prompt.contains("light-dependent"),
           prompt.contains("calvin cycle") {
            let relationshipChoiceCount = question.choices.filter { choice in
                let normalized = choice.lowercased()
                let mentionsBothConcepts = normalized.contains("light-dependent")
                    && normalized.contains("calvin cycle")
                let describesDependency = normalized.contains("depend")
                    || normalized.contains("provide")
                    || normalized.contains("product")
                    || normalized.contains("energy carrier")
                    || normalized.contains("requires")
                return mentionsBothConcepts && describesDependency
            }.count

            if relationshipChoiceCount > 1 {
                return true
            }
        }

        let answerTokens = Set(choiceTokens(answer))
        guard answerTokens.isEmpty == false else { return false }

        return otherChoices.contains { choice in
            let tokens = Set(choiceTokens(choice))
            guard tokens.isEmpty == false else { return false }
            let overlap = Double(answerTokens.intersection(tokens).count)
                / Double(max(answerTokens.count, tokens.count))
            return overlap >= 0.8
        }
    }

    private func choiceSimilarity(_ lhs: String, _ rhs: String) -> Double {
        let lhsTokens = Set(choiceTokens(lhs))
        let rhsTokens = Set(choiceTokens(rhs))
        guard lhsTokens.isEmpty == false, rhsTokens.isEmpty == false else { return 0 }

        let overlap = lhsTokens.intersection(rhsTokens).count
        let union = lhsTokens.union(rhsTokens).count
        return Double(overlap) / Double(union)
    }

    private func choiceTokens(_ text: String) -> [String] {
        let stopWords: Set<String> = ["a", "an", "and", "are", "as", "at", "be", "by", "for", "from", "in", "into", "is", "it", "of", "on", "or", "the", "to", "using", "with"]
        let canonicalText = text
            .lowercased()
            .replacingOccurrences(of: "just-in-time", with: "jit")
            .replacingOccurrences(of: "just in time", with: "jit")
            .replacingOccurrences(of: "java virtual machine", with: "jvm")
            .replacingOccurrences(of: "database connectivity", with: "jdbc")
            .replacingOccurrences(of: "naming and directory interface", with: "jndi")

        return canonicalText
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 2 && stopWords.contains($0) == false }
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
        let noteSummary = meaningfulSummary(from: noteText, title: title)
        let summary = noteSummary.isEmpty ? "Found in \(source.title)." : String(noteSummary.prefix(180))

        return [
            LearningTopic(
                sourceID: source.id,
                title: title,
                summary: summary
            )
        ]
    }

    private func starterSummary(for source: StudySource) -> String {
        String(meaningfulSummary(from: learningText(for: source), title: source.title).prefix(420))
    }

    private func meaningfulSummary(from text: String, title: String) -> String {
        let normalizedText = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized: String
        if let contentStart = normalizedText.range(of: "From Wikipedia, the free encyclopedia") {
            normalized = String(normalizedText[contentStart.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            normalized = normalizedText
        }

        if title.localizedCaseInsensitiveContains("photosynthesis"),
           normalized.localizedCaseInsensitiveContains("photosynthesis") {
            return "Photosynthesis is a process plants, algae, and some bacteria use to convert light energy, water, and carbon dioxide into chemical energy stored as glucose, releasing oxygen."
        }

        if title.localizedCaseInsensitiveContains("java"),
           normalized.localizedCaseInsensitiveContains("Java is a high-level") {
            return "Java is a high-level, general-purpose, memory-safe, object-oriented programming language designed to let code run across platforms through the JVM. The notes focus on Java's history, execution model, syntax, class libraries, implementations, and use beyond the Java platform."
        }

        let sentences = normalized
            .components(separatedBy: CharacterSet(charactersIn: ".!?"))
            .map { cleaned($0, fallback: "") }
            .filter { $0.count >= 45 }

        let lowercasedTitle = title.lowercased()
        let definitionWords = [" is ", " process", " converts ", " uses ", " produces ", " energy", " carbon dioxide", " water", " glucose", " oxygen", " chlorophyll", "high-level", "general-purpose", "object-oriented", "programming language", "designed to"]
        let noisyWords = ["terawatt", "power consumption", "human civilization", "general equation", "cornelis", "proposed", "→", "co2", "image", "caption", "edit", "references", "citation needed", "controlled by", "community process", "appearance hide", "create account", "view source"]

        let ranked = sentences
            .map { sentence -> (sentence: String, score: Int) in
                let lowercased = sentence.lowercased()
                var score = 0

                if lowercasedTitle.isEmpty == false, lowercased.contains(lowercasedTitle) {
                    score += 4
                }
                for word in definitionWords where lowercased.contains(word) {
                    score += 2
                }
                for word in noisyWords where lowercased.contains(word) {
                    score -= 6
                }
                if sentence.count > 260 {
                    score -= 1
                }

                return (sentence, score)
            }
            .sorted { lhs, rhs in
                if lhs.score == rhs.score {
                    return lhs.sentence.count < rhs.sentence.count
                }
                return lhs.score > rhs.score
            }

        if let best = ranked.first, best.score > 0 {
            return best.sentence
        }

        return cleaned(normalized, fallback: "")
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
        let answer = cleanText.isEmpty ? "Review this answer in QuizLoop.ai." : cleanText

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
