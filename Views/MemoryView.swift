import SwiftUI

struct NotesView: View {
    @EnvironmentObject private var assistant: TutorEngine
    @State private var isAddingNotes = false
    @State private var selectedSource: StudySource?
    let onAskFromNotes: (String) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                AppHeader(
                    title: "Notes",
                    subtitle: "Saved material and its learning coverage."
                )

                Button {
                    isAddingNotes = true
                } label: {
                    Label("Add Notes", systemImage: "plus")
                        .frame(maxWidth: .infinity, minHeight: 46)
                }
                .buttonStyle(.borderedProminent)
                .tint(.teal)

                if assistant.sources.isEmpty {
                    EmptyInlineState(
                        title: "No saved notes",
                        detail: "Paste class notes, summaries, or lecture transcripts. Accordian stores them locally with SQLite.",
                        systemImage: "doc.text"
                    )
                } else {
                    NotesCoverageSummary(
                        overall: assistant.masterySnapshot(for: nil),
                        noteCount: assistant.sources.count,
                        questionCount: assistant.questions.count,
                        processingCount: assistant.sources.filter { $0.status == .processing }.count
                    )

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Saved Notes")
                            .font(.headline)

                        ForEach(assistant.sources) { source in
                            Button {
                                selectedSource = source
                            } label: {
                                NoteRow(source: source)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(16)
            .padding(.bottom, 72)
        }
        .background(WavesTheme.background)
        .sheet(isPresented: $isAddingNotes) {
            AddNotesSheet()
        }
        .sheet(item: $selectedSource) { source in
            NoteDetailView(source: source) {
                selectedSource = nil
                onAskFromNotes("Use \(source.title). Summarize these notes.")
            } onDelete: {
                assistant.deleteStudySource(source)
                selectedSource = nil
            }
        }
    }
}

private struct NotesCoverageSummary: View {
    let overall: MasterySnapshot
    let noteCount: Int
    let questionCount: Int
    let processingCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 18) {
                MasteryRing(snapshot: overall, size: 112, lineWidth: 13)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Learning Map")
                        .font(.headline)

                    Text("\(noteCount) saved notes / \(questionCount) learning checks")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    CoveragePill(tested: overall.testedCount, total: overall.totalCount)

                    if processingCount > 0 {
                        Label("\(processingCount) building journey", systemImage: "wand.and.stars")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 0)
            }
        }
        .padding(14)
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct NoteRow: View {
    let source: StudySource

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: source.type.systemImage)
                    .foregroundStyle(.teal)
                    .frame(width: 24)

                Text(source.title)
                    .font(.headline)
                    .lineLimit(1)

                Spacer(minLength: 0)

                Text(source.type.title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(source.status == .processing ? .teal : .secondary)
            }

            Text(source.text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(3)

            if source.status != .ready {
                Label(source.status == .processing ? "Building journey" : "Basic journey ready", systemImage: source.status == .processing ? "wand.and.stars" : "exclamationmark.triangle")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(source.status == .processing ? .teal : .orange)
            }
        }
        .padding(14)
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct NoteDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var isConfirmingDelete = false
    let source: StudySource
    let onAsk: () -> Void
    let onDelete: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(source.type.title, systemImage: source.type.systemImage)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.teal)

                        Text(source.title)
                            .font(.largeTitle.weight(.semibold))
                            .lineLimit(3)

                        Text("\(wordCount) words / saved \(source.createdAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Button {
                        onAsk()
                    } label: {
                        Label("Ask From These Notes", systemImage: "sparkles")
                            .frame(maxWidth: .infinity, minHeight: 46)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.teal)

                    Button(role: .destructive) {
                        isConfirmingDelete = true
                    } label: {
                        Label("Delete Notes", systemImage: "trash")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered)

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Note Text")
                            .font(.headline)

                        Text(source.text)
                            .font(.body)
                            .lineSpacing(3)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                            .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                .padding(16)
                .padding(.bottom, 48)
            }
            .background(WavesTheme.background)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .confirmationDialog("Delete these notes?", isPresented: $isConfirmingDelete, titleVisibility: .visible) {
                Button("Delete Notes", role: .destructive) {
                    onDelete()
                    dismiss()
                }

                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Accordian will stop using these notes. Flashcards generated from them will also be removed.")
            }
        }
    }

    private var wordCount: Int {
        source.text
            .split { $0.isWhitespace || $0.isNewline }
            .count
    }
}

private struct AddNotesSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var assistant: TutorEngine
    @State private var title = ""
    @State private var text = ""
    @FocusState private var focusedField: Field?

    private enum Field {
        case title
        case text
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Title") {
                    TextField("Biology lecture", text: $title)
                        .focused($focusedField, equals: .title)
                }

                Section("Notes") {
                    TextEditor(text: $text)
                        .frame(minHeight: 180)
                        .focused($focusedField, equals: .text)
                }
            }
            .navigationTitle("Add Notes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        assistant.addStudySource(title: title, text: text)
                        dismiss()
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
}
