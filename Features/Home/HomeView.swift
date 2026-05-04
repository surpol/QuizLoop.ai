import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var assistant: TutorEngine
    @EnvironmentObject private var speechService: SpeechService
    @State private var typedPrompt = ""
    @State private var isAddingContext = false
    @State private var isShowingVoiceControls = false
    @State private var isShowingModelSetup = false
    @State private var isConfirmingReset = false

    var body: some View {
        Group {
            if assistant.modelReadiness.isReady {
                assistantSurface
            } else {
                SetupView(
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
        .background(WavesTheme.background)
        .navigationTitle("Waves")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 14) {
                    Button {
                        isShowingModelSetup = true
                    } label: {
                        Image(systemName: "server.rack")
                    }
                    .accessibilityLabel("Model setup")

                    Button {
                        isShowingVoiceControls = true
                    } label: {
                        Image(systemName: "speaker.wave.2")
                    }
                    .accessibilityLabel("Voice controls")

                    Button(role: .destructive) {
                        isConfirmingReset = true
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                    }
                    .accessibilityLabel("Reset conversation")
                }
            }
        }
        .sheet(isPresented: $isShowingVoiceControls) {
            VoiceControlsSheet()
                .environmentObject(speechService)
        }
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
        .alert(
            "Reset this conversation?",
            isPresented: $isConfirmingReset
        ) {
            Button("Reset Conversation", role: .destructive) {
                assistant.reset()
            }

            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This clears the current chat history. Saved sources and flashcards stay in your library.")
        }
    }

    private var assistantSurface: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 12) {
                        SessionStatusBar(
                            isResponding: assistant.isResponding,
                            savedCount: assistant.sources.count,
                            isOnDevice: assistant.modelConfiguration.mode == .onDevice
                        )

                        ConversationView(turns: assistant.turns)

                        Color.clear
                            .frame(height: 72)
                            .id("conversation-bottom")
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 8)
                }
                .scrollDismissesKeyboard(.interactively)

                AssistantControls(
                    text: $typedPrompt,
                    transcript: speechService.transcript,
                    state: speechService.state,
                    isRecording: speechService.isRecording,
                    isSpeaking: speechService.isSpeaking,
                    autoSpeak: speechService.autoSpeak,
                    isResponding: assistant.isResponding,
                    onAddContext: { isAddingContext = true },
                    onVoiceControls: { isShowingVoiceControls = true },
                    onStopSpeaking: speechService.stopSpeaking,
                    onMicTap: handleMicTap,
                    onSubmit: submitTypedPrompt
                )
            }
            .sheet(isPresented: $isAddingContext) {
                AddMaterialSheet()
                    .environmentObject(assistant)
                    .environmentObject(speechService)
            }
            .onChange(of: assistant.turns.count) {
                withAnimation(.snappy) {
                    proxy.scrollTo("conversation-bottom", anchor: .bottom)
                }
            }
            .onAppear {
                proxy.scrollTo("conversation-bottom", anchor: .bottom)
            }
            .task {
                try? await Task.sleep(for: .milliseconds(250))
                proxy.scrollTo("conversation-bottom", anchor: .bottom)
            }
        }
    }

    private func handleMicTap() {
        if speechService.isRecording {
            let prompt = speechService.transcript
            speechService.stopRecording()
            submit(prompt)
        } else {
            speechService.toggleRecording()
        }
    }

    private func submitTypedPrompt() {
        let prompt = typedPrompt
        typedPrompt = ""
        dismissKeyboard()
        submit(prompt)
    }

    private func submit(_ prompt: String) {
        Task {
            if let response = await assistant.submit(prompt) {
                speechService.speak(response)
            }
        }
    }
}

private struct SetupView: View {
    let readiness: ModelReadiness
    let configuration: ModelRuntimeConfiguration
    let onSave: (ModelRuntimeConfiguration) async -> Void
    let onCheckAgain: () async -> Void
    @State private var mode: ModelRuntimeConfiguration.Mode
    @State private var serverURLString: String
    @State private var modelName: String
    @FocusState private var focusedField: RuntimeField?

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
        ScrollView {
            VStack(spacing: 22) {
                VStack(spacing: 14) {
                    Image(systemName: iconName)
                        .font(.system(size: 48, weight: .semibold))
                        .foregroundStyle(.teal)
                        .symbolEffect(.pulse, options: .repeating, value: readiness == .checking)

                    VStack(spacing: 8) {
                        Text(title)
                            .font(.largeTitle.weight(.semibold))
                            .multilineTextAlignment(.center)

                        Text(subtitle)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .lineSpacing(3)
                    }
                }
                .padding(.top, 28)

                VStack(alignment: .leading, spacing: 12) {
                    Picker("Runtime", selection: $mode) {
                        Text("Local Server").tag(ModelRuntimeConfiguration.Mode.localServer)
                        Text("On Device").tag(ModelRuntimeConfiguration.Mode.onDevice)
                    }
                    .pickerStyle(.segmented)

                    if mode == .localServer {
                        RuntimeTextField(title: "Mac Address", text: $serverURLString, placeholder: "http://192.168.1.10:11434")
                            .focused($focusedField, equals: .serverURL)
                        RuntimeTextField(title: "Model", text: $modelName, placeholder: "gemma4:e2b")
                            .focused($focusedField, equals: .modelName)

                        ShareLink(item: macSetupText) {
                            Label("Send Mac Setup", systemImage: "square.and.arrow.up")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                        }
                        .buttonStyle(.bordered)
                    } else {
                        OnDeviceStatus(readiness: readiness)
                    }
                }
                .padding(16)
                .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 8))

                if mode == .localServer {
                    VStack(alignment: .leading, spacing: 18) {
                        SetupStep(
                            index: 1,
                            title: "Send this to your Mac",
                            detail: "Tap Send Mac Setup, then open it on your Mac. It includes the commands to run."
                        )
                        SetupStep(
                            index: 2,
                            title: "Paste your Mac address",
                            detail: "On your Mac, the command prints a URL. Paste that URL into Mac Address above."
                        )
                        SetupStep(
                            index: 3,
                            title: "Save and test",
                            detail: "Your phone works while it is on the same Wi-Fi as that Mac. Away from the Mac needs on-device mode later."
                        )
                    }
                }

                VStack(spacing: 10) {
                    Button {
                        Task {
                            focusedField = nil
                            dismissKeyboard()
                            await onSave(currentConfiguration)
                        }
                    } label: {
                        Label("Save and Test", systemImage: "checkmark")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color.teal, in: Capsule())
                            .foregroundStyle(.white)
                    }
                    .disabled(readiness == .checking)

                    Button {
                        Task {
                            await onCheckAgain()
                        }
                    } label: {
                        Label("Check Again", systemImage: "arrow.clockwise")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                    }
                    .buttonStyle(.bordered)
                    .disabled(readiness == .checking)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 36)
        }
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") {
                    focusedField = nil
                    dismissKeyboard()
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

    private var macSetupText: String {
        let selectedModel = modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? configuration.modelName : modelName

        return """
        Waves Mac setup

        1. Open Terminal on this Mac.

        2. Install the model:
        ollama pull \(selectedModel)

        3. Start Ollama for your phone:
        OLLAMA_HOST=0.0.0.0:11434 ollama serve

        4. In another Terminal window, find this Mac's Wi-Fi address:
        ipconfig getifaddr en0

        5. On your iPhone, open Waves > Model and paste:
        http://YOUR_MAC_WIFI_ADDRESS:11434

        Example:
        http://192.168.1.10:11434

        Your iPhone and Mac must be on the same Wi-Fi.
        """
    }

    private var iconName: String {
        switch readiness {
        case .checking:
            "waveform"
        case .ready:
            "checkmark.circle.fill"
        case .serverUnavailable:
            "desktopcomputer.trianglebadge.exclamationmark"
        case .modelMissing:
            "arrow.down.circle"
        case .deviceNotEligible:
            "exclamationmark.triangle"
        case .appleIntelligenceNotEnabled:
            "gear.badge"
        case .appleModelNotReady:
            "arrow.down.circle"
        }
    }

    private var title: String {
        switch readiness {
        case .checking:
            mode == .onDevice ? "Checking Apple Intelligence" : "Checking Gemma"
        case .ready:
            mode == .onDevice ? "Ready" : "Gemma is ready"
        case .serverUnavailable:
            "Set up local AI"
        case .modelMissing:
            "Install Gemma"
        case .deviceNotEligible:
            "Not supported"
        case .appleIntelligenceNotEnabled:
            "Turn on Apple Intelligence"
        case .appleModelNotReady:
            "Almost ready"
        }
    }

    private var subtitle: String {
        switch readiness {
        case .checking:
            "Waves is looking for a local model before starting your private assistant."
        case .ready:
            "Your assistant can answer offline through the local model runtime."
        case .serverUnavailable:
            "Your Mac runs Gemma and your phone connects to it on the same Wi-Fi."
        case .modelMissing:
            "The server is reachable, but the selected model is not installed yet."
        case .deviceNotEligible:
            "This device does not support Apple Intelligence. Switch to Local Server to use your Mac instead."
        case .appleIntelligenceNotEnabled:
            "Turn on Apple Intelligence in Settings to use the on-device model."
        case .appleModelNotReady:
            "The on-device model is still downloading. This only happens once."
        }
    }
}

private enum RuntimeField {
    case serverURL
    case modelName
}

struct ModelRuntimeSheet: View {
    @Environment(\.dismiss) private var dismiss
    let readiness: ModelReadiness
    let configuration: ModelRuntimeConfiguration
    let onSave: (ModelRuntimeConfiguration) async -> Void
    let onCheckAgain: () async -> Void

    var body: some View {
        NavigationStack {
            SetupView(
                readiness: readiness,
                configuration: configuration,
                onSave: { configuration in
                    await onSave(configuration)
                },
                onCheckAgain: {
                    await onCheckAgain()
                }
            )
            .navigationTitle("Model")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

private struct RuntimeTextField: View {
    let title: String
    @Binding var text: String
    let placeholder: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            TextField(placeholder, text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(title == "Mac Address" ? .URL : .default)
                .padding(.horizontal, 12)
                .padding(.vertical, 11)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
                .textSelection(.enabled)
        }
    }
}

private struct OnDeviceStatus: View {
    let readiness: ModelReadiness

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: statusIcon)
                    .font(.title3)
                    .foregroundStyle(statusColor)
                    .frame(width: 30)

                VStack(alignment: .leading, spacing: 4) {
                    Text(statusTitle)
                        .font(.headline)

                    Text(statusDetail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineSpacing(2)
                }
            }

            if readiness == .appleIntelligenceNotEnabled {
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Label("Open Settings", systemImage: "gear")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.bordered)
            }

            if readiness == .appleModelNotReady {
                ProgressView("Preparing model…")
                    .font(.subheadline)
            }
        }
    }

    private var statusIcon: String {
        switch readiness {
        case .ready:
            "checkmark.circle.fill"
        case .deviceNotEligible:
            "exclamationmark.triangle"
        case .appleIntelligenceNotEnabled:
            "gear.badge"
        case .appleModelNotReady:
            "arrow.down.circle"
        default:
            "apple.intelligence"
        }
    }

    private var statusColor: Color {
        switch readiness {
        case .ready: .green
        case .deviceNotEligible: .red
        case .appleIntelligenceNotEnabled: .orange
        default: .teal
        }
    }

    private var statusTitle: String {
        switch readiness {
        case .ready:
            "Apple Intelligence is ready"
        case .deviceNotEligible:
            "Not supported on this device"
        case .appleIntelligenceNotEnabled:
            "Apple Intelligence is turned off"
        case .appleModelNotReady:
            "Model is preparing"
        default:
            "On-device model"
        }
    }

    private var statusDetail: String {
        switch readiness {
        case .ready:
            "Waves runs entirely on your device with no network needed."
        case .deviceNotEligible:
            "This device does not support Apple Intelligence."
        case .appleIntelligenceNotEnabled:
            "Go to Settings and turn on Apple Intelligence."
        case .appleModelNotReady:
            "The on-device model is downloading. This only happens once."
        default:
            "Checking on-device model availability."
        }
    }
}

private struct SetupStep: View {
    let index: Int
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Text("\(index)")
                .font(.subheadline.weight(.semibold))
                .frame(width: 28, height: 28)
                .background(Color(.secondarySystemBackground), in: Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)

                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }
}

private struct SessionStatusBar: View {
    let isResponding: Bool
    let savedCount: Int
    var isOnDevice: Bool = false

    var body: some View {
        HStack(spacing: 10) {
            Label(isResponding ? "Thinking" : (isOnDevice ? "On-Device" : "Local Gemma"), systemImage: isResponding ? "hourglass" : "checkmark.circle.fill")
                .foregroundStyle(isResponding ? Color.secondary : Color.teal)

            Spacer(minLength: 0)

            Label("\(savedCount) sources", systemImage: "tray.full")
                .foregroundStyle(.secondary)
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct ConversationView: View {
    @EnvironmentObject private var assistant: TutorEngine
    @EnvironmentObject private var speechService: SpeechService

    let turns: [TutorTurn]

    var body: some View {
        let latestActionableTurnID = turns.last(where: \.canCreateStudyActions)?.id

        LazyVStack(spacing: 12) {
            ForEach(turns) { turn in
                VStack(alignment: turn.speaker == .learner ? .trailing : .leading, spacing: 8) {
                    HStack {
                        if turn.speaker == .learner {
                            Spacer(minLength: 48)
                        }

                        Text(turn.text)
                            .font(.body)
                            .foregroundStyle(turn.speaker == .learner ? .white : .primary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .background(
                                turn.speaker == .learner ? Color.teal : Color(.secondarySystemBackground),
                                in: RoundedRectangle(cornerRadius: 8)
                            )

                        if turn.speaker == .waves {
                            Spacer(minLength: 48)
                        }
                    }

                    if turn.sourceTitles.isEmpty == false {
                        SourceTrustChips(sourceTitles: turn.sourceTitles)
                    }

                    if turn.id == latestActionableTurnID {
                        ResponseActions(
                            onFlashcards: {
                                Task {
                                    if let response = await assistant.makeFlashcards(from: turn.text) {
                                        speechService.speak(response)
                                    }
                                }
                            },
                            onQuiz: {
                                Task {
                                    if let response = await assistant.startQuiz(from: turn.text) {
                                        speechService.speak(response)
                                    }
                                }
                            },
                            onSave: {
                                assistant.saveAnswerAsSource(turn.text)
                            }
                        )
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct SourceTrustChips: View {
    let sourceTitles: [String]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(sourceTitles.prefix(3)), id: \.self) { title in
                    Label(title, systemImage: "checkmark.seal")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color(.systemBackground), in: Capsule())
                        .accessibilityLabel("Using source \(title)")
                }
            }
            .padding(.leading, 4)
        }
    }
}

private extension TutorTurn {
    var canCreateStudyActions: Bool {
        guard speaker == .waves else { return false }

        let blockedPrefixes = [
            "Hi, I am Waves",
            "Fresh session ready",
            "I made ",
            "I could not reach",
            "Something went wrong with"
        ]

        return blockedPrefixes.contains { text.hasPrefix($0) } == false
    }
}

private struct ResponseActions: View {
    let onFlashcards: () -> Void
    let onQuiz: () -> Void
    let onSave: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            StudyActionButton(title: "Flashcards", systemImage: "rectangle.stack", action: onFlashcards)
            StudyActionButton(title: "Quiz Me", systemImage: "checklist", action: onQuiz)
            StudyActionButton(title: "Save", systemImage: "bookmark", action: onSave)
        }
        .padding(.leading, 4)
    }
}

private struct StudyActionButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color(.systemBackground), in: Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
    }
}

private struct AssistantControls: View {
    @Binding var text: String
    let transcript: String
    let state: SpeechService.RecordingState
    let isRecording: Bool
    let isSpeaking: Bool
    let autoSpeak: Bool
    let isResponding: Bool
    let onAddContext: () -> Void
    let onVoiceControls: () -> Void
    let onStopSpeaking: () -> Void
    let onMicTap: () -> Void
    let onSubmit: () -> Void
    @FocusState private var isMessageFocused: Bool

    var body: some View {
        VStack(spacing: showsStatusRow ? 8 : 0) {
            HStack(spacing: 10) {
                Button(action: onMicTap) {
                    Image(systemName: isRecording ? "stop.fill" : "mic.fill")
                        .frame(width: 46, height: 46)
                        .background(isRecording ? .red : .teal, in: Circle())
                        .foregroundStyle(.white)
                }
                .disabled(isResponding)
                .accessibilityLabel(isRecording ? "Stop recording" : "Start recording")

                Button(action: onAddContext) {
                    Image(systemName: "plus")
                        .frame(width: 36, height: 36)
                        .background(Color(.secondarySystemBackground), in: Circle())
                }
                .accessibilityLabel("Add material")

                Button(action: onVoiceControls) {
                    Image(systemName: autoSpeak ? "speaker.wave.2.fill" : "speaker.slash.fill")
                        .frame(width: 36, height: 36)
                        .background(Color(.secondarySystemBackground), in: Circle())
                }
                .accessibilityLabel("Composer voice controls")

                TextField(placeholder, text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .focused($isMessageFocused)
                    .lineLimit(1...3)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 11)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
                    .submitLabel(.send)
                    .onSubmit {
                        isMessageFocused = false
                        dismissKeyboard()
                        onSubmit()
                    }
                    .accessibilityLabel("Message Waves")

                if isMessageFocused {
                    Button {
                        isMessageFocused = false
                        dismissKeyboard()
                    } label: {
                        Image(systemName: "keyboard.chevron.compact.down")
                            .frame(width: 36, height: 36)
                            .background(Color(.secondarySystemBackground), in: Circle())
                    }
                    .accessibilityLabel("Close keyboard")
                }

                Button {
                    isMessageFocused = false
                    dismissKeyboard()
                    onSubmit()
                } label: {
                    Image(systemName: isResponding ? "hourglass" : "arrow.up")
                        .frame(width: 42, height: 42)
                        .background(canSend ? Color.teal : Color.gray.opacity(0.3), in: Circle())
                        .foregroundStyle(.white)
                }
                .disabled(canSend == false)
                .accessibilityLabel("Send message")
            }

            if showsStatusRow {
                HStack(spacing: 10) {
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if isSpeaking {
                        Button("Stop Voice", action: onStopSpeaking)
                            .font(.caption.weight(.semibold))
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .accessibilityLabel("Stop speaking")
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.regularMaterial)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") {
                    isMessageFocused = false
                    dismissKeyboard()
                }
            }
        }
    }

    private var canSend: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false && isResponding == false
    }

    private var placeholder: String {
        if isRecording {
            return transcript.isEmpty ? "Listening..." : transcript
        }

        return "Message Waves"
    }

    private var showsStatusRow: Bool {
        if isSpeaking {
            return true
        }

        if case .idle = state {
            return false
        }

        return true
    }

    private var statusText: String {
        switch state {
        case .idle:
            "Private by design. Voice, chat, and history stay local."
        case .requestingPermission:
            "Checking voice permissions..."
        case .recording:
            transcript.isEmpty ? "Listening..." : "Listening: \(transcript)"
        case .unavailable(let message):
            message
        }
    }
}

private func dismissKeyboard() {
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
}

private struct VoiceControlsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var speechService: SpeechService

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Read answers aloud", isOn: $speechService.autoSpeak)

                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Voice speed")
                            Spacer()
                            Text(rateLabel)
                                .foregroundStyle(.secondary)
                        }

                        Slider(value: $speechService.speechRate, in: 0.34...0.52, step: 0.01) {
                            Text("Voice speed")
                        } minimumValueLabel: {
                            Image(systemName: "tortoise")
                        } maximumValueLabel: {
                            Image(systemName: "hare")
                        }
                    }

                    Button {
                        speechService.previewVoice()
                    } label: {
                        Label("Preview Voice", systemImage: "play.circle")
                    }

                    Button(role: .destructive) {
                        speechService.stopSpeaking()
                    } label: {
                        Label("Stop Speaking", systemImage: "stop.circle")
                    }
                    .disabled(speechService.isSpeaking == false)
                } footer: {
                    Text("A slower enhanced system voice usually sounds more natural for tutoring and is easier to follow for accessibility.")
                }
            }
            .navigationTitle("Voice")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }

    private var rateLabel: String {
        switch speechService.speechRate {
        case ..<0.39:
            "Slow"
        case 0.39..<0.47:
            "Natural"
        default:
            "Fast"
        }
    }
}

#Preview {
    NavigationStack {
        HomeView()
            .environmentObject(TutorEngine())
            .environmentObject(SpeechService())
    }
}
