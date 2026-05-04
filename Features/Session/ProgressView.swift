import SwiftUI

struct ProgressScreen: View {
    @EnvironmentObject private var assistant: TutorEngine
    @State private var mode: PracticeMode = .due
    @State private var selectedGroup: FlashcardGroup?

    private var modeCards: [StudyFlashcard] {
        mode.cards(in: assistant.flashcards)
    }

    private var reviewCards: [StudyFlashcard] {
        selectedGroup?.cards ?? modeCards
    }

    private var groups: [FlashcardGroup] {
        mode.groups(in: assistant.flashcards)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                PracticeHeader(cards: assistant.flashcards)
                PracticeSummary(cards: assistant.flashcards)

                Picker("Practice mode", selection: $mode) {
                    ForEach(PracticeMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: mode) {
                    selectedGroup = nil
                }

                if assistant.flashcards.isEmpty {
                    EmptyPracticeState()
                } else if reviewCards.isEmpty {
                    EmptyModeState(mode: mode)
                } else {
                    if let selectedGroup {
                        SelectedDeckBanner(group: selectedGroup) {
                            self.selectedGroup = nil
                        }
                    }

                    FlashcardDeck(
                        title: selectedGroup?.title ?? mode.reviewTitle,
                        subtitle: selectedGroup?.subtitle ?? mode.reviewSubtitle(for: reviewCards),
                        cards: reviewCards
                    )
                    PracticeFocus(cards: reviewCards)
                    DeckCollectionSection(mode: mode, groups: groups, selectedGroup: selectedGroup) { group in
                        selectedGroup = group
                    }
                }

                Color.clear
                    .frame(height: 72)
            }
            .padding(16)
        }
        .background(WavesTheme.background)
        .onAppear {
            assistant.refreshPracticeDeck()
        }
    }
}

private enum PracticeMode: String, CaseIterable, Identifiable {
    case due
    case topics
    case sources
    case weak

    var id: String { rawValue }

    var title: String {
        switch self {
        case .due:
            "Due"
        case .topics:
            "Topics"
        case .sources:
            "Sources"
        case .weak:
            "Weak"
        }
    }

    var reviewTitle: String {
        switch self {
        case .due:
            "Due Today"
        case .topics:
            "Topic Review"
        case .sources:
            "Source Review"
        case .weak:
            "Weak Cards"
        }
    }

    var groupTitle: String {
        switch self {
        case .due:
            "Due by Topic"
        case .topics:
            "Topic Decks"
        case .sources:
            "Source Decks"
        case .weak:
            "Weak Areas"
        }
    }

    func reviewSubtitle(for cards: [StudyFlashcard]) -> String {
        switch self {
        case .due:
            "\(cards.count) ready now"
        case .topics:
            "\(cards.count) cards across topics"
        case .sources:
            "\(cards.count) cards from sources"
        case .weak:
            "\(cards.count) cards need another pass"
        }
    }

    func cards(in cards: [StudyFlashcard]) -> [StudyFlashcard] {
        switch self {
        case .due:
            cards.filter(\.isDue)
        case .topics, .sources:
            cards
        case .weak:
            cards.filter(\.isWeak)
        }
    }

    func groups(in cards: [StudyFlashcard]) -> [FlashcardGroup] {
        let filtered = self.cards(in: cards)
        let keyPath: KeyPath<StudyFlashcard, String>

        switch self {
        case .sources:
            keyPath = \.sourceTitle
        case .due, .topics, .weak:
            keyPath = \.deckTitle
        }

        return Dictionary(grouping: filtered) { card in
            let title = card[keyPath: keyPath]
            return title.isEmpty ? "General" : title
        }
        .map { title, cards in
            FlashcardGroup(title: title, cards: cards.sortedForPractice())
        }
        .sorted { lhs, rhs in
            if lhs.dueCount == rhs.dueCount {
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }

            return lhs.dueCount > rhs.dueCount
        }
    }
}

private struct FlashcardGroup: Identifiable, Equatable {
    let id: String
    let title: String
    let cards: [StudyFlashcard]

    init(title: String, cards: [StudyFlashcard]) {
        self.id = title
        self.title = title
        self.cards = cards
    }

    var dueCount: Int {
        cards.filter(\.isDue).count
    }

    var weakCount: Int {
        cards.filter(\.isWeak).count
    }

    var subtitle: String {
        let dueText = dueCount == 1 ? "1 due" : "\(dueCount) due"
        let cardText = cards.count == 1 ? "1 card" : "\(cards.count) cards"
        return "\(dueText) / \(cardText)"
    }
}

private struct PracticeHeader: View {
    let cards: [StudyFlashcard]

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Practice")
                .font(.largeTitle.weight(.semibold))

            Spacer(minLength: 0)

            Text(cards.isEmpty ? "No cards" : "\(cards.count) cards")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }
}

private struct PracticeSummary: View {
    let cards: [StudyFlashcard]

    private var dueCount: Int {
        cards.filter(\.isDue).count
    }

    private var weakCount: Int {
        cards.filter(\.isWeak).count
    }

    var body: some View {
        HStack(spacing: 12) {
            SummaryPill(value: "\(dueCount)", label: "Due")
            SummaryPill(value: "\(cards.count)", label: "Cards")
            SummaryPill(value: "\(weakCount)", label: "Weak")
        }
    }
}

private struct PracticeFocus: View {
    let cards: [StudyFlashcard]

    private var cardTypes: [StudyFlashcard.CardType] {
        var seen: Set<String> = []
        return cards
            .map(\.cardType)
            .filter { type in
                guard seen.contains(type.rawValue) == false else { return false }
                seen.insert(type.rawValue)
                return true
            }
            .prefix(4)
            .map { $0 }
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(cardTypes, id: \.rawValue) { type in
                    Label(type.title, systemImage: type.systemImage)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color(.secondarySystemBackground), in: Capsule())
                }
            }
        }
    }
}

private struct SummaryPill: View {
    let value: String
    let label: String

    var body: some View {
        HStack(spacing: 6) {
            Text(value)
                .font(.subheadline.weight(.semibold))

            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 9)
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct EmptyPracticeState: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Nothing to review yet")
                .font(.headline)

            Text("Ask Waves a question, then use Flashcards on the latest answer to build a study deck.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineSpacing(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct EmptyModeState: View {
    let mode: PracticeMode

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(emptyTitle)
                .font(.headline)

            Text(emptyDetail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 8))
    }

    private var emptyTitle: String {
        switch mode {
        case .due:
            "Nothing due"
        case .topics:
            "No topic decks"
        case .sources:
            "No source decks"
        case .weak:
            "No weak cards"
        }
    }

    private var emptyDetail: String {
        switch mode {
        case .due:
            "You are caught up. Use Topics or Sources to keep studying."
        case .topics:
            "New flashcards will appear here by topic."
        case .sources:
            "Add study material or save answers to build source decks."
        case .weak:
            "Cards marked Again will collect here for extra review."
        }
    }
}

private struct SelectedDeckBanner: View {
    let group: FlashcardGroup
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(group.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)

                Text(group.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            Button(action: onClear) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .frame(width: 28, height: 28)
                    .background(Color(.secondarySystemBackground), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Clear selected deck")
        }
        .padding(12)
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct DeckCollectionSection: View {
    let mode: PracticeMode
    let groups: [FlashcardGroup]
    let selectedGroup: FlashcardGroup?
    let onSelect: (FlashcardGroup) -> Void

    var body: some View {
        if groups.isEmpty == false {
            VStack(alignment: .leading, spacing: 10) {
                Text(mode.groupTitle)
                    .font(.headline)

                VStack(spacing: 8) {
                    ForEach(groups) { group in
                        DeckRow(
                            group: group,
                            isSelected: selectedGroup?.id == group.id,
                            onSelect: { onSelect(group) }
                        )
                    }
                }
            }
        }
    }
}

private struct DeckRow: View {
    let group: FlashcardGroup
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "rectangle.stack")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.teal : Color.secondary)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 3) {
                    Text(group.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Text(group.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                if group.weakCount > 0 {
                    Text("\(group.weakCount) weak")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(12)
            .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}

private struct FlashcardDeck: View {
    @EnvironmentObject private var assistant: TutorEngine
    let title: String
    let subtitle: String
    let cards: [StudyFlashcard]
    @State private var selectedIndex = 0

    var body: some View {
        let currentIndex = min(selectedIndex, max(cards.count - 1, 0))
        let currentCard = cards[currentIndex]

        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.headline)

                    Text(subtitle)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.teal)
                }

                Spacer()

                Text("\(currentIndex + 1) of \(cards.count)")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            FlashcardView(card: currentCard)
                .id(currentCard.id)

            HStack(spacing: 10) {
                DeckNavigationButton(systemImage: "chevron.left", label: "Previous card") {
                    selectedIndex = max(currentIndex - 1, 0)
                }
                .disabled(currentIndex == 0)

                ReviewButton(title: "Again", systemImage: "arrow.counterclockwise") {
                    review(currentCard, as: .again, currentIndex: currentIndex)
                }

                ReviewButton(title: "Hard", systemImage: "exclamationmark") {
                    review(currentCard, as: .hard, currentIndex: currentIndex)
                }

                ReviewButton(title: "Good", systemImage: "checkmark") {
                    review(currentCard, as: .good, currentIndex: currentIndex)
                }

                DeckNavigationButton(systemImage: "chevron.right", label: "Next card") {
                    selectedIndex = min(currentIndex + 1, cards.count - 1)
                }
                .disabled(currentIndex == cards.count - 1)
            }
        }
        .onChange(of: cards) {
            selectedIndex = min(selectedIndex, max(cards.count - 1, 0))
        }
    }

    private func review(_ card: StudyFlashcard, as grade: StudyFlashcard.ReviewGrade, currentIndex: Int) {
        assistant.reviewFlashcard(card, grade: grade)
        selectedIndex = min(currentIndex + 1, max(cards.count - 1, 0))
    }
}

private struct FlashcardView: View {
    let card: StudyFlashcard
    @State private var isShowingBack = false

    var body: some View {
        Button {
            withAnimation(.snappy) {
                isShowingBack.toggle()
            }
        } label: {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label(isShowingBack ? "Back" : "Front", systemImage: isShowingBack ? "checkmark.circle" : "questionmark.circle")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.teal)

                    Spacer()

                    Label(card.cardType.title, systemImage: card.cardType.systemImage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text(isShowingBack ? card.back : card.front)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 4) {
                    Text(card.deckTitle)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)

                    if card.sourceTitle != card.deckTitle {
                        Text(card.sourceTitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if card.referenceText.isEmpty == false {
                    Text(String(card.referenceText.prefix(150)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .padding(.top, 2)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 190, alignment: .topLeading)
            .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onChange(of: card.id) {
            isShowingBack = false
        }
        .accessibilityLabel(isShowingBack ? "Flashcard back. \(card.back)" : "Flashcard front. \(card.front)")
        .accessibilityHint("Double tap to flip the card.")
    }
}

private struct DeckNavigationButton: View {
    let systemImage: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.headline)
                .frame(width: 44, height: 44)
                .background(Color(.secondarySystemBackground), in: Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .accessibilityLabel(label)
    }
}

private struct ReviewButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
    }
}

private extension Array where Element == StudyFlashcard {
    func sortedForPractice() -> [StudyFlashcard] {
        sorted { lhs, rhs in
            if lhs.isDue != rhs.isDue {
                return lhs.isDue
            }

            if lhs.confidence != rhs.confidence {
                return lhs.confidence < rhs.confidence
            }

            return lhs.createdAt > rhs.createdAt
        }
    }
}

#Preview {
    NavigationStack {
        ProgressScreen()
            .environmentObject(TutorEngine())
    }
}
