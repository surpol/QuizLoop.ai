import Foundation
#if canImport(LlamaSwift)
import LlamaSwift
#endif
#if canImport(MediaPipeTasksGenAI)
import MediaPipeTasksGenAI
#endif
#if canImport(LiteRTLM)
import LiteRTLM
#endif
#if canImport(LiteRTLMSwift)
import LiteRTLMSwift
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
        if modelFileName.lowercased().hasSuffix(".litertlm") {
            return try await replyWithLiteRTLM(to: messages)
        }

        #if canImport(MediaPipeTasksGenAI)
        guard let modelPath else {
            throw GemmaServiceError.modelFileMissing(modelFileName)
        }
        try GoogleAIEdgeModelStore.validateMediaPipeModel(atPath: modelPath, modelName: modelFileName)

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
        if modelFileName.lowercased().hasSuffix(".litertlm") {
            guard let modelPath else { return false }
            try GoogleAIEdgeModelStore.validateMediaPipeModel(atPath: modelPath, modelName: modelFileName)
            #if canImport(LiteRTLM)
            return true
            #elseif canImport(LiteRTLMSwift)
            return true
            #else
            throw GemmaServiceError.aiEdgeRuntimeUnavailable
            #endif
        }

        #if canImport(MediaPipeTasksGenAI)
        guard let modelPath else { return false }
        try GoogleAIEdgeModelStore.validateMediaPipeModel(atPath: modelPath, modelName: modelFileName)
        return true
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

    private func replyWithLiteRTLM(to messages: [GemmaMessage]) async throws -> String {
        #if canImport(LiteRTLM)
        guard let modelPath else {
            throw GemmaServiceError.modelFileMissing(modelFileName)
        }
        try GoogleAIEdgeModelStore.validateMediaPipeModel(atPath: modelPath, modelName: modelFileName)

        let system = messages
            .filter { $0.role == "system" }
            .map(\.content)
            .joined(separator: "\n")
        let userPrompt = Self.prompt(from: messages)
        let tokenLimit = max(512, maxTokens)
        let topK = topK
        let temperature = temperature
        let randomSeed = randomSeed

        return try await Task.detached(priority: .userInitiated) {
            let engineConfig = try EngineConfig(
                modelPath: modelPath,
                backend: .gpu,
                maxNumTokens: tokenLimit,
                cacheDir: NSTemporaryDirectory()
            )
            let engine = Engine(engineConfig: engineConfig)
            try await engine.initialize()

            let samplerConfig = try SamplerConfig(
                topK: topK,
                topP: 0.95,
                temperature: temperature,
                seed: randomSeed
            )
            let conversationConfig = ConversationConfig(
                systemMessage: system.isEmpty ? nil : Message(system, role: .system),
                samplerConfig: samplerConfig
            )
            let conversation = try await engine.createConversation(with: conversationConfig)
            let response = try await conversation.sendMessage(Message(userPrompt))
            return response.toString.trimmingCharacters(in: .whitespacesAndNewlines)
        }.value
        #else
        return try await replyWithVendoredLiteRTLM(to: messages)
        #endif
    }

    private func replyWithVendoredLiteRTLM(to messages: [GemmaMessage]) async throws -> String {
        #if canImport(LiteRTLMSwift)
        guard let modelPath else {
            throw GemmaServiceError.modelFileMissing(modelFileName)
        }
        try GoogleAIEdgeModelStore.validateMediaPipeModel(atPath: modelPath, modelName: modelFileName)

        let prompt = Self.gemma4Prompt(from: messages)
        let tokenLimit = max(512, maxTokens)
        let temperature = temperature

        let engine = LiteRTLMEngine(modelPath: URL(fileURLWithPath: modelPath), backend: "cpu")
        try await engine.load()
        return try await engine.generate(
            prompt: prompt,
            temperature: temperature,
            maxTokens: tokenLimit
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
        #else
        throw GemmaServiceError.aiEdgeRuntimeUnavailable
        #endif
    }

    private static func gemma4Prompt(from messages: [GemmaMessage]) -> String {
        var parts: [String] = []

        for message in messages {
            let role: String
            let content: String
            switch message.role {
            case "system":
                role = "user"
                content = "Instruction:\n\(message.content)"
            case "assistant", "model":
                role = "model"
                content = message.content
            default:
                role = "user"
                content = message.content
            }

            parts.append(
                """
                <|turn>\(role)
                \(content)
                <turn|>
                """
            )
        }

        parts.append("<|turn>model\n")
        return parts.joined(separator: "\n")
    }
}

final class LlamaCppGemmaService: GemmaService {
    let modelFileName: String
    let maxTokens: Int32

    init(modelFileName: String, maxTokens: Int32 = 1400) {
        self.modelFileName = modelFileName
        self.maxTokens = maxTokens
    }

    var modelName: String { modelFileName }

    func reply(to messages: [GemmaMessage]) async throws -> String {
        try await reply(to: messages, timeout: nil)
    }

    func reply(to messages: [GemmaMessage], timeout: TimeInterval?) async throws -> String {
        #if canImport(LlamaSwift)
        guard let modelPath else {
            throw GemmaServiceError.modelFileMissing(modelFileName)
        }
        try GGUFGemmaModelStore.validateModel(atPath: modelPath, modelName: modelFileName)

        let prompt = Self.prompt(from: messages)
        let maxTokens = self.maxTokens

        return try await Task.detached(priority: .userInitiated) {
            try Self.generate(prompt: prompt, modelPath: modelPath, maxTokens: maxTokens)
        }.value.trimmingCharacters(in: .whitespacesAndNewlines)
        #else
        throw GemmaServiceError.llamaRuntimeUnavailable
        #endif
    }

    func isModelInstalled() async throws -> Bool {
        #if canImport(LlamaSwift)
        guard let modelPath else { return false }
        try GGUFGemmaModelStore.validateModel(atPath: modelPath, modelName: modelFileName)
        return true
        #else
        throw GemmaServiceError.llamaRuntimeUnavailable
        #endif
    }

    private var modelPath: String? {
        GGUFGemmaModelStore.modelPath(named: modelFileName)
    }

    private static func prompt(from messages: [GemmaMessage]) -> String {
        let system = messages
            .filter { $0.role == "system" }
            .map(\.content)
            .joined(separator: "\n")

        let turns = messages
            .filter { $0.role != "system" }
            .map { message in
                "\(message.role == "user" ? "User" : "Assistant"): \(message.content)"
            }
            .joined(separator: "\n\n")

        return """
        <start_of_turn>user
        You are QuizLoop.ai, an offline learning engine running on this iPhone.
        Stay grounded in the supplied note context. Return exactly the requested format when JSON is requested.
        \(system)

        \(turns)
        <end_of_turn>
        <start_of_turn>model
        """
    }

    #if canImport(LlamaSwift)
    private static func generate(prompt: String, modelPath: String, maxTokens: Int32) throws -> String {
        llama_backend_init()

        let modelParameters = llama_model_default_params()
        guard let model = llama_model_load_from_file(modelPath, modelParameters) else {
            throw GemmaServiceError.badResponse
        }
        defer { llama_model_free(model) }

        var contextParameters = llama_context_default_params()
        contextParameters.n_ctx = 4096
        contextParameters.n_batch = 512

        guard let context = llama_init_from_model(model, contextParameters) else {
            throw GemmaServiceError.badResponse
        }
        defer { llama_free(context) }

        let vocab = llama_model_get_vocab(model)
        let utf8Count = prompt.utf8.count
        var promptTokens = [llama_token](repeating: 0, count: utf8Count + 8)
        let tokenCount = llama_tokenize(
            vocab,
            prompt,
            Int32(utf8Count),
            &promptTokens,
            Int32(promptTokens.count),
            true,
            true
        )

        guard tokenCount > 0 else {
            throw GemmaServiceError.badResponse
        }

        promptTokens = Array(promptTokens.prefix(Int(tokenCount)))
        var batch = llama_batch_init(Int32(max(512, promptTokens.count + 1)), 0, 1)
        defer { llama_batch_free(batch) }

        batch.n_tokens = Int32(promptTokens.count)
        for index in promptTokens.indices {
            batch.token[index] = promptTokens[index]
            batch.pos[index] = Int32(index)
            batch.n_seq_id[index] = 1
            batch.seq_id[index]![0] = 0
            batch.logits[index] = 0
        }
        batch.logits[promptTokens.count - 1] = 1

        guard llama_decode(context, batch) == 0 else {
            throw GemmaServiceError.badResponse
        }

        var generated = ""
        var position = Int32(promptTokens.count)

        for _ in 0..<maxTokens {
            guard let logits = llama_get_logits_ith(context, batch.n_tokens - 1) else {
                throw GemmaServiceError.badResponse
            }

            let vocabularySize = Int(llama_vocab_n_tokens(vocab))
            var bestToken = llama_token(0)
            var bestLogit = logits[0]
            for tokenIndex in 1..<vocabularySize where logits[tokenIndex] > bestLogit {
                bestLogit = logits[tokenIndex]
                bestToken = llama_token(tokenIndex)
            }

            if bestToken == llama_vocab_eos(vocab) || llama_vocab_is_eog(vocab, bestToken) {
                break
            }

            generated += tokenText(bestToken, vocabulary: vocab)

            batch.n_tokens = 1
            batch.token[0] = bestToken
            batch.pos[0] = position
            batch.n_seq_id[0] = 1
            batch.seq_id[0]![0] = 0
            batch.logits[0] = 1
            position += 1

            guard llama_decode(context, batch) == 0 else {
                throw GemmaServiceError.badResponse
            }
        }

        return generated
    }

    private static func tokenText(_ token: llama_token, vocabulary: OpaquePointer?) -> String {
        var buffer = [CChar](repeating: 0, count: 64)
        let length = llama_token_to_piece(
            vocabulary,
            token,
            &buffer,
            Int32(buffer.count),
            0,
            false
        )

        if length > 0 {
            return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
        return ""
    }
    #endif
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
    case llamaRuntimeUnavailable
    case modelFileMissing(String)
    case unsupportedModelFormat(String)
    case requestTimedOut

    var errorDescription: String? {
        switch self {
        case .badResponse:
            "Gemma returned an invalid response."
        case .aiEdgeRuntimeUnavailable:
            "LiteRT-LM is not linked in this build."
        case .llamaRuntimeUnavailable:
            "The on-device GGUF runtime is not linked in this build."
        case .modelFileMissing(let model):
            "The on-device Gemma model file \(model) is not bundled or imported."
        case .unsupportedModelFormat(let model):
            "\(model) is downloaded, but this build cannot run that model format."
        case .requestTimedOut:
            "Gemma took too long to respond."
        }
    }
}

enum GGUFGemmaModelStore {
    static let defaultDownloadName = "gemma-4-e2b-Q4_K_S.gguf"
    private static let defaultDownloadMinimumBytes: Int64 = 500_000_000
    private static let defaultDownloadURL = URL(
        string: "https://huggingface.co/dahus/gemma-4-e2b-it-Q4_K_S-GGUF/resolve/main/gemma-4-e2b-Q4_K_S.gguf?download=true"
    )!

    static var modelsDirectory: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "QuizLoop", directoryHint: .isDirectory)
            .appending(path: "Models", directoryHint: .isDirectory)
    }

    static var bundledDefaultModelPath: String? {
        bundledModelPath(named: defaultDownloadName)
    }

    static var hasBundledDefaultModel: Bool {
        guard let path = bundledDefaultModelPath else { return false }
        return (try? validateModel(atPath: path, modelName: defaultDownloadName)) != nil
    }

    static func bundledModelPath(named modelFileName: String) -> String? {
        let file = URL(fileURLWithPath: modelFileName)
        let resourceName = file.deletingPathExtension().lastPathComponent
        let resourceExtension = file.pathExtension
        guard resourceName.isEmpty == false, resourceExtension.isEmpty == false else {
            return nil
        }
        return Bundle.main.path(forResource: resourceName, ofType: resourceExtension)
    }

    static func installBundledDefaultModelIfNeeded() throws -> String {
        guard let bundledPath = bundledDefaultModelPath else {
            throw GemmaServiceError.modelFileMissing(defaultDownloadName)
        }
        try validateModel(atPath: bundledPath, modelName: defaultDownloadName)

        try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        let destination = modelsDirectory.appending(path: defaultDownloadName)

        if FileManager.default.fileExists(atPath: destination.path) {
            try validateModel(atPath: destination.path, modelName: defaultDownloadName)
            return defaultDownloadName
        }

        try FileManager.default.copyItem(at: URL(fileURLWithPath: bundledPath), to: destination)
        try validateModel(atPath: destination.path, modelName: defaultDownloadName)
        return defaultDownloadName
    }

    static func importModel(from sourceURL: URL) throws -> String {
        let didStartAccessing = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        let destination = modelsDirectory.appending(path: sourceURL.lastPathComponent)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: sourceURL, to: destination)
        try validateModel(atPath: destination.path, modelName: destination.lastPathComponent)
        return destination.lastPathComponent
    }

    static func downloadDefaultModel(
        progress: @escaping @Sendable (Double) async -> Void
    ) async throws -> String {
        try await downloadModel(
            named: defaultDownloadName,
            from: defaultDownloadURL,
            minimumBytes: defaultDownloadMinimumBytes,
            progress: progress
        )
    }

    static func downloadModel(
        named modelFileName: String,
        from url: URL,
        minimumBytes: Int64,
        progress: @escaping @Sendable (Double) async -> Void
    ) async throws -> String {
        try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        let destination = modelsDirectory.appending(path: modelFileName)
        let temporaryDestination = destination.appendingPathExtension("download")

        if FileManager.default.fileExists(atPath: temporaryDestination.path) {
            try FileManager.default.removeItem(at: temporaryDestination)
        }

        let (bytes, response) = try await URLSession.shared.bytes(from: url)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ModelDownloadError.unreachable
        }

        guard 200..<300 ~= httpResponse.statusCode else {
            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                throw ModelDownloadError.blockedByLicenseOrLogin
            }
            throw ModelDownloadError.unreachable
        }

        let expectedLength = httpResponse.expectedContentLength
        var receivedBytes: Int64 = 0
        FileManager.default.createFile(atPath: temporaryDestination.path, contents: nil)

        let handle = try FileHandle(forWritingTo: temporaryDestination)
        defer { try? handle.close() }

        for try await byte in bytes {
            try handle.write(contentsOf: Data([byte]))
            receivedBytes += 1
            if expectedLength > 0, receivedBytes % 2_000_000 == 0 {
                await progress(Double(receivedBytes) / Double(expectedLength))
            }
        }

        try handle.close()

        guard receivedBytes >= minimumBytes else {
            try? FileManager.default.removeItem(at: temporaryDestination)
            throw ModelDownloadError.incompleteDownload
        }

        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: temporaryDestination, to: destination)
        try validateModel(atPath: destination.path, modelName: modelFileName)
        await progress(1)
        return modelFileName
    }

    static func modelPath(named modelFileName: String) -> String? {
        let importedPath = modelsDirectory.appending(path: modelFileName).path
        if FileManager.default.fileExists(atPath: importedPath) {
            return importedPath
        }

        let url = URL(fileURLWithPath: modelFileName)
        if url.isFileURL, FileManager.default.fileExists(atPath: url.path) {
            return url.path
        }

        return bundledModelPath(named: modelFileName)
    }

    static func isModelAvailable(named modelFileName: String) -> Bool {
        guard let path = modelPath(named: modelFileName) else { return false }
        return (try? validateModel(atPath: path, modelName: modelFileName)) != nil
    }

    static func validateModel(atPath path: String, modelName: String) throws {
        let url = URL(fileURLWithPath: path)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let header = try handle.read(upToCount: 4) ?? Data()
        let isGGUF = header.count == 4
            && header[0] == 0x47
            && header[1] == 0x47
            && header[2] == 0x55
            && header[3] == 0x46

        guard modelName.lowercased().hasSuffix(".gguf"), isGGUF else {
            throw GemmaServiceError.unsupportedModelFormat(modelName)
        }
    }
}

enum GoogleAIEdgeModelStore {
    static let defaultDownloadName = "gemma-4-E2B-it.litertlm"
    private static let defaultDownloadMinimumBytes: Int64 = 2_000_000_000
    private static let defaultDownloadURL = URL(
        string: "https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/main/gemma-4-E2B-it.litertlm?download=true"
    )!

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

    static func downloadDefaultModel(
        progress: @escaping @Sendable (Double) async -> Void = { _ in }
    ) async throws -> String {
        try await downloadModel(
            from: defaultDownloadURL,
            fileName: defaultDownloadName,
            minimumBytes: defaultDownloadMinimumBytes,
            progress: progress
        )
    }

    static func downloadModel(
        from url: URL,
        fileName: String,
        minimumBytes: Int64,
        progress: @escaping @Sendable (Double) async -> Void = { _ in }
    ) async throws -> String {
        try FileManager.default.createDirectory(
            at: modelsDirectory,
            withIntermediateDirectories: true
        )

        var request = URLRequest(url: url)
        request.timeoutInterval = 60 * 30
        request.setValue("QuizLoop.ai iOS", forHTTPHeaderField: "User-Agent")

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              200..<300 ~= httpResponse.statusCode else {
            throw ModelDownloadError.unreachable
        }

        let expectedBytes = max(httpResponse.expectedContentLength, 0)
        let temporaryURL = FileManager.default.temporaryDirectory
            .appending(path: "\(UUID().uuidString)-\(fileName)")

        FileManager.default.createFile(atPath: temporaryURL.path, contents: nil)
        let fileHandle = try FileHandle(forWritingTo: temporaryURL)
        defer {
            try? fileHandle.close()
            try? FileManager.default.removeItem(at: temporaryURL)
        }

        var downloadedBytes: Int64 = 0
        var buffer = Data()
        buffer.reserveCapacity(64 * 1024)

        for try await byte in bytes {
            buffer.append(byte)

            if buffer.count >= 64 * 1024 {
                try fileHandle.write(contentsOf: buffer)
                downloadedBytes += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)

                if expectedBytes > 0 {
                    await progress(min(Double(downloadedBytes) / Double(expectedBytes), 0.99))
                }
            }
        }

        if buffer.isEmpty == false {
            try fileHandle.write(contentsOf: buffer)
            downloadedBytes += Int64(buffer.count)
        }

        await progress(1)

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: temporaryURL.path)[.size] as? Int64) ?? 0
        guard fileSize >= minimumBytes else {
            throw ModelDownloadError.blockedByLicenseOrLogin
        }

        let destinationURL = modelsDirectory.appending(path: fileName)
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }

        try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)
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

    static func isModelAvailable(named modelFileName: String) -> Bool {
        modelPath(named: modelFileName) != nil
    }

    static func validateMediaPipeModel(atPath path: String, modelName: String) throws {
        let url = URL(fileURLWithPath: path)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let header = try handle.read(upToCount: 8) ?? Data()
        let lowercasedName = modelName.lowercased()
        let isZipBundle = header.starts(with: Data([0x50, 0x4B]))
        let isTFLiteFlatBuffer = header.count >= 8
            && header[4] == 0x54
            && header[5] == 0x46
            && header[6] == 0x4C
            && header[7] == 0x33

        if lowercasedName.hasSuffix(".task") && isZipBundle == false {
            throw GemmaServiceError.unsupportedModelFormat(modelName)
        }

        if lowercasedName.contains("gemma-4") && isTFLiteFlatBuffer {
            throw GemmaServiceError.unsupportedModelFormat(modelName)
        }
    }
}

enum ModelDownloadError: LocalizedError {
    case unreachable
    case blockedByLicenseOrLogin
    case incompleteDownload

    var errorDescription: String? {
        switch self {
        case .unreachable:
            "QuizLoop.ai could not reach the model download."
        case .blockedByLicenseOrLogin:
            "The model download was blocked. Open the Gemma page, accept the model terms, then try importing the file from Files."
        case .incompleteDownload:
            "The model download finished too early. Check the connection and try again."
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
        let mode = modeText.flatMap(ModelRuntimeConfiguration.Mode.init(rawValue:)) ?? ModelRuntimeConfiguration.default.mode
        let serverURL = defaults.string(forKey: Keys.serverURL) ?? ModelRuntimeConfiguration.default.serverURLString
        let modelName = defaults.string(forKey: Keys.modelName) ?? ModelRuntimeConfiguration.default.modelName

        let lowercasedModelName = modelName.lowercased()
        if mode == .onDeviceGGUF,
           lowercasedModelName == GGUFGemmaModelStore.defaultDownloadName.lowercased(),
           GGUFGemmaModelStore.isModelAvailable(named: modelName) == false {
            return ModelRuntimeConfiguration.default
        }

        if mode == .onDevice,
           lowercasedModelName.contains("gemma-4"),
           lowercasedModelName.hasSuffix(".task") {
            return ModelRuntimeConfiguration(
                mode: .onDevice,
                serverURLString: ModelRuntimeConfiguration.default.serverURLString,
                modelName: GoogleAIEdgeModelStore.defaultDownloadName
            )
        }

        if mode == .onDevice,
           let modelPath = GoogleAIEdgeModelStore.modelPath(named: modelName),
           (try? GoogleAIEdgeModelStore.validateMediaPipeModel(atPath: modelPath, modelName: modelName)) == nil {
            return ModelRuntimeConfiguration(
                mode: .onDeviceGGUF,
                serverURLString: ModelRuntimeConfiguration.default.serverURLString,
                modelName: ModelRuntimeConfiguration.default.modelName
            )
        }

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
