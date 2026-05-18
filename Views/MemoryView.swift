import SwiftUI

struct NotesView: View {
    @EnvironmentObject private var assistant: TutorEngine
    @Binding var activeSourceID: UUID?
    let onAskFromNotes: (String) -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    NotesHeader()
                    
                    if assistant.sources.isEmpty {
                        EmptyInlineState(
                            title: "No saved notes",
                            detail: "Paste text, articles, chapters, or lecture transcripts. QuizLoop.ai stores the source locally and turns it into quizzes.",
                            systemImage: "doc.text"
                        )
                    } else {
                        VStack(spacing: 0) {
                            ForEach(assistant.sources) { source in
                                NavigationLink(value: NotesRoute.detail(source.id)) {
                                    NoteRow(
                                        source: source,
                                        isCurrent: activeSourceID == source.id
                                    )
                                }
                                .buttonStyle(.plain)
                                .simultaneousGesture(TapGesture().onEnded {
                                    activeSourceID = source.id
                                })

                                if source.id != assistant.sources.last?.id {
                                    Divider()
                                        .padding(.leading, 16)
                                }
                            }
                        }
                        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
                .padding(16)
                .padding(.bottom, 72)
            }
            .background(QuizLoopTheme.background)
            .navigationDestination(for: NotesRoute.self) { route in
                switch route {
                case .add:
                    AddNotesView(activeSourceID: $activeSourceID)
                case .detail(let sourceID):
                    NoteDetailView(activeSourceID: $activeSourceID, sourceID: sourceID)
                }
            }
        }
    }
}

private struct NotesHeader: View {
    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Library")
                    .font(.largeTitle.weight(.semibold))

                Text("Choose what you want to learn.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 16)

            NavigationLink(value: NotesRoute.add) {
                Image(systemName: "plus")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.teal)
                    .frame(width: 44, height: 44)
                    .background(Color(.systemBackground), in: Circle())
            }
            .accessibilityLabel("Add Note")
        }
    }
}

private enum NotesRoute: Hashable {
    case add
    case detail(UUID)
}

private struct NoteRow: View {
    @EnvironmentObject private var assistant: TutorEngine
    let source: StudySource
    let isCurrent: Bool

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(source.title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if isCurrent {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.teal)
                            .accessibilityLabel("Current note")
                    }
                }

                Text(rowDetail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if let buildProgress {
                    QuizBuildProgressView(progress: buildProgress, compact: true)
                        .padding(.top, 4)
                }
            }

            Spacer(minLength: 12)

            Text(understandingText)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.primary)
                .frame(minWidth: 52, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }

    private var rowDetail: String {
        let prefix = isCurrent ? "Current · " : ""

        if let buildProgress {
            if hasReadyQuiz {
                return "\(prefix)Building more"
            }
            return "\(prefix)\(buildProgress.stage.title) · \(buildProgress.percentText)"
        }

        if source.quizBuildState == .building {
            return "\(prefix)Creating quiz"
        }

        if source.quizBuildState == .partial {
            return hasReadyQuiz ? "\(prefix)Building more" : "\(prefix)Creating quiz"
        }

        if assistant.modelReadiness.isReady == false {
            return "\(prefix)Model needed"
        }

        if source.quizBuildState == .failed || source.status == .failed {
            return "\(prefix)Needs retry"
        }

        if hasReadyQuiz {
            return "\(prefix)\(compactWordCount) words"
        }

        if savedCheckCount > 0 {
            return "\(prefix)Needs new quiz"
        }

        return "\(prefix)\(compactWordCount) words"
    }

    private var wordCount: Int {
        source.text.split { $0.isWhitespace || $0.isNewline }.count
    }

    private var compactWordCount: String {
        if wordCount >= 10_000 {
            return "\(Int((Double(wordCount) / 1_000).rounded()))k"
        }

        if wordCount >= 1_000 {
            let value = Double(wordCount) / 1_000
            return String(format: "%.1fk", value)
        }

        return wordCount.formatted()
    }

    private var understandingText: String {
        let mastery = assistant.coverageNode(for: source).snapshot.weightedMastery
        return "\(Int((mastery * 100).rounded()))%"
    }

    private var availableCheckCount: Int {
        assistant.availableQuizQuestionCount(for: source)
    }

    private var hasReadyQuiz: Bool {
        assistant.hasAvailableQuizQuestions(for: source)
    }

    private var savedCheckCount: Int {
        assistant.questions.filter { $0.sourceID == source.id }.count
    }

    private var buildProgress: QuizBuildProgress? {
        assistant.quizBuildProgress(for: source)
    }

    private var isBuildingChecks: Bool {
        buildProgress != nil
            || source.quizBuildState == .building
            || assistant.isPreparingNextQuiz(for: source.id)
    }

    private var statusColor: Color {
        if hasReadyQuiz {
            return .teal
        }

        if isBuildingChecks {
            return .orange
        }

        return .secondary
    }
}

private struct NoteDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var assistant: TutorEngine
    @Binding var activeSourceID: UUID?
    @State private var isConfirmingDelete = false
    @State private var generatedSummary = ""
    @State private var isGeneratingSummary = false
    @State private var draftTitle = ""
    @State private var draftText = ""
    @FocusState private var focusedField: Field?
    let sourceID: UUID

    private enum Field {
        case title
        case text
    }

    private var source: StudySource? {
        assistant.sources.first { $0.id == sourceID }
    }

    var body: some View {
        Group {
            if let source {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        noteHeader(source)

                        summarySection(source)

                        editorSection(source)
                    }
                    .padding(16)
                    .padding(.bottom, 24)
                }
            } else {
                EmptyInlineState(
                    title: "Note not found",
                    detail: "This note may have been deleted.",
                    systemImage: "doc.text.magnifyingglass"
                )
                .padding(16)
            }
        }
        .background(QuizLoopTheme.background)
        .navigationTitle("Note")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .onAppear {
            activeSourceID = sourceID
            loadDraftIfNeeded()
        }
        .onChange(of: sourceID) {
            loadDraftIfNeeded(force: true)
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    saveChanges()
                }
                .disabled(canSave == false)
            }

            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(role: .destructive) {
                        isConfirmingDelete = true
                    } label: {
                        Label("Delete Note", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Note options")
            }

            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") {
                    focusedField = nil
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if canSave {
                Button {
                    saveChanges()
                } label: {
                    Label("Save Notes", systemImage: "checkmark.circle")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .tint(.teal)
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 8)
                .background(.regularMaterial)
            }
        }
        .confirmationDialog("Delete this note?", isPresented: $isConfirmingDelete, titleVisibility: .visible) {
            if let source {
                Button("Delete Note", role: .destructive) {
                    if activeSourceID == source.id {
                        activeSourceID = nil
                    }
                    assistant.deleteStudySource(source)
                    dismiss()
                }
            }

            Button("Cancel", role: .cancel) { }
        } message: {
            Text("QuizLoop.ai will stop using this note for future quizzes.")
        }
    }

    private func noteHeader(_ source: StudySource) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(source.type.title, systemImage: source.type.systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.teal)

            TextField("Note title", text: $draftTitle)
                .font(.largeTitle.weight(.semibold))
                .focused($focusedField, equals: .title)
                .textFieldStyle(.plain)
                .lineLimit(2)

            Text("\(wordCount) words / saved \(source.createdAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private func summarySection(_ source: StudySource) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Summary")
                    .font(.headline)

                Spacer()

                Button {
                    generateSummary(source)
                } label: {
                    if isGeneratingSummary {
                        Label("Generating", systemImage: "sparkles")
                    } else {
                        Label(summaryText.isEmpty ? "Generate" : "Regenerate", systemImage: "sparkles")
                    }
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isGeneratingSummary || canSave)
            }

            Text(summaryText.isEmpty ? "Generate a short Gemma summary when you want a condensed picture of these notes." : summaryText)
                .font(.subheadline)
                .foregroundStyle(summaryText.isEmpty ? .secondary : .primary)
                .lineSpacing(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func editorSection(_ source: StudySource) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Note Text")
                    .font(.headline)

                Spacer()

                if canSave {
                    Text("Unsaved")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                }
            }

                TextEditor(text: $draftText)
                    .font(.body)
                    .lineSpacing(3)
                    .focused($focusedField, equals: .text)
                    .autocorrectionDisabled()
                    .scrollContentBackground(.hidden)
                    .frame(height: 360)
                    .padding(10)
                .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 8))

        }
    }

    private var wordCount: Int {
        draftText
            .split { $0.isWhitespace || $0.isNewline }
            .count
    }

    private var summaryText: String {
        generatedSummary.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSave: Bool {
        guard let source else { return false }
        let title = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.isEmpty == false else { return false }
        return title != source.title || text != source.text
    }

    private func loadDraftIfNeeded(force: Bool = false) {
        guard let source else { return }
        guard force || draftTitle.isEmpty && draftText.isEmpty else { return }
        draftTitle = source.title
        draftText = source.text
        generatedSummary = source.summary
    }

    private func saveChanges() {
        guard let source, canSave else { return }
        assistant.updateStudySource(source, title: draftTitle, text: draftText)
        generatedSummary = ""
        focusedField = nil
        dismiss()
    }

    private func generateSummary(_ source: StudySource) {
        guard isGeneratingSummary == false else { return }
        isGeneratingSummary = true

        Task {
            let summary = await assistant.generateSummary(for: source)
            generatedSummary = summary
            isGeneratingSummary = false
        }
    }
}

private struct AddNotesView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var assistant: TutorEngine
    @Binding var activeSourceID: UUID?
    @State private var title = ""
    @State private var text = ""
    @State private var inputMode: NoteInputMode = .paste
    @State private var wikiQuery = ""
    @State private var wikiResults: [WikipediaSearchResult] = []
    @State private var selectedWikiResult: WikipediaSearchResult?
    @State private var isSearchingWikipedia = false
    @State private var isImportingWikipedia = false
    @State private var wikipediaError: String?
    @FocusState private var focusedField: Field?

    private enum Field {
        case title
        case text
        case wikipediaSearch
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Picker("Input", selection: $inputMode) {
                    ForEach(NoteInputMode.allCases) { mode in
                        Label(mode.title, systemImage: mode.systemImage)
                            .tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                switch inputMode {
                case .paste:
                    pasteInput
                case .wikipedia:
                    wikipediaInput
                }
            }
            .padding(16)
            .padding(.bottom, 92)
        }
        .background(QuizLoopTheme.background)
        .navigationTitle("Add Notes")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .onChange(of: inputMode) {
            resetInputState()
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
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                saveNotes()
            } label: {
                Label(saveButtonTitle, systemImage: "checkmark.circle")
                    .font(.headline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 48)
            }
            .buttonStyle(.borderedProminent)
            .tint(.teal)
            .disabled(canSave == false)
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 8)
            .background(.regularMaterial)
        }
    }

    private var pasteInput: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Title")
                    .font(.headline)

                TextField("Biology lecture", text: $title)
                    .font(.title2.weight(.semibold))
                    .textFieldStyle(.plain)
                    .focused($focusedField, equals: .title)
                    .padding(12)
                    .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 8))
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Notes")
                    .font(.headline)

                TextEditor(text: $text)
                    .font(.body)
                    .lineSpacing(3)
                    .focused($focusedField, equals: .text)
                    .autocorrectionDisabled()
                    .scrollContentBackground(.hidden)
                    .frame(height: 360)
                    .padding(10)
                    .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var wikipediaInput: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)

                    TextField("Search Wikipedia", text: $wikiQuery)
                        .font(.title3.weight(.semibold))
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .wikipediaSearch)
                        .submitLabel(.search)
                        .onSubmit(searchWikipedia)

                    Button(action: searchWikipedia) {
                        if isSearchingWikipedia {
                            ProgressView()
                                .controlSize(.small)
                                .frame(width: 30, height: 30)
                        } else {
                            Image(systemName: "arrow.right.circle.fill")
                                .font(.title3)
                                .frame(width: 30, height: 30)
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.teal)
                    .disabled(wikiQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSearchingWikipedia)
                    .accessibilityLabel("Search Wikipedia")
                }
                .padding(12)
                .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 8))

                if hasImportedWikipedia == false {
                    Text("Search Wikipedia, choose an article, then save it as notes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            if let wikipediaError {
                Label(wikipediaError, systemImage: "exclamationmark.triangle")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if hasImportedWikipedia {
                ImportedWikipediaCard(
                    title: title.isEmpty ? "Wikipedia article" : title,
                    wordCount: wordCount,
                    preview: text,
                    onChange: resetWikipediaImport
                )
            } else if wikiResults.isEmpty == false {
                VStack(spacing: 0) {
                    ForEach(wikiResults.prefix(6)) { result in
                        Button {
                            importWikipedia(result)
                        } label: {
                            WikipediaResultRow(
                                result: result,
                                isSelected: selectedWikiResult?.id == result.id,
                                isImporting: isImportingWikipedia && selectedWikiResult?.id == result.id
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(isImportingWikipedia)

                        if result.id != wikiResults.last?.id {
                            Divider()
                                .padding(.leading, 14)
                        }
                    }
                }
                .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 8))
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Image(systemName: "globe")
                        .font(.title2)
                        .foregroundStyle(.teal)

                    Text("Search, tap an article, save.")
                        .font(.headline.weight(.semibold))

                    Text("QuizLoop.ai saves the article locally, then builds quizzes from the text.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(14)
                .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var canSave: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    private var saveButtonTitle: String {
        switch inputMode {
        case .paste:
            "Save Notes"
        case .wikipedia:
            "Save Article"
        }
    }

    private var hasImportedWikipedia: Bool {
        inputMode == .wikipedia && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    private func saveNotes() {
        guard canSave else { return }
        if let source = assistant.addStudySource(title: title, text: text, type: inputMode.sourceType) {
            activeSourceID = source.id
        }
        dismiss()
    }

    private var wordCount: Int {
        text
            .split { $0.isWhitespace || $0.isNewline }
            .count
    }

    private func searchWikipedia() {
        let query = wikiQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.isEmpty == false, isSearchingWikipedia == false else { return }

        focusedField = nil
        isSearchingWikipedia = true
        wikipediaError = nil
        selectedWikiResult = nil
        if inputMode == .wikipedia {
            title = ""
            text = ""
        }

        Task {
            do {
                let results = try await WikipediaClient.search(query: query)
                wikiResults = results
                if results.isEmpty {
                    wikipediaError = "No Wikipedia results found."
                }
            } catch {
                wikipediaError = "Wikipedia search failed. Try again."
            }
            isSearchingWikipedia = false
        }
    }

    private func importWikipedia(_ result: WikipediaSearchResult) {
        guard isImportingWikipedia == false else { return }

        selectedWikiResult = result
        isImportingWikipedia = true
        wikipediaError = nil

        Task {
            do {
                let article = try await WikipediaClient.article(for: result)
                title = article.title
                text = article.noteText
            } catch {
                wikipediaError = "Could not import this article."
            }
            isImportingWikipedia = false
        }
    }

    private func resetWikipediaImport() {
        title = ""
        text = ""
        selectedWikiResult = nil
    }

    private func resetInputState() {
        focusedField = nil
        title = ""
        text = ""
        wikiQuery = ""
        wikiResults = []
        selectedWikiResult = nil
        isSearchingWikipedia = false
        isImportingWikipedia = false
        wikipediaError = nil
    }
}

private enum NoteInputMode: String, CaseIterable, Identifiable {
    case paste
    case wikipedia

    var id: String { rawValue }

    var title: String {
        switch self {
        case .paste:
            "Paste"
        case .wikipedia:
            "Wikipedia"
        }
    }

    var systemImage: String {
        switch self {
        case .paste:
            "doc.text"
        case .wikipedia:
            "globe"
        }
    }

    var sourceType: StudySource.SourceType {
        switch self {
        case .paste:
            .notes
        case .wikipedia:
            .wikipedia
        }
    }
}

private struct WikipediaResultRow: View {
    let result: WikipediaSearchResult
    let isSelected: Bool
    let isImporting: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(result.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                Text(result.snippet)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)

            if isImporting {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "plus")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isSelected ? .teal : .secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(result.title). \(result.snippet)")
    }
}

private struct ImportedWikipediaCard: View {
    let title: String
    let wordCount: Int
    let preview: String
    let onChange: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Label("Ready", systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.teal)

                Spacer()

                Text("\(wordCount.formatted()) words")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            Text(title)
                .font(.title2.weight(.semibold))
                .lineLimit(2)

            Text(cleanPreview)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineSpacing(3)
                .lineLimit(6)

            Button("Change article", action: onChange)
                .font(.caption.weight(.semibold))
                .buttonStyle(.plain)
                .foregroundStyle(.teal)
                .accessibilityLabel("Choose a different Wikipedia article")
        }
        .padding(14)
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Ready to save. \(title). \(wordCount.formatted()) words. \(cleanPreview)")
    }

    private var cleanPreview: String {
        let cleaned = preview
            .components(separatedBy: .newlines)
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty == false
                    && trimmed.hasPrefix("Source:") == false
                    && trimmed.hasPrefix("URL:") == false
            }
            .joined(separator: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard cleaned.count > 520 else { return cleaned }
        let prefix = String(cleaned.prefix(520)).trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(prefix)..."
    }
}

private struct WikipediaSearchResult: Identifiable, Equatable {
    let pageID: Int
    let title: String
    let snippet: String

    var id: Int { pageID }
}

private struct WikipediaArticle {
    let title: String
    let extract: String
    let url: String?

    var noteText: String {
        var parts = ["Source: Wikipedia"]
        if let url, url.isEmpty == false {
            parts.append("URL: \(url)")
        }
        parts.append("")
        parts.append(extract)
        return parts.joined(separator: "\n")
    }
}

private enum WikipediaClient {
    private static let host = "en.wikipedia.org"

    static func search(query: String) async throws -> [WikipediaSearchResult] {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/w/api.php"
        components.queryItems = [
            URLQueryItem(name: "action", value: "query"),
            URLQueryItem(name: "list", value: "search"),
            URLQueryItem(name: "srsearch", value: query),
            URLQueryItem(name: "srlimit", value: "8"),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "formatversion", value: "2")
        ]

        guard let url = components.url else { throw URLError(.badURL) }
        let (data, _) = try await URLSession.shared.data(from: url)
        let response = try JSONDecoder().decode(WikipediaSearchResponse.self, from: data)

        return response.query.search.map { page in
            WikipediaSearchResult(
                pageID: page.pageid,
                title: page.title,
                snippet: cleanSnippet(page.snippet)
            )
        }
    }

    static func article(for result: WikipediaSearchResult) async throws -> WikipediaArticle {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/w/api.php"
        components.queryItems = [
            URLQueryItem(name: "action", value: "query"),
            URLQueryItem(name: "prop", value: "extracts|info"),
            URLQueryItem(name: "pageids", value: "\(result.pageID)"),
            URLQueryItem(name: "explaintext", value: "1"),
            URLQueryItem(name: "exsectionformat", value: "plain"),
            URLQueryItem(name: "inprop", value: "url"),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "formatversion", value: "2")
        ]

        guard let url = components.url else { throw URLError(.badURL) }
        let (data, _) = try await URLSession.shared.data(from: url)
        let response = try JSONDecoder().decode(WikipediaArticleResponse.self, from: data)
        guard let page = response.query.pages.first else { throw URLError(.cannotParseResponse) }
        let extract = page.extract.trimmingCharacters(in: .whitespacesAndNewlines)
        guard extract.isEmpty == false else { throw URLError(.zeroByteResource) }

        return WikipediaArticle(title: page.title, extract: extract, url: page.fullurl)
    }

    private static func cleanSnippet(_ snippet: String) -> String {
        snippet
            .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&#039;", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct WikipediaSearchResponse: Decodable {
    let query: Query

    struct Query: Decodable {
        let search: [Page]
    }

    struct Page: Decodable {
        let pageid: Int
        let title: String
        let snippet: String
    }
}

private struct WikipediaArticleResponse: Decodable {
    let query: Query

    struct Query: Decodable {
        let pages: [Page]
    }

    struct Page: Decodable {
        let title: String
        let extract: String
        let fullurl: String?
    }
}

private extension QuizHistoryEntry {
    var notesPercentText: String {
        "\(Int((score * 100).rounded()))%"
    }
}
