import CryptoKit
import Foundation

@MainActor
final class TutorEngine: ObservableObject {
    private static let localAIModelDefaultsKey = "waves.localAI.model"
    private static let localAIDownloadURLDefaultsKey = "waves.localAI.downloadURL"
    private static let localAIChecksumDefaultsKey = "waves.localAI.checksum"
    private static let localAIPackageFilenameDefaultsKey = "waves.localAI.packageFilename"

    @Published private(set) var turns: [TutorTurn]
    @Published private(set) var memory: LearningMemory
    @Published private(set) var localAIConfiguration: LocalAIConfiguration

    @Published private(set) var isResponding = false
    @Published private(set) var lastError: String?
    @Published private(set) var modelReadiness: ModelReadiness = .checking
    @Published private(set) var downloadProgress: Double?

    private let gemmaService: GemmaService
    private let conversationStore: ConversationStore

    init(
        gemmaService: GemmaService = DownloadableGemmaService(),
        conversationStore: ConversationStore = ConversationStore()
    ) {
        let localAIConfiguration = Self.loadLocalAIConfiguration()

        self.localAIConfiguration = localAIConfiguration
        self.gemmaService = gemmaService
        self.conversationStore = conversationStore
        self.gemmaService.updateConfiguration(localAIConfiguration)

        self.memory = conversationStore.loadMemory()

        let savedTurns = conversationStore.loadTurns()
        if savedTurns.isEmpty {
            let welcomeTurn = TutorTurn(
                speaker: .waves,
                text: "Hi, I am Waves. I can help you learn offline, remember your goals on this device, and quiz you when you are ready.",
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
        downloadProgress = nil

        switch await gemmaService.installState() {
        case .notConfigured:
            modelReadiness = .notConfigured(localAIConfiguration.displayModel)
        case .missing:
            modelReadiness = .modelMissing(localAIConfiguration.displayModel)
        case .ready:
            modelReadiness = .ready(localAIConfiguration.displayModel)
        }
    }

    func downloadModel() async {
        let model = localAIConfiguration.displayModel
        modelReadiness = .downloading(model)
        downloadProgress = 0

        do {
            try await gemmaService.downloadModel { [weak self] progress in
                Task { @MainActor in
                    self?.downloadProgress = progress
                }
            }
            await refreshModelReadiness()
        } catch {
            modelReadiness = .downloadFailed(model)
            downloadProgress = nil
        }
    }

    func removeModel() {
        do {
            try gemmaService.removeDownloadedModel()
            modelReadiness = localAIConfiguration.hasRemotePackage ? .modelMissing(localAIConfiguration.displayModel) : .notConfigured(localAIConfiguration.displayModel)
            downloadProgress = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func updateLocalAIConfiguration(downloadURL: String, model: String, checksum: String, packageFilename: String) {
        let downloadURL = downloadURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let checksum = checksum.trimmingCharacters(in: .whitespacesAndNewlines)
        let packageFilename = packageFilename.trimmingCharacters(in: .whitespacesAndNewlines)

        let updatedConfiguration = LocalAIConfiguration(
            model: model.isEmpty ? LocalAIConfiguration.defaultModel : model,
            downloadURL: downloadURL,
            checksum: checksum,
            packageFilename: packageFilename.isEmpty ? LocalAIConfiguration.defaultFilename : packageFilename
        )

        localAIConfiguration = updatedConfiguration
        gemmaService.updateConfiguration(updatedConfiguration)

        UserDefaults.standard.set(updatedConfiguration.model, forKey: Self.localAIModelDefaultsKey)
        UserDefaults.standard.set(updatedConfiguration.downloadURL, forKey: Self.localAIDownloadURLDefaultsKey)
        UserDefaults.standard.set(updatedConfiguration.checksum, forKey: Self.localAIChecksumDefaultsKey)
        UserDefaults.standard.set(updatedConfiguration.packageFilename, forKey: Self.localAIPackageFilenameDefaultsKey)
    }

    @discardableResult
    func submit(_ prompt: String, modelPrompt: String? = nil, images: [Data] = []) async -> String? {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedPrompt.isEmpty == false || images.isEmpty == false else { return nil }

        let displayedPrompt = trimmedPrompt.isEmpty ? "Image question" : trimmedPrompt
        appendTurn(TutorTurn(speaker: .learner, text: displayedPrompt, createdAt: .now))
        isResponding = true
        lastError = nil

        do {
            let response = try await gemmaService.reply(to: conversationHistory(modelPrompt: modelPrompt, images: images))
            appendTurn(TutorTurn(speaker: .waves, text: response, createdAt: .now))
            isResponding = false
            return response
        } catch {
            let message = fallbackErrorMessage()
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

    func setMemoryEnabled(_ isEnabled: Bool) {
        memory.isEnabled = isEnabled
        conversationStore.saveMemory(memory)
    }

    func setGoal(_ goal: String) {
        let trimmedGoal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedGoal.isEmpty == false else { return }
        memory.currentGoal = trimmedGoal
        conversationStore.saveMemory(memory)
    }

    func rememberTopic(_ topic: String) {
        let trimmedTopic = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedTopic.isEmpty == false else { return }
        if memory.weakTopics.contains(trimmedTopic) == false {
            memory.weakTopics.insert(trimmedTopic, at: 0)
            memory.weakTopics = Array(memory.weakTopics.prefix(8))
            conversationStore.saveMemory(memory)
        }
    }

    func saveNote(_ note: String) {
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedNote.isEmpty == false else { return }
        guard memory.savedNotes.contains(trimmedNote) == false else { return }
        memory.savedNotes.insert(trimmedNote, at: 0)
        memory.savedNotes = Array(memory.savedNotes.prefix(12))
        conversationStore.saveMemory(memory)
    }

    func clearMemory() {
        conversationStore.deleteMemory()
        memory = conversationStore.loadMemory()
    }

    private func appendTurn(_ turn: TutorTurn) {
        turns.append(turn)
        conversationStore.save(turn)
    }

    private func fallbackErrorMessage() -> String {
        let model = localAIConfiguration.displayModel

        switch modelReadiness {
        case .notConfigured:
            return "Add a model download URL in Settings before trying to install \(model) on this iPhone."
        case .modelMissing, .downloadFailed:
            return "\(model) is not installed on this iPhone yet. Download it in the setup screen, then try again."
        case .runtimeUnavailable(let reason):
            return reason
        default:
            return "The on-device model is not ready yet. Finish installing \(model), then try again."
        }
    }

    private func conversationHistory(modelPrompt: String? = nil, images: [Data] = []) -> [GemmaMessage] {
        var history: [GemmaMessage] = []

        if memory.isEnabled {
            history.append(
                GemmaMessage(
                    role: "system",
                    content: "Private local context for this learner:\n\(memory.contextSummary)"
                )
            )
        }

        let recentTurns = turns.suffix(24)
        history += recentTurns.map { turn in
            GemmaMessage(
                role: turn.speaker == .learner ? "user" : "assistant",
                content: turn.text
            )
        }

        if
            let modelPrompt = modelPrompt?.trimmingCharacters(in: .whitespacesAndNewlines),
            modelPrompt.isEmpty == false,
            let lastUserIndex = history.lastIndex(where: { $0.role == "user" })
        {
            history[lastUserIndex] = GemmaMessage(
                role: "user",
                content: modelPrompt,
                images: images.map { $0.base64EncodedString() }.nilIfEmpty
            )
        } else if images.isEmpty == false, let lastUserIndex = history.lastIndex(where: { $0.role == "user" }) {
            history[lastUserIndex] = GemmaMessage(
                role: "user",
                content: history[lastUserIndex].content,
                images: images.map { $0.base64EncodedString() }
            )
        }

        return history
    }

    private static func loadLocalAIConfiguration() -> LocalAIConfiguration {
        let defaults = UserDefaults.standard

        return LocalAIConfiguration(
            model: defaults.string(forKey: localAIModelDefaultsKey) ?? LocalAIConfiguration.defaultModel,
            downloadURL: defaults.string(forKey: localAIDownloadURLDefaultsKey) ?? "",
            checksum: defaults.string(forKey: localAIChecksumDefaultsKey) ?? "",
            packageFilename: defaults.string(forKey: localAIPackageFilenameDefaultsKey) ?? LocalAIConfiguration.defaultFilename
        )
    }
}

struct GemmaMessage: Codable, Equatable {
    let role: String
    let content: String
    var images: [String]? = nil
}

protocol GemmaService {
    func updateConfiguration(_ configuration: LocalAIConfiguration)
    func reply(to messages: [GemmaMessage]) async throws -> String
    func installState() async -> LocalModelInstallState
    func downloadModel(progress: @escaping @Sendable (Double?) -> Void) async throws
    func removeDownloadedModel() throws
}

protocol OnDeviceGemmaRuntime {
    func reply(to messages: [GemmaMessage], modelName: String, modelFileURL: URL) async throws -> String
}

struct OnDeviceGemmaRuntimeFactory {
    static func makeDefaultRuntime() -> OnDeviceGemmaRuntime {
        LiteRTGemmaRuntime()
    }
}

struct LiteRTGemmaRuntime: OnDeviceGemmaRuntime {
    func reply(to messages: [GemmaMessage], modelName: String, modelFileURL: URL) async throws -> String {
        if LiteRTBridge.isAvailable {
            return try await LiteRTBridge.shared.generateReply(
                for: messages,
                modelName: modelName,
                modelFileURL: modelFileURL
            )
        }

        return try await PreviewOnDeviceGemmaRuntime().reply(
            to: messages,
            modelName: modelName,
            modelFileURL: modelFileURL
        )
    }
}

final class LiteRTBridge {
    static let shared = LiteRTBridge()
    static let isAvailable = false

    private init() {}

    func generateReply(for messages: [GemmaMessage], modelName: String, modelFileURL: URL) async throws -> String {
        throw GemmaServiceError.runtimeUnavailable(
            "Gemma runtime is not linked yet. Add the LiteRT-LM iOS bridge to enable real on-device inference for \(modelName)."
        )
    }
}

final class DownloadableGemmaService: GemmaService {
    private var configuration = LocalAIConfiguration()
    private let runtime: OnDeviceGemmaRuntime

    init(runtime: OnDeviceGemmaRuntime = OnDeviceGemmaRuntimeFactory.makeDefaultRuntime()) {
        self.runtime = runtime
    }

    func updateConfiguration(_ configuration: LocalAIConfiguration) {
        self.configuration = configuration
    }

    func reply(to messages: [GemmaMessage]) async throws -> String {
        guard await installState() == .ready else {
            throw GemmaServiceError.modelNotInstalled(configuration.displayModel)
        }

        return try await runtime.reply(
            to: messages,
            modelName: configuration.displayModel,
            modelFileURL: installedModelURL
        )
    }

    func installState() async -> LocalModelInstallState {
        guard configuration.hasRemotePackage else {
            return .notConfigured
        }

        return FileManager.default.fileExists(atPath: installedModelURL.path) ? .ready : .missing
    }

    func downloadModel(progress: @escaping @Sendable (Double?) -> Void) async throws {
        guard let packageURL = configuration.packageURL else {
            throw GemmaServiceError.invalidModelConfiguration
        }

        progress(0.05)
        let (temporaryURL, _) = try await URLSession.shared.download(from: packageURL)
        progress(0.75)

        if configuration.trimmedChecksum.isEmpty == false {
            let digest = try Self.sha256(for: temporaryURL)
            guard digest.caseInsensitiveCompare(configuration.trimmedChecksum) == .orderedSame else {
                throw GemmaServiceError.checksumMismatch
            }
        }

        let fileManager = FileManager.default
        let modelsDirectory = installedModelURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)

        if fileManager.fileExists(atPath: installedModelURL.path) {
            try fileManager.removeItem(at: installedModelURL)
        }

        try fileManager.moveItem(at: temporaryURL, to: installedModelURL)
        progress(1.0)
    }

    func removeDownloadedModel() throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: installedModelURL.path) {
            try fileManager.removeItem(at: installedModelURL)
        }
    }

    private var installedModelURL: URL {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return baseURL
            .appending(path: "Waves", directoryHint: .isDirectory)
            .appending(path: "Models", directoryHint: .isDirectory)
            .appending(path: configuration.normalizedPackageFilename)
    }

    private static func sha256(for fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1_048_576) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }

        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

private struct PreviewOnDeviceGemmaRuntime: OnDeviceGemmaRuntime {
    func reply(to messages: [GemmaMessage], modelName: String, modelFileURL: URL) async throws -> String {
        let latestPrompt = messages.last(where: { $0.role == "user" })?.content.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard latestPrompt.isEmpty == false else {
            return "Your on-device \(modelName) package is installed. Ask me a question and I’ll help you study locally."
        }

        let lowercasePrompt = latestPrompt.lowercased()

        if lowercasePrompt.contains("quiz") {
            return "Quick quiz time. What is the main idea behind: \(latestPrompt)? Answer in one or two sentences, and I’ll check it."
        }

        if lowercasePrompt.contains("plan") {
            return "Study plan:\n1. Define the goal in one sentence.\n2. Spend 15 minutes reviewing the core concept: \(latestPrompt).\n3. Practice one example from memory.\n4. End with one short self-test question."
        }

        if lowercasePrompt.contains("review") {
            return "Review summary for \(latestPrompt): start with the key concept, list two confusing parts, then explain one example out loud to lock it in."
        }

        return "Here’s a concise local explanation of \(latestPrompt): start with the core definition, connect it to a simple example, then restate it in your own words. If you want, I can turn this into a one-question quiz next."
    }
}

private extension Array {
    var nilIfEmpty: [Element]? {
        isEmpty ? nil : self
    }
}

enum GemmaServiceError: LocalizedError {
    case invalidModelConfiguration
    case checksumMismatch
    case modelNotInstalled(String)
    case runtimeUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .invalidModelConfiguration:
            "Add a valid HTTPS model URL in Settings before downloading the model package."
        case .checksumMismatch:
            "The downloaded model package did not match the expected checksum."
        case .modelNotInstalled(let model):
            "\(model) is not installed on this iPhone yet."
        case .runtimeUnavailable(let message):
            message
        }
    }
}
