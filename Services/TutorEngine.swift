import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

@MainActor
final class TutorEngine: ObservableObject {
    @Published private(set) var turns: [TutorTurn]
    @Published private(set) var sources: [StudySource]
    @Published private(set) var flashcards: [StudyFlashcard]

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
        self.flashcards = conversationStore.loadFlashcards(focusText: Self.practiceFocusText(from: savedTurns), limit: 30)
        if savedTurns.isEmpty {
            let welcomeTurn = TutorTurn(
                speaker: .waves,
                text: "Hi, I am Waves. Add class material or ask me anything.",
                createdAt: .now
            )
            self.turns = [welcomeTurn]
            conversationStore.save(welcomeTurn)
        } else {
            self.turns = savedTurns
        }

        Task {
            await refreshModelReadiness()
        }
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
    func submit(_ prompt: String) async -> String? {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedPrompt.isEmpty == false else { return nil }

        appendTurn(TutorTurn(speaker: .learner, text: trimmedPrompt, createdAt: .now))
        isResponding = true
        lastError = nil

        do {
            let matches = relevantSources(for: trimmedPrompt)
            let response = try await gemmaService.reply(to: conversationHistory(for: trimmedPrompt, matches: matches))
            appendTurn(TutorTurn(speaker: .waves, text: response, sourceTitles: matches.map(\.title), createdAt: .now))
            isResponding = false
            return response
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
            status: .ready,
            text: trimmedText
        )

        sources.insert(source, at: 0)
        conversationStore.save(source)
        refreshPracticeDeck()
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

            let message = "I made \(cards.count) flashcards. Open Practice to study them."
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

            let message = "I made \(cards.count) simple flashcards from that answer. Open Practice to study them."
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

    func reviewFlashcard(_ card: StudyFlashcard, grade: StudyFlashcard.ReviewGrade) {
        let reviewedCard = card.reviewed(grade)

        guard let index = flashcards.firstIndex(where: { $0.id == card.id }) else {
            return
        }

        flashcards[index] = reviewedCard
        conversationStore.save(reviewedCard)
        refreshPracticeDeck()
    }

    func refreshPracticeDeck() {
        flashcards = conversationStore.loadFlashcards(focusText: Self.practiceFocusText(from: turns), limit: 30)
    }

    private func appendTurn(_ turn: TutorTurn) {
        turns.append(turn)
        conversationStore.save(turn)
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
        let answer = cleanText.isEmpty ? "Review this answer in Waves." : cleanText

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
                Source: \(source.title)
                \(source.text.prefix(1_200))
                """
            }
            .joined(separator: "\n\n")

            history.insert(
                GemmaMessage(
                    role: "system",
                    content: """
                    Use this student-provided local context when relevant. If it does not answer the question, say so briefly.

                    \(context)
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
            Source: \(source.title)
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
        guard queryTerms.isEmpty == false else {
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

struct GemmaMessage: Codable, Equatable {
    let role: String
    let content: String
}

protocol GemmaService {
    var modelName: String { get }

    func reply(to messages: [GemmaMessage]) async throws -> String
    func isModelInstalled() async throws -> Bool
}

struct OllamaGemmaService: GemmaService {
    var endpoint: URL
    var tagsEndpoint: URL
    var model: String

    init(configuration: ModelRuntimeConfiguration = .default) {
        self.endpoint = configuration.chatEndpoint ?? ModelRuntimeConfiguration.default.chatEndpoint!
        self.tagsEndpoint = configuration.tagsEndpoint ?? ModelRuntimeConfiguration.default.tagsEndpoint!
        self.model = configuration.modelName
    }

    var modelName: String {
        model
    }

    func reply(to messages: [GemmaMessage]) async throws -> String {
        let requestBody = OllamaChatRequest(
            model: model,
            messages: [
                GemmaMessage(
                    role: "system",
                    content: "You are Waves, a simple helpful voice assistant. Keep answers concise and natural to speak out loud."
                )
            ] + messages,
            stream: false
        )

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(requestBody)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, 200..<300 ~= httpResponse.statusCode else {
            throw GemmaServiceError.badResponse
        }

        let decoded = try JSONDecoder().decode(OllamaChatResponse.self, from: data)
        return decoded.message.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func isModelInstalled() async throws -> Bool {
        var request = URLRequest(url: tagsEndpoint)
        request.timeoutInterval = 2

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, 200..<300 ~= httpResponse.statusCode else {
            throw GemmaServiceError.badResponse
        }

        let decoded = try JSONDecoder().decode(OllamaTagsResponse.self, from: data)
        return decoded.models.contains { installedModel in
            installedModel.name == model || installedModel.model == model
        }
    }
}

#if canImport(FoundationModels)
@available(iOS 26.0, *)
final class OnDeviceModelService: GemmaService {
    var modelName: String { "Apple Intelligence" }

    func reply(to messages: [GemmaMessage]) async throws -> String {
        var instructionParts = [
            "You are Waves, a private offline learning assistant.",
            "Help the user learn through clear explanations, short study plans, and one-question-at-a-time quizzes.",
            "Be concise and natural to speak out loud.",
            "Do not claim cloud access, live web access, or external account access."
        ]

        for message in messages where message.role == "system" {
            instructionParts.append(message.content)
        }

        let conversationMessages = messages.filter { $0.role != "system" }
        let priorTurns = conversationMessages.dropLast()
        if priorTurns.isEmpty == false {
            let contextLines = priorTurns.map { msg in
                "\(msg.role == "user" ? "Learner" : "You"): \(msg.content)"
            }
            instructionParts.append("Prior conversation:\n" + contextLines.joined(separator: "\n"))
        }

        let session = LanguageModelSession(instructions: instructionParts.joined(separator: "\n"))
        let lastPrompt = conversationMessages.last?.content ?? ""
        let response = try await session.respond(to: lastPrompt)
        return response.content
    }

    func isModelInstalled() async throws -> Bool {
        SystemLanguageModel.default.isAvailable
    }
}
#endif

struct OnDeviceGemmaServicePlaceholder: GemmaService {
    let model: String

    var modelName: String {
        model
    }

    func reply(to messages: [GemmaMessage]) async throws -> String {
        throw GemmaServiceError.onDeviceRuntimeUnavailable
    }

    func isModelInstalled() async throws -> Bool {
        false
    }
}

private struct OllamaChatRequest: Codable {
    let model: String
    let messages: [GemmaMessage]
    let stream: Bool
}

private struct OllamaChatResponse: Codable {
    let message: GemmaMessage
}

private struct OllamaTagsResponse: Codable {
    let models: [OllamaInstalledModel]
}

private struct OllamaInstalledModel: Codable {
    let name: String
    let model: String?
}

enum GemmaServiceError: LocalizedError {
    case badResponse
    case onDeviceRuntimeUnavailable

    var errorDescription: String? {
        switch self {
        case .badResponse:
            "Gemma returned an invalid response."
        case .onDeviceRuntimeUnavailable:
            "The on-device Gemma runtime is not bundled yet."
        }
    }
}

struct ModelRuntimeStore {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> ModelRuntimeConfiguration {
        let modeText = defaults.string(forKey: Keys.mode)
        let mode = modeText.flatMap(ModelRuntimeConfiguration.Mode.init(rawValue:)) ?? .localServer
        let serverURL = defaults.string(forKey: Keys.serverURL) ?? ModelRuntimeConfiguration.default.serverURLString
        let modelName = defaults.string(forKey: Keys.modelName) ?? ModelRuntimeConfiguration.default.modelName

        return ModelRuntimeConfiguration(
            mode: mode,
            serverURLString: serverURL,
            modelName: modelName
        )
    }

    func save(_ configuration: ModelRuntimeConfiguration) {
        defaults.set(configuration.mode.rawValue, forKey: Keys.mode)
        defaults.set(configuration.normalizedServerURLString, forKey: Keys.serverURL)
        defaults.set(configuration.modelName.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Keys.modelName)
    }

    private enum Keys {
        static let mode = "modelRuntime.mode"
        static let serverURL = "modelRuntime.serverURL"
        static let modelName = "modelRuntime.modelName"
    }
}
