import Foundation
#if canImport(MediaPipeTasksGenAI)
import MediaPipeTasksGenAI
#endif

struct GemmaMessage: Codable, Equatable {
    let role: String
    let content: String
}

protocol GemmaService {
    var modelName: String { get }

    func reply(to messages: [GemmaMessage]) async throws -> String
    func reply(to messages: [GemmaMessage], timeout: TimeInterval?) async throws -> String
    func isModelInstalled() async throws -> Bool
}

extension GemmaService {
    func reply(to messages: [GemmaMessage]) async throws -> String {
        try await reply(to: messages, timeout: nil)
    }
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
        try await reply(to: messages, timeout: nil)
    }

    func reply(to messages: [GemmaMessage], timeout: TimeInterval?) async throws -> String {
        let requestBody = OllamaChatRequest(
            model: model,
            messages: [
                GemmaMessage(
                    role: "system",
                    content: "You are QuizLoop.ai, a private offline notes assistant for students. Answer from saved notes when they are relevant. Keep answers concise and natural to speak out loud."
                )
            ] + messages,
            stream: false,
            think: false
        )

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout ?? 20
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

final class GoogleAIEdgeGemmaService: GemmaService {
    let modelFileName: String
    let maxTokens: Int
    let topK: Int
    let temperature: Float
    let randomSeed: Int

    init(
        modelFileName: String,
        maxTokens: Int = 1400,
        topK: Int = 40,
        temperature: Float = 0.4,
        randomSeed: Int = 101
    ) {
        self.modelFileName = modelFileName
        self.maxTokens = maxTokens
        self.topK = topK
        self.temperature = temperature
        self.randomSeed = randomSeed
    }

    var modelName: String { modelFileName }

    func reply(to messages: [GemmaMessage]) async throws -> String {
        try await reply(to: messages, timeout: nil)
    }

    func reply(to messages: [GemmaMessage], timeout: TimeInterval?) async throws -> String {
        #if canImport(MediaPipeTasksGenAI)
        guard let modelPath else {
            throw GemmaServiceError.modelFileMissing(modelFileName)
        }

        let prompt = Self.prompt(from: messages)
        let maxTokens = self.maxTokens
        let topK = self.topK
        let temperature = self.temperature
        let randomSeed = self.randomSeed

        return try await Task.detached(priority: .userInitiated) {
            let options = LlmInference.Options(modelPath: modelPath)
            options.maxTokens = maxTokens

            let llmInference = try LlmInference(options: options)
            let sessionOptions = LlmInference.Session.Options()
            sessionOptions.topk = topK
            sessionOptions.temperature = temperature
            sessionOptions.randomSeed = randomSeed

            let session = try LlmInference.Session(llmInference: llmInference, options: sessionOptions)
            try session.addQueryChunk(inputText: prompt)
            return try session.generateResponse()
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }.value
        #else
        throw GemmaServiceError.aiEdgeRuntimeUnavailable
        #endif
    }

    func isModelInstalled() async throws -> Bool {
        #if canImport(MediaPipeTasksGenAI)
        return modelPath != nil
        #else
        throw GemmaServiceError.aiEdgeRuntimeUnavailable
        #endif
    }

    private var modelPath: String? {
        GoogleAIEdgeModelStore.modelPath(named: modelFileName)
    }

    private static func prompt(from messages: [GemmaMessage]) -> String {
        let system = messages
            .filter { $0.role == "system" }
            .map(\.content)
            .joined(separator: "\n")

        let turns = messages
            .filter { $0.role != "system" }
            .map { message in
                "\(message.role == "user" ? "Learner" : "Assistant"): \(message.content)"
            }
            .joined(separator: "\n\n")

        return """
        You are QuizLoop.ai, a private offline learning assistant.
        Stay grounded in the supplied note context.
        Return exactly the requested format when the prompt asks for JSON.

        \(system)

        \(turns)
        """
    }
}

struct OnDeviceGemmaServicePlaceholder: GemmaService {
    let model: String

    var modelName: String {
        model
    }

    func reply(to messages: [GemmaMessage]) async throws -> String {
        try await reply(to: messages, timeout: nil)
    }

    func reply(to messages: [GemmaMessage], timeout: TimeInterval?) async throws -> String {
        throw GemmaServiceError.aiEdgeRuntimeUnavailable
    }

    func isModelInstalled() async throws -> Bool {
        false
    }
}

private struct OllamaChatRequest: Codable {
    let model: String
    let messages: [GemmaMessage]
    let stream: Bool
    let think: Bool
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
    case aiEdgeRuntimeUnavailable
    case modelFileMissing(String)
    case requestTimedOut

    var errorDescription: String? {
        switch self {
        case .badResponse:
            "Gemma returned an invalid response."
        case .aiEdgeRuntimeUnavailable:
            "Google AI Edge is not linked in this build."
        case .modelFileMissing(let model):
            "The on-device Gemma model file \(model) is not bundled or imported."
        case .requestTimedOut:
            "Gemma took too long to respond."
        }
    }
}

enum GoogleAIEdgeModelStore {
    static var modelsDirectory: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "QuizLoop", directoryHint: .isDirectory)
            .appending(path: "Models", directoryHint: .isDirectory)
    }

    static func importModel(from sourceURL: URL) throws -> String {
        let didStartAccessing = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        try FileManager.default.createDirectory(
            at: modelsDirectory,
            withIntermediateDirectories: true
        )

        let destinationURL = modelsDirectory.appending(path: sourceURL.lastPathComponent)
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }

        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        return destinationURL.lastPathComponent
    }

    static func modelPath(named modelFileName: String) -> String? {
        let trimmedName = modelFileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedName.isEmpty == false else { return nil }

        let directURL = URL(fileURLWithPath: trimmedName)
        if directURL.isFileURL, directURL.pathExtension.isEmpty == false,
           FileManager.default.fileExists(atPath: directURL.path) {
            return directURL.path
        }

        let importedURL = modelsDirectory.appending(path: trimmedName)
        if FileManager.default.fileExists(atPath: importedURL.path) {
            return importedURL.path
        }

        let file = URL(fileURLWithPath: trimmedName)
        if file.pathExtension.isEmpty == false {
            return Bundle.main.path(
                forResource: file.deletingPathExtension().lastPathComponent,
                ofType: file.pathExtension
            )
        }

        return Bundle.main.path(forResource: trimmedName, ofType: "bin")
            ?? Bundle.main.path(forResource: trimmedName, ofType: "task")
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
