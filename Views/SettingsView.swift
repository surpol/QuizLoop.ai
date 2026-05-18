import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var assistant: TutorEngine
    @State private var isShowingModelSetup = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                AppHeader(
                    title: "Settings",
                    subtitle: "Local model and storage."
                )

                ModelStatusCard(
                    readiness: assistant.modelReadiness,
                    configuration: assistant.modelConfiguration,
                    downloadState: assistant.modelDownloadState,
                    onConfigure: { isShowingModelSetup = true },
                    onRefresh: {
                        Task {
                            await assistant.refreshModelReadiness()
                        }
                    }
                )

                SettingsSection(title: "Model") {
                    SettingsRow(title: "Runtime", value: assistant.modelConfiguration.mode.title, systemImage: "server.rack")
                    SettingsRow(title: "Model", value: modelDisplayName, systemImage: "cpu")

                    if assistant.modelConfiguration.mode == .localServer {
                        SettingsRow(
                            title: "Server",
                            value: assistant.modelConfiguration.normalizedServerURLString,
                            systemImage: "network"
                        )
                    }

                    SettingsRow(title: "Status", value: assistant.modelReadiness.title, systemImage: assistant.modelReadiness.systemImage)
                }

                SettingsSection(title: "Local Notes") {
                    SettingsRow(
                        title: "Stored Locally",
                        value: "\(assistant.sources.count) notes / \(assistant.topics.count) topics",
                        systemImage: "internaldrive"
                    )
                }
            }
            .padding(16)
            .padding(.bottom, 110)
        }
        .background(QuizLoopTheme.background)
        .sheet(isPresented: $isShowingModelSetup) {
            ModelRuntimeSheet(
                readiness: assistant.modelReadiness,
                configuration: assistant.modelConfiguration,
                downloadState: assistant.modelDownloadState,
                onDownloadDefaultModel: {
                    assistant.downloadDefaultOnDeviceModel()
                },
                onDownloadLiteRTModel: {
                    assistant.downloadDefaultLiteRTModel()
                },
                onSave: { configuration in
                    await assistant.updateModelConfiguration(configuration)
                },
                onCheckAgain: {
                    await assistant.refreshModelReadiness()
                }
            )
        }
    }

    private var modelDisplayName: String {
        switch assistant.modelConfiguration.mode {
        case .localServer:
            assistant.modelConfiguration.modelName
        case .onDeviceGGUF:
            assistant.modelConfiguration.modelName
        case .onDevice:
            assistant.modelConfiguration.modelName
        }
    }
}

private struct ModelStatusCard: View {
    let readiness: ModelReadiness
    let configuration: ModelRuntimeConfiguration
    let downloadState: ModelDownloadState
    let onConfigure: () -> Void
    let onRefresh: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: readiness.systemImage)
                    .font(.title2)
                    .foregroundStyle(readiness.color)
                    .frame(width: 34, height: 34)

                VStack(alignment: .leading, spacing: 4) {
                    Text(configuration.mode == .localServer ? configuration.modelName : configuration.mode.title)
                        .font(.headline)
                        .lineLimit(1)

                    Text(readiness.detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineSpacing(2)

                    if let progress = downloadState.progress {
                        VStack(alignment: .leading, spacing: 6) {
                            ProgressView(value: progress)
                                .progressViewStyle(.linear)

                            Text("Downloading Gemma \(Int((progress * 100).rounded()))%")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.top, 4)
                    }
                }

                Spacer(minLength: 0)
            }

            HStack(spacing: 10) {
                Button(action: onConfigure) {
                    Label("Configure", systemImage: "slider.horizontal.3")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.teal)

                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Check model again")
            }
        }
        .padding(14)
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)

            VStack(spacing: 0) {
                content
            }
            .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

private struct SettingsRow: View {
    let title: String
    let value: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.teal)
                .frame(width: 26)

            Text(title)
                .font(.subheadline)

            Spacer(minLength: 12)

            Text(value)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
    }
}

private struct ModelSetupPathButton: View {
    let title: String
    let detail: String
    let systemImage: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: systemImage)
                    .font(.headline)
                    .foregroundStyle(isSelected ? .white : .teal)
                    .frame(width: 34, height: 34)
                    .background(
                        isSelected ? Color.teal : Color.teal.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 8)
                    )

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.primary)

                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineSpacing(2)
                }

                Spacer(minLength: 8)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? .teal : .secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 4)
    }
}

private struct SetupStepRow: View {
    let number: Int
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Color.teal, in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))

                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineSpacing(2)
            }
        }
        .padding(.vertical, 3)
    }
}

private struct ModelRuntimeSheet: View {
    @Environment(\.dismiss) private var dismiss
    let readiness: ModelReadiness
    let configuration: ModelRuntimeConfiguration
    let downloadState: ModelDownloadState
    let onDownloadDefaultModel: () -> Void
    let onDownloadLiteRTModel: () -> Void
    let onSave: (ModelRuntimeConfiguration) async -> Void
    let onCheckAgain: () async -> Void

    @State private var mode: ModelRuntimeConfiguration.Mode
    @State private var serverURLString: String
    @State private var modelName: String
    @State private var isImportingModel = false
    @State private var modelImportMessage: String?
    @State private var isShowingManualImport = false
    @FocusState private var focusedField: Field?

    private enum Field {
        case server
        case model
    }

    init(
        readiness: ModelReadiness,
        configuration: ModelRuntimeConfiguration,
        downloadState: ModelDownloadState,
        onDownloadDefaultModel: @escaping () -> Void,
        onDownloadLiteRTModel: @escaping () -> Void,
        onSave: @escaping (ModelRuntimeConfiguration) async -> Void,
        onCheckAgain: @escaping () async -> Void
    ) {
        self.readiness = readiness
        self.configuration = configuration
        self.downloadState = downloadState
        self.onDownloadDefaultModel = onDownloadDefaultModel
        self.onDownloadLiteRTModel = onDownloadLiteRTModel
        self.onSave = onSave
        self.onCheckAgain = onCheckAgain
        let initialMode: ModelRuntimeConfiguration.Mode = configuration.mode == .localServer ? .localServer : .onDevice
        _mode = State(initialValue: initialMode)
        _serverURLString = State(initialValue: configuration.serverURLString)
        _modelName = State(initialValue: initialMode == .onDevice ? GoogleAIEdgeModelStore.defaultDownloadName : configuration.modelName)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Download Gemma")
                            .font(.title2.weight(.semibold))

                        Text("QuizLoop.ai runs best with Gemma on this iPhone. Download the recommended model once, then quizzes can run locally.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }

                Section {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: "sparkles")
                                .font(.headline)
                                .foregroundStyle(.white)
                                .frame(width: 36, height: 36)
                                .background(Color.teal, in: RoundedRectangle(cornerRadius: 8))

                            VStack(alignment: .leading, spacing: 4) {
                                Text("Best for this iPhone")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.teal)
                                    .textCase(.uppercase)

                                Text("Gemma-4-E2B-it")
                                    .font(.title3.weight(.semibold))

                                Text("2.59 GB · LiteRT-LM · up to 32K context")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer(minLength: 0)
                        }

                        Text("Built for Google AI Edge on iOS. QuizLoop uses it to read notes, create quizzes, and grade answers without sending learning data to a cloud AI service.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineSpacing(2)

                        if litertModelIsDownloaded {
                            Label(
                                litertRuntimeIsLinked ? "Downloaded" : "Downloaded, runtime missing",
                                systemImage: litertRuntimeIsLinked ? "checkmark.circle.fill" : "exclamationmark.triangle"
                            )
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(litertRuntimeIsLinked ? .green : .orange)
                        } else if downloadState.isDownloading {
                            VStack(alignment: .leading, spacing: 8) {
                                Label("Downloading Gemma", systemImage: "arrow.down.circle")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.secondary)

                                if let modelDownloadProgress = downloadState.progress {
                                    ProgressView(value: modelDownloadProgress)
                                        .progressViewStyle(.linear)

                                    Text("\(Int((modelDownloadProgress * 100).rounded()))%")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        } else {
                            Label("Not downloaded", systemImage: "arrow.down.circle")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }

                        Button {
                            focusedField = nil
                            mode = .onDevice
                            modelName = GoogleAIEdgeModelStore.defaultDownloadName
                            if litertModelIsDownloaded {
                                Task {
                                    await onSave(currentConfiguration)
                                    await onCheckAgain()
                                }
                            } else {
                                onDownloadLiteRTModel()
                            }
                        } label: {
                            Label(primaryModelButtonTitle, systemImage: primaryModelButtonIcon)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.teal)
                        .disabled(downloadState.isDownloading || (litertModelIsDownloaded && litertRuntimeIsLinked == false))

                        Button {
                            Task {
                                focusedField = nil
                                await onCheckAgain()
                            }
                        } label: {
                            Label("Check Again", systemImage: "arrow.clockwise")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .disabled(readiness == .checking || downloadState.isDownloading)
                    }
                    .padding(.vertical, 4)
                }

                Section("Status") {
                    Label(readiness.title, systemImage: readiness.systemImage)
                        .foregroundStyle(readiness.color)

                    Text(readiness.detail)
                        .foregroundStyle(.secondary)
                }

                Section("Advanced") {
                    DisclosureGroup("Manual and developer setup", isExpanded: $isShowingManualImport) {
                        VStack(alignment: .leading, spacing: 14) {
                            Button {
                                focusedField = nil
                                mode = .onDevice
                                modelName = GoogleAIEdgeModelStore.defaultDownloadName
                                isImportingModel = true
                            } label: {
                                Label("Import LiteRT-LM Model", systemImage: "folder")
                            }

                            Button {
                                mode = .localServer
                            } label: {
                                Label("Use Ollama on Mac", systemImage: "desktopcomputer")
                            }

                            Button {
                                mode = .onDeviceGGUF
                                modelName = GGUFGemmaModelStore.defaultDownloadName
                            } label: {
                                Label("Use GGUF Runtime", systemImage: "shippingbox")
                            }
                        }
                        .padding(.vertical, 6)
                    }

                    if mode == .localServer {
                        SetupStepRow(
                            number: 1,
                            title: "Run Gemma with Ollama",
                            detail: "Start Ollama on your Mac and keep both devices on the same Wi-Fi."
                        )

                        LabeledContent("Endpoint") {
                            TextField("http://192.168.1.10:11434", text: $serverURLString)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .keyboardType(.URL)
                                .multilineTextAlignment(.trailing)
                                .focused($focusedField, equals: .server)
                                .accessibilityLabel("Gemma endpoint")
                        }

                        SetupStepRow(
                            number: 2,
                            title: "Choose the model",
                            detail: "Use the same model name installed in Ollama."
                        )

                        LabeledContent("Model") {
                            TextField("gemma4:e2b", text: $modelName)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .multilineTextAlignment(.trailing)
                                .focused($focusedField, equals: .model)
                                .accessibilityLabel("Model name")
                        }

                        ShareLink(item: macSetupText) {
                            Label("Send Gemma Setup", systemImage: "square.and.arrow.up")
                        }
                    } else if mode == .onDeviceGGUF {
                        SetupStepRow(
                            number: 1,
                            title: "Use packaged Gemma",
                            detail: "For judge/demo builds, ship the Gemma GGUF file with the app so setup is instant and reliable."
                        )

                        if selectedModelIsDownloaded, downloadState.isDownloading == false {
                            Label("Gemma ready", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        } else if GGUFGemmaModelStore.hasBundledDefaultModel {
                            Button {
                                focusedField = nil
                                mode = .onDeviceGGUF
                                modelName = GGUFGemmaModelStore.defaultDownloadName
                                onDownloadDefaultModel()
                            } label: {
                                Label("Use Packaged Gemma", systemImage: "shippingbox")
                            }
                            .disabled(downloadState.isDownloading)
                        } else {
                            Label("No packaged model in this build", systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                        }

                        if let modelDownloadProgress = downloadState.progress {
                            VStack(alignment: .leading, spacing: 6) {
                                ProgressView(value: modelDownloadProgress)
                                    .progressViewStyle(.linear)

                                Text("\(Int((modelDownloadProgress * 100).rounded()))% downloaded")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 2)
                        }

                        SetupStepRow(
                            number: 2,
                            title: "Save and test",
                            detail: "QuizLoop.ai validates the model before it marks Gemma ready."
                        )

                        Text("Selected model: \(modelName)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)

                        if let downloadMessage = downloadState.message {
                            Text(downloadMessage)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }

                        if let modelImportMessage {
                            Text(modelImportMessage)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Model")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }

                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        focusedField = nil
                    }
                }
            }
        }
        .onChange(of: downloadState.installedModelName) { _, installedModelName in
            guard let installedModelName else { return }
            mode = installedModelName.lowercased().hasSuffix(".litertlm") ? .onDevice : .onDeviceGGUF
            modelName = installedModelName
        }
        .fileImporter(
            isPresented: $isImportingModel,
            allowedContentTypes: [.data],
            allowsMultipleSelection: false
        ) { result in
            importModel(from: result)
        }
    }

    private var currentConfiguration: ModelRuntimeConfiguration {
        ModelRuntimeConfiguration(
            mode: mode,
            serverURLString: serverURLString,
            modelName: modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? configuration.modelName : modelName
        )
    }

    private var selectedModelIsDownloaded: Bool {
        switch mode {
        case .localServer:
            false
        case .onDeviceGGUF:
            GGUFGemmaModelStore.isModelAvailable(named: modelName)
        case .onDevice:
            GoogleAIEdgeModelStore.isModelAvailable(named: modelName)
        }
    }

    private var litertModelIsDownloaded: Bool {
        GoogleAIEdgeModelStore.isModelAvailable(named: GoogleAIEdgeModelStore.defaultDownloadName)
    }

    private var litertRuntimeIsLinked: Bool {
        #if canImport(LiteRTLM)
        true
        #elseif canImport(LiteRTLMSwift)
        true
        #else
        false
        #endif
    }

    private var primaryModelButtonTitle: String {
        if downloadState.isDownloading {
            "Downloading"
        } else if litertModelIsDownloaded && litertRuntimeIsLinked == false {
            "Runtime Missing"
        } else if litertModelIsDownloaded {
            "Use Model"
        } else {
            "Download"
        }
    }

    private var primaryModelButtonIcon: String {
        if downloadState.isDownloading {
            "hourglass"
        } else if litertModelIsDownloaded && litertRuntimeIsLinked == false {
            "exclamationmark.triangle"
        } else if litertModelIsDownloaded {
            "checkmark.circle"
        } else {
            "arrow.down.circle"
        }
    }

    private var runtimeHelpText: String {
        switch mode {
        case .localServer:
            "Use Gemma through a local endpoint while the bundled on-device runtime is being prepared. QuizLoop.ai does not generate quizzes without a model."
        case .onDeviceGGUF:
            "Use a packaged or imported Gemma 4 GGUF model through llama.cpp. This is the production offline path."
        case .onDevice:
            "Use the official Gemma 4 E2B LiteRT-LM model file. The Swift runtime is kept behind the same GemmaService boundary."
        }
    }

    private var macSetupText: String {
        let selectedModel = modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? configuration.modelName : modelName

        return """
        QuizLoop.ai Gemma setup

        1. Install the model:
        ollama pull \(selectedModel)

        2. Start Ollama for this device:
        OLLAMA_HOST=0.0.0.0:11434 ollama serve

        3. Find the server's Wi-Fi address:
        ipconfig getifaddr en0

        4. In QuizLoop.ai > Settings > Model, paste:
        http://YOUR_MAC_WIFI_ADDRESS:11434

        Your iPhone and Gemma server must be on the same Wi-Fi.
        """
    }

    private func importModel(from result: Result<[URL], Error>) {
        do {
            guard let sourceURL = try result.get().first else { return }
            let importedFileName: String
            switch mode {
            case .onDeviceGGUF:
                importedFileName = try GGUFGemmaModelStore.importModel(from: sourceURL)
            case .onDevice:
                importedFileName = try GoogleAIEdgeModelStore.importModel(from: sourceURL)
            case .localServer:
                importedFileName = try GGUFGemmaModelStore.importModel(from: sourceURL)
                mode = .onDeviceGGUF
            }
            modelName = importedFileName
            modelImportMessage = "Imported \(importedFileName). Tap Save and Test."
        } catch {
            modelImportMessage = error.localizedDescription
        }
    }
}
