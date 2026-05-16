import SwiftUI

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
        case .onDevice:
            assistant.modelConfiguration.modelName
        }
    }
}

private struct ModelStatusCard: View {
    let readiness: ModelReadiness
    let configuration: ModelRuntimeConfiguration
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
                    Text(configuration.mode == .onDevice ? "Google AI Edge" : configuration.modelName)
                        .font(.headline)
                        .lineLimit(1)

                    Text(readiness.detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineSpacing(2)
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

private struct ModelRuntimeSheet: View {
    @Environment(\.dismiss) private var dismiss
    let readiness: ModelReadiness
    let configuration: ModelRuntimeConfiguration
    let onSave: (ModelRuntimeConfiguration) async -> Void
    let onCheckAgain: () async -> Void

    @State private var mode: ModelRuntimeConfiguration.Mode
    @State private var serverURLString: String
    @State private var modelName: String
    @FocusState private var focusedField: Field?

    private enum Field {
        case server
        case model
    }

    init(
        readiness: ModelReadiness,
        configuration: ModelRuntimeConfiguration,
        onSave: @escaping (ModelRuntimeConfiguration) async -> Void,
        onCheckAgain: @escaping () async -> Void
    ) {
        self.readiness = readiness
        self.configuration = configuration
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
                    Picker("Runtime", selection: $mode) {
                        Text(ModelRuntimeConfiguration.Mode.localServer.title).tag(ModelRuntimeConfiguration.Mode.localServer)
                        Text(ModelRuntimeConfiguration.Mode.onDevice.title).tag(ModelRuntimeConfiguration.Mode.onDevice)
                    }
                    .pickerStyle(.segmented)
                } footer: {
                    Text(runtimeHelpText)
                }

                if mode == .localServer {
                    Section("Gemma Endpoint") {
                        LabeledContent("Endpoint") {
                            TextField("http://192.168.1.10:11434", text: $serverURLString)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .keyboardType(.URL)
                                .multilineTextAlignment(.trailing)
                                .focused($focusedField, equals: .server)
                                .accessibilityLabel("Gemma endpoint")
                        }

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
                } else {
                    Section("On-device Gemma") {
                        LabeledContent("Model file") {
                            TextField("gemma-2-2b-it-8bit.bin", text: $modelName)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .multilineTextAlignment(.trailing)
                                .focused($focusedField, equals: .model)
                                .accessibilityLabel("On-device model file")
                        }

                        Text("Bundle a Google AI Edge compatible Gemma .bin or .task model with the app target. QuizLoop.ai will use SQLite memory locally and run inference through MediaPipe/LiteRT on device.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
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
    }

    private var currentConfiguration: ModelRuntimeConfiguration {
        ModelRuntimeConfiguration(
            mode: mode,
            serverURLString: serverURLString,
            modelName: modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? configuration.modelName : modelName
        )
    }

    private var runtimeHelpText: String {
        switch mode {
        case .localServer:
            "Use Gemma through a local endpoint while the bundled on-device runtime is being prepared. QuizLoop.ai does not generate quizzes without a model."
        case .onDevice:
            "Use Google AI Edge with a bundled Gemma model file. This is the target production offline mode."
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
}
