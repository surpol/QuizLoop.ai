import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class ConversationStore {
    private let databaseURL: URL
    private var database: OpaquePointer?

    init(databaseURL: URL = ConversationStore.defaultDatabaseURL()) {
        self.databaseURL = databaseURL
        open()
        createSchema()
    }

    deinit {
        sqlite3_close(database)
    }

    func loadTurns() -> [TutorTurn] {
        let sql = """
        SELECT id, speaker, text, source_titles, created_at
        FROM messages
        ORDER BY created_at ASC
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(statement) }

        var turns: [TutorTurn] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard
                let idText = sqlite3_column_text(statement, 0),
                let speakerText = sqlite3_column_text(statement, 1),
                let messageText = sqlite3_column_text(statement, 2)
            else {
                continue
            }

            let idString = String(cString: idText)
            let speakerString = String(cString: speakerText)
            let text = String(cString: messageText)
            let sourceTitlesText = sqlite3_column_text(statement, 3).map { String(cString: $0) } ?? ""
            let sourceTitles = sourceTitlesText
                .components(separatedBy: "\n")
                .filter { $0.isEmpty == false }
            let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 4))

            guard
                let id = UUID(uuidString: idString),
                let speaker = TutorTurn.Speaker(databaseValue: speakerString)
            else {
                continue
            }

            turns.append(TutorTurn(id: id, speaker: speaker, text: text, sourceTitles: sourceTitles, createdAt: createdAt))
        }

        return turns
    }

    func loadSources() -> [StudySource] {
        let sql = """
        SELECT id, title, type, status, text, created_at
        FROM study_sources
        ORDER BY created_at DESC
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(statement) }

        var sources: [StudySource] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard
                let idText = sqlite3_column_text(statement, 0),
                let titleText = sqlite3_column_text(statement, 1),
                let typeText = sqlite3_column_text(statement, 2),
                let statusText = sqlite3_column_text(statement, 3),
                let bodyText = sqlite3_column_text(statement, 4)
            else {
                continue
            }

            let idString = String(cString: idText)
            let title = String(cString: titleText)
            let typeString = String(cString: typeText)
            let statusString = String(cString: statusText)
            let text = String(cString: bodyText)
            let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 5))

            guard
                let id = UUID(uuidString: idString),
                let type = StudySource.SourceType(rawValue: typeString)
            else {
                continue
            }

            let status = StudySource.ProcessingStatus(rawValue: statusString) ?? .ready
            sources.append(StudySource(id: id, title: title, type: type, status: status, text: text, createdAt: createdAt))
        }

        return sources
    }

    func loadFlashcards(focusText: String? = nil, limit: Int? = nil) -> [StudyFlashcard] {
        let focusTerms = searchableTerms(in: focusText ?? "")
        let searchableColumn = "lower(deck_title || ' ' || topic || ' ' || card_type || ' ' || source_title || ' ' || front || ' ' || back || ' ' || reference_text)"
        let relevanceSQL = focusTerms
            .map { _ in "CASE WHEN \(searchableColumn) LIKE ? THEN 12 ELSE 0 END" }
            .joined(separator: " + ")
        let scoreSQL = relevanceSQL.isEmpty ? "0" : relevanceSQL
        let limitSQL = limit == nil ? "" : "LIMIT ?"
        let sql = """
        SELECT id, source_id, source_title, deck_title, topic, card_type, front, back, reference_text, created_at, due_at, confidence
        FROM flashcards
        ORDER BY
            (CASE WHEN due_at <= ? THEN 100 ELSE 0 END)
            + (CASE WHEN confidence < 0 THEN 40 ELSE 0 END)
            + (\(scoreSQL)) DESC,
            due_at ASC,
            created_at DESC
        \(limitSQL)
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(statement) }

        var bindIndex: Int32 = 1
        sqlite3_bind_double(statement, bindIndex, Date.now.timeIntervalSince1970)
        bindIndex += 1

        for term in focusTerms {
            sqlite3_bind_text(statement, bindIndex, "%\(term)%", -1, sqliteTransient)
            bindIndex += 1
        }

        if let limit {
            sqlite3_bind_int(statement, bindIndex, Int32(limit))
        }

        var cards: [StudyFlashcard] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard
                let idText = sqlite3_column_text(statement, 0),
                let sourceTitleText = sqlite3_column_text(statement, 2),
                let deckTitleText = sqlite3_column_text(statement, 3),
                let topicText = sqlite3_column_text(statement, 4),
                let cardTypeText = sqlite3_column_text(statement, 5),
                let frontText = sqlite3_column_text(statement, 6),
                let backText = sqlite3_column_text(statement, 7),
                let referenceText = sqlite3_column_text(statement, 8)
            else {
                continue
            }

            let idString = String(cString: idText)
            let sourceIDString = sqlite3_column_text(statement, 1).map { String(cString: $0) }
            let sourceTitle = String(cString: sourceTitleText)
            let deckTitle = String(cString: deckTitleText)
            let topic = String(cString: topicText)
            let cardType = StudyFlashcard.CardType(rawValue: String(cString: cardTypeText)) ?? .recall
            let front = String(cString: frontText)
            let back = String(cString: backText)
            let reference = String(cString: referenceText)
            let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 9))
            let dueAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 10))
            let confidence = Int(sqlite3_column_int(statement, 11))

            guard let id = UUID(uuidString: idString) else {
                continue
            }

            cards.append(
                StudyFlashcard(
                    id: id,
                    sourceID: sourceIDString.flatMap(UUID.init(uuidString:)),
                    sourceTitle: sourceTitle,
                    deckTitle: deckTitle,
                    topic: topic,
                    cardType: cardType,
                    front: front,
                    back: back,
                    referenceText: reference,
                    createdAt: createdAt,
                    dueAt: dueAt,
                    confidence: confidence
                )
            )
        }

        return cards
    }

    func save(_ turn: TutorTurn) {
        let sql = """
        INSERT OR REPLACE INTO messages (id, speaker, text, source_titles, created_at)
        VALUES (?, ?, ?, ?, ?)
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            return
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, turn.id.uuidString, -1, sqliteTransient)
        sqlite3_bind_text(statement, 2, turn.speaker.databaseValue, -1, sqliteTransient)
        sqlite3_bind_text(statement, 3, turn.text, -1, sqliteTransient)
        sqlite3_bind_text(statement, 4, turn.sourceTitles.joined(separator: "\n"), -1, sqliteTransient)
        sqlite3_bind_double(statement, 5, turn.createdAt.timeIntervalSince1970)
        sqlite3_step(statement)
    }

    func save(_ source: StudySource) {
        let sql = """
        INSERT OR REPLACE INTO study_sources (id, title, type, status, text, created_at)
        VALUES (?, ?, ?, ?, ?, ?)
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            return
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, source.id.uuidString, -1, sqliteTransient)
        sqlite3_bind_text(statement, 2, source.title, -1, sqliteTransient)
        sqlite3_bind_text(statement, 3, source.type.rawValue, -1, sqliteTransient)
        sqlite3_bind_text(statement, 4, source.status.rawValue, -1, sqliteTransient)
        sqlite3_bind_text(statement, 5, source.text, -1, sqliteTransient)
        sqlite3_bind_double(statement, 6, source.createdAt.timeIntervalSince1970)
        sqlite3_step(statement)
    }

    func save(_ flashcard: StudyFlashcard) {
        let sql = """
        INSERT OR REPLACE INTO flashcards (id, source_id, source_title, deck_title, topic, card_type, front, back, reference_text, created_at, due_at, confidence)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            return
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, flashcard.id.uuidString, -1, sqliteTransient)
        if let sourceID = flashcard.sourceID {
            sqlite3_bind_text(statement, 2, sourceID.uuidString, -1, sqliteTransient)
        } else {
            sqlite3_bind_null(statement, 2)
        }
        sqlite3_bind_text(statement, 3, flashcard.sourceTitle, -1, sqliteTransient)
        sqlite3_bind_text(statement, 4, flashcard.deckTitle, -1, sqliteTransient)
        sqlite3_bind_text(statement, 5, flashcard.topic, -1, sqliteTransient)
        sqlite3_bind_text(statement, 6, flashcard.cardType.rawValue, -1, sqliteTransient)
        sqlite3_bind_text(statement, 7, flashcard.front, -1, sqliteTransient)
        sqlite3_bind_text(statement, 8, flashcard.back, -1, sqliteTransient)
        sqlite3_bind_text(statement, 9, flashcard.referenceText, -1, sqliteTransient)
        sqlite3_bind_double(statement, 10, flashcard.createdAt.timeIntervalSince1970)
        sqlite3_bind_double(statement, 11, flashcard.dueAt.timeIntervalSince1970)
        sqlite3_bind_int(statement, 12, Int32(flashcard.confidence))
        sqlite3_step(statement)
    }

    func deleteAll() {
        sqlite3_exec(database, "DELETE FROM messages", nil, nil, nil)
    }

    private func open() {
        let directory = databaseURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        sqlite3_open(databaseURL.path, &database)
    }

    private func createSchema() {
        let sql = """
        CREATE TABLE IF NOT EXISTS messages (
            id TEXT PRIMARY KEY NOT NULL,
            speaker TEXT NOT NULL,
            text TEXT NOT NULL,
            source_titles TEXT NOT NULL DEFAULT '',
            created_at REAL NOT NULL
        );

        CREATE INDEX IF NOT EXISTS idx_messages_created_at
        ON messages(created_at);

        CREATE TABLE IF NOT EXISTS study_sources (
            id TEXT PRIMARY KEY NOT NULL,
            title TEXT NOT NULL,
            type TEXT NOT NULL,
            status TEXT NOT NULL DEFAULT 'ready',
            text TEXT NOT NULL,
            created_at REAL NOT NULL
        );

        CREATE INDEX IF NOT EXISTS idx_study_sources_created_at
        ON study_sources(created_at);

        CREATE TABLE IF NOT EXISTS flashcards (
            id TEXT PRIMARY KEY NOT NULL,
            source_id TEXT,
            source_title TEXT NOT NULL,
            deck_title TEXT NOT NULL DEFAULT 'General',
            topic TEXT NOT NULL DEFAULT 'General',
            card_type TEXT NOT NULL DEFAULT 'recall',
            front TEXT NOT NULL,
            back TEXT NOT NULL,
            reference_text TEXT NOT NULL DEFAULT '',
            created_at REAL NOT NULL,
            due_at REAL NOT NULL DEFAULT 0,
            confidence INTEGER NOT NULL DEFAULT 0
        );

        CREATE INDEX IF NOT EXISTS idx_flashcards_created_at
        ON flashcards(created_at);

        CREATE INDEX IF NOT EXISTS idx_flashcards_due_at
        ON flashcards(due_at);

        CREATE INDEX IF NOT EXISTS idx_flashcards_source_id
        ON flashcards(source_id);
        """

        sqlite3_exec(database, sql, nil, nil, nil)
        migrateSchema()
    }

    private func migrateSchema() {
        sqlite3_exec(database, "ALTER TABLE flashcards ADD COLUMN due_at REAL NOT NULL DEFAULT 0", nil, nil, nil)
        sqlite3_exec(database, "ALTER TABLE flashcards ADD COLUMN confidence INTEGER NOT NULL DEFAULT 0", nil, nil, nil)
        sqlite3_exec(database, "ALTER TABLE flashcards ADD COLUMN source_id TEXT", nil, nil, nil)
        sqlite3_exec(database, "ALTER TABLE flashcards ADD COLUMN deck_title TEXT NOT NULL DEFAULT 'General'", nil, nil, nil)
        sqlite3_exec(database, "ALTER TABLE flashcards ADD COLUMN topic TEXT NOT NULL DEFAULT 'General'", nil, nil, nil)
        sqlite3_exec(database, "ALTER TABLE flashcards ADD COLUMN card_type TEXT NOT NULL DEFAULT 'recall'", nil, nil, nil)
        sqlite3_exec(database, "ALTER TABLE flashcards ADD COLUMN reference_text TEXT NOT NULL DEFAULT ''", nil, nil, nil)
        sqlite3_exec(database, "ALTER TABLE messages ADD COLUMN source_titles TEXT NOT NULL DEFAULT ''", nil, nil, nil)
        sqlite3_exec(database, "ALTER TABLE study_sources ADD COLUMN status TEXT NOT NULL DEFAULT 'ready'", nil, nil, nil)
        sqlite3_exec(database, "UPDATE study_sources SET type = 'notes' WHERE type = 'pastedText'", nil, nil, nil)
        sqlite3_exec(database, "UPDATE flashcards SET due_at = created_at WHERE due_at = 0", nil, nil, nil)
        sqlite3_exec(database, "UPDATE flashcards SET topic = source_title WHERE topic = 'General' AND source_title != ''", nil, nil, nil)
        sqlite3_exec(database, "UPDATE flashcards SET deck_title = topic WHERE deck_title = 'General' AND topic != ''", nil, nil, nil)
    }

    private func searchableTerms(in text: String) -> [String] {
        Array(
            Set(
                text
                    .lowercased()
                    .components(separatedBy: CharacterSet.alphanumerics.inverted)
                    .filter { $0.count > 3 }
            )
        )
        .prefix(8)
        .map { $0 }
    }

    private static func defaultDatabaseURL() -> URL {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return baseURL.appending(path: "Waves", directoryHint: .isDirectory).appending(path: "conversations.sqlite")
    }
}

private extension TutorTurn.Speaker {
    init?(databaseValue: String) {
        switch databaseValue {
        case "learner":
            self = .learner
        case "waves":
            self = .waves
        default:
            return nil
        }
    }

    var databaseValue: String {
        switch self {
        case .learner:
            "learner"
        case .waves:
            "waves"
        }
    }
}
