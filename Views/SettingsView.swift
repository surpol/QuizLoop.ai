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
        onSave: @escaping (ModelRuntimeConfiguration) async -> Void,
        onCheckAgain: @escaping () async -> Void
    ) {
        self.readiness = readiness
        self.configuration = configuration
        self.downloadState = downloadState
        self.onDownloadDefaultModel = onDownloadDefaultModel
        self.onSave = onSave
        self.onCheckAgain = onCheckAgain
        _mode = State(initialValue: configuration.mode)
        _serverURLString = State(initialValue: configuration.serverURLString)
        _modelName = State(initialValue: configuration.modelName)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Set Up Gemma")
                            .font(.title2.weight(.semibold))

                        Text("QuizLoop.ai needs a local Gemma model before it can read notes, create quizzes, or grade answers.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                } footer: {
                    Text("Choose the path that matches how you want to run Gemma.")
                }

                Section("Choose setup") {
                    ModelSetupPathButton(
                        title: "Use This iPhone Offline",
                        detail: "Use a packaged or imported Gemma model so quizzes run on this iPhone.",
                        systemImage: "iphone",
                        isSelected: mode == .onDeviceGGUF
                    ) {
                        mode = .onDeviceGGUF
                        modelName = GGUFGemmaModelStore.defaultDownloadName
                    }

                    ModelSetupPathButton(
                        title: "Use LiteRT-LM Gemma 4",
                        detail: "Use the official Gemma 4 E2B iOS-ready LiteRT-LM model when the Swift runtime is linked.",
                        systemImage: "cpu",
                        isSelected: mode == .onDevice
                    ) {
                        mode = .onDevice
                        modelName = GoogleAIEdgeModelStore.defaultDownloadName
                    }

                    ModelSetupPathButton(
                        title: "Connect to My Computer",
                        detail: "Use Ollama on your Mac while developing or testing over the same Wi-Fi.",
                        systemImage: "desktopcomputer",
                        isSelected: mode == .localServer
                    ) {
                        mode = .localServer
                    }
                }

                if mode == .localServer {
                    Section("Connect to Mac") {
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
                    }
                } else if mode == .onDevice {
                    Section("LiteRT-LM Gemma 4") {
                        SetupStepRow(
                            number: 1,
                            title: "Use Gemma 4 E2B",
                            detail: "The target model is gemma-4-E2B-it.litertlm, built for LiteRT-LM deployment with long text context."
                        )

                        if selectedModelIsDownloaded {
                            Label("Model file ready", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        } else {
                            Label("Model file missing", systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                        }

                        SetupStepRow(
                            number: 2,
                            title: "Link LiteRT-LM",
                            detail: "Google lists Swift support as in development, so this build stores the model and keeps the runtime boundary ready."
                        )

                        Text("Selected model: \(modelName)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)

                        Button {
                            focusedField = nil
                            isImportingModel = true
                        } label: {
                            Label("Import LiteRT-LM Model", systemImage: "folder")
                        }
                    }
                } else {
                    Section("Use This iPhone Offline") {
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

                        DisclosureGroup("Fallback setup", isExpanded: $isShowingManualImport) {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Use these only when this build does not include a packaged Gemma .gguf file.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                LabeledContent("Model file") {
                                    TextField(GGUFGemmaModelStore.defaultDownloadName, text: $modelName)
                                        .textInputAutocapitalization(.never)
                                        .autocorrectionDisabled()
                                        .multilineTextAlignment(.trailing)
                                        .focused($focusedField, equals: .model)
                                        .accessibilityLabel("On-device model file")
                                }

                                Button {
                                    focusedField = nil
                                    isImportingModel = true
                                } label: {
                                    Label("Import Model File", systemImage: "folder")
                                }

                                Button {
                                    focusedField = nil
                                    mode = .onDeviceGGUF
                                    modelName = GGUFGemmaModelStore.defaultDownloadName
                                    onDownloadDefaultModel()
                                } label: {
                                    Label(
                                        downloadState.isDownloading ? "Downloading Gemma..." : "Download from Web",
                                        systemImage: downloadState.isDownloading ? "hourglass" : "arrow.down.circle"
                                    )
                                }
                                .disabled(downloadState.isDownloading)
                            }
                            .padding(.vertical, 6)
                        }
                    }
                }

                Section("Status") {
                    Label(readiness.title, systemImage: readiness.systemImage)
                        .foregroundStyle(readiness.color)

                    Text(readiness.detail)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Button {
                        Task {
                            focusedField = nil
                            await onSave(currentConfiguration)
                        }
                    } label: {
                        Label("Save and Test", systemImage: "checkmark")
                    }
                    .disabled(readiness == .checking)

                    Button {
                        Task {
                            focusedField = nil
                            await onCheckAgain()
                        }
                    } label: {
                        Label("Check Again", systemImage: "arrow.clockwise")
                    }
                    .disabled(readiness == .checking)
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
            mode = .onDeviceGGUF
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
