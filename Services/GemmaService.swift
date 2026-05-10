import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

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
                    content: "You are Accordian, a private offline notes assistant for students. Answer from saved notes when they are relevant. Keep answers concise and natural to speak out loud."
                )
            ] + messages,
            stream: false
        )

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
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
            "You are Accordian, a private offline learning assistant.",
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
    case requestTimedOut

    var errorDescription: String? {
        switch self {
        case .badResponse:
            "Gemma returned an invalid response."
        case .onDeviceRuntimeUnavailable:
            "The on-device Gemma runtime is not bundled yet."
        case .requestTimedOut:
            "Gemma took too long to respond."
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
