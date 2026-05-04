import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var assistant: TutorEngine
    @EnvironmentObject private var speechService: SpeechService
    @State private var isAddingMaterial = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                LibraryHeader(sourceCount: assistant.sources.count) {
                    isAddingMaterial = true
                }

                if assistant.sources.isEmpty {
                    EmptyLibraryState()
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(assistant.sources) { source in
                            SavedSourceRow(source: source)
                        }
                    }
                }

                Color.clear
                    .frame(height: 72)
            }
            .padding(16)
        }
        .background(WavesTheme.background)
        .sheet(isPresented: $isAddingMaterial) {
            AddMaterialSheet()
                .environmentObject(assistant)
                .environmentObject(speechService)
        }
    }
}

private struct LibraryHeader: View {
    let sourceCount: Int
    let onAdd: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Library")
                    .font(.largeTitle.weight(.semibold))

                Text(sourceCount == 0 ? "No sources" : "\(sourceCount) sources")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            Button(action: onAdd) {
                Image(systemName: "plus")
                    .font(.headline.weight(.semibold))
                    .frame(width: 42, height: 42)
                    .background(Color.teal, in: Circle())
                    .foregroundStyle(.white)
            }
            .accessibilityLabel("Add material")
        }
    }
}

private struct EmptyLibraryState: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No study material yet")
                .font(.headline)

            Text("Add one class source so Waves can ground answers, generate quizzes, and build flashcards from your real coursework.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineSpacing(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct SavedSourceRow: View {
    let source: StudySource

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "doc.text")
                .font(.title3)
                .foregroundStyle(.teal)
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 5) {
                Text(source.title)
                    .font(.headline)
                    .lineLimit(1)

                HStack(spacing: 8) {
                    Label(source.type.title, systemImage: source.type.systemImage)
                    Text(source.status.title)
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

                Text(source.text)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                Text(source.createdAt, format: .dateTime.month().day().hour().minute())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct StudyContextSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var assistant: TutorEngine
    @EnvironmentObject private var speechService: SpeechService
    @State private var title = ""
    @State private var text = ""
    @State private var sourceType: StudySource.SourceType = .notes
    @FocusState private var focusedField: MaterialField?

    var body: some View {
        NavigationStack {
            Form {
                Section("Material Type") {
                    Picker("Material Type", selection: $sourceType) {
                        Text("Notes").tag(StudySource.SourceType.notes)
                        Text("PDF").tag(StudySource.SourceType.pdf)
                        Text("Audio").tag(StudySource.SourceType.audio)
                        Text("Video").tag(StudySource.SourceType.video)
                        Text("Link").tag(StudySource.SourceType.link)
                    }
                    .pickerStyle(.menu)
                    .onChange(of: sourceType) {
                        if sourceType == .audio && title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            title = "Lecture Recording"
                        }
                    }
                }

                if sourceType == .audio {
                    Section {
                        LectureCaptureControls(
                            transcript: speechService.transcript,
                            state: speechService.state,
                            isRecording: speechService.isRecording,
                            onRecord: {
                                focusedField = nil
                                dismissKeyboard()
                                speechService.toggleRecording()
                            },
                            onUseTranscript: {
                                text = speechService.transcript
                            }
                        )
                    } footer: {
                        Text("Record a lecture excerpt to create a transcript. Save the transcript so Waves can use it for answers, flashcards, and quizzes.")
                    }
                }

                Section {
                    TextField("Title optional", text: $title)
                        .focused($focusedField, equals: .title)
                        .textInputAutocapitalization(.words)
                        .accessibilityLabel("Context title")

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Notes")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        TextEditor(text: $text)
                            .focused($focusedField, equals: .notes)
                            .frame(minHeight: 220)
                            .accessibilityLabel("Context notes")
                            .overlay(alignment: .topLeading) {
                                if text.isEmpty {
                                    Text("Paste syllabus notes, class notes, a worksheet question, or a video transcript.")
                                        .foregroundStyle(.tertiary)
                                        .padding(.top, 8)
                                        .padding(.leading, 5)
                                }
                            }
                    }
                } header: {
                    Text("Material")
                } footer: {
                    Text("For now, paste extracted text or transcripts. File, recording, and link processing will use this same local source pipeline.")
                }

                Section {
                    Button {
                        focusedField = nil
                        dismissKeyboard()
                        save()
                    } label: {
                        Label("Save Material", systemImage: "checkmark")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(canSave == false)
                }
            }
            .navigationTitle("Add Material")
            .navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: speechService.transcript) {
                guard sourceType == .audio, speechService.isRecording else { return }
                text = speechService.transcript
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        focusedField = nil
                        dismissKeyboard()
                    }
                }
            }
        }
    }

    private var canSave: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    private func save() {
        if speechService.isRecording {
            speechService.stopRecording()
        }
        assistant.addStudySource(title: title, text: text, type: sourceType)
        dismiss()
    }
}

private struct LectureCaptureControls: View {
    let transcript: String
    let state: SpeechService.RecordingState
    let isRecording: Bool
    let onRecord: () -> Void
    let onUseTranscript: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Button(action: onRecord) {
                    Label(isRecording ? "Stop Recording" : "Record Lecture", systemImage: isRecording ? "stop.fill" : "mic.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(isRecording ? .red : .teal)

                Button(action: onUseTranscript) {
                    Image(systemName: "text.insert")
                        .font(.headline)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.bordered)
                .disabled(transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel("Use transcript")
            }

            HStack(spacing: 8) {
                Image(systemName: isRecording ? "waveform" : statusIcon)
                    .foregroundStyle(isRecording ? .teal : .secondary)

                Text(statusText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if transcript.isEmpty == false {
                Text(transcript)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var statusIcon: String {
        switch state {
        case .idle:
            "mic"
        case .requestingPermission:
            "lock"
        case .recording:
            "waveform"
        case .unavailable:
            "exclamationmark.triangle"
        }
    }

    private var statusText: String {
        switch state {
        case .idle:
            transcript.isEmpty ? "Ready to record a lecture excerpt." : "Transcript ready to save."
        case .requestingPermission:
            "Checking microphone and speech permissions..."
        case .recording:
            transcript.isEmpty ? "Listening..." : "Recording transcript..."
        case .unavailable(let message):
            message
        }
    }
}

private enum MaterialField {
    case title
    case notes
}

private func dismissKeyboard() {
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
}

typealias AddMaterialSheet = StudyContextSheet

#Preview {
    NavigationStack {
        LibraryView()
            .environmentObject(TutorEngine())
    }
}
