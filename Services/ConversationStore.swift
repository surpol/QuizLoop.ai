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
        SELECT id, title, type, status, text, summary,
               quiz_build_state, quiz_build_detail, quiz_build_error,
               quiz_build_target_count, quiz_build_saved_count, quiz_build_updated_at,
               created_at
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
            let summary = sqlite3_column_text(statement, 5).map { String(cString: $0) } ?? ""
            let quizBuildStateString = sqlite3_column_text(statement, 6).map { String(cString: $0) } ?? ""
            let quizBuildDetail = sqlite3_column_text(statement, 7).map { String(cString: $0) } ?? ""
            let quizBuildError = sqlite3_column_text(statement, 8).map { String(cString: $0) } ?? ""
            let quizBuildTargetCount = Int(sqlite3_column_int(statement, 9))
            let quizBuildSavedCount = Int(sqlite3_column_int(statement, 10))
            let quizBuildUpdatedAt: Date?
            if sqlite3_column_type(statement, 11) == SQLITE_NULL {
                quizBuildUpdatedAt = nil
            } else {
                quizBuildUpdatedAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 11))
            }
            let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 12))

            guard
                let id = UUID(uuidString: idString),
                let type = StudySource.SourceType(rawValue: typeString)
            else {
                continue
            }

            let status = StudySource.ProcessingStatus(rawValue: statusString) ?? .ready
            let quizBuildState = StudySource.QuizBuildState(rawValue: quizBuildStateString)
                ?? Self.defaultQuizBuildState(status: status, savedCount: quizBuildSavedCount)
            sources.append(
                StudySource(
                    id: id,
                    title: title,
                    type: type,
                    status: status,
                    text: text,
                    summary: summary,
                    quizBuildState: quizBuildState,
                    quizBuildDetail: quizBuildDetail,
                    quizBuildError: quizBuildError,
                    quizBuildTargetCount: quizBuildTargetCount,
                    quizBuildSavedCount: quizBuildSavedCount,
                    quizBuildUpdatedAt: quizBuildUpdatedAt,
                    createdAt: createdAt
                )
            )
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

    func loadXPEvents() -> [XPEvent] {
        let sql = """
        SELECT id, action, points, reason, created_at
        FROM xp_events
        ORDER BY created_at DESC
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(statement) }

        var events: [XPEvent] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard
                let idText = sqlite3_column_text(statement, 0),
                let actionText = sqlite3_column_text(statement, 1),
                let reasonText = sqlite3_column_text(statement, 3),
                let id = UUID(uuidString: String(cString: idText)),
                let action = LearningAction(rawValue: String(cString: actionText))
            else {
                continue
            }

            events.append(
                XPEvent(
                    id: id,
                    action: action,
                    points: Int(sqlite3_column_int(statement, 2)),
                    reason: String(cString: reasonText),
                    createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4))
                )
            )
        }

        return events
    }

    func loadSuggestions() -> [LearningSuggestion] {
        let sql = """
        SELECT id, action, title, detail, priority, created_at
        FROM learning_suggestions
        ORDER BY priority DESC, created_at DESC
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(statement) }

        var suggestions: [LearningSuggestion] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard
                let idText = sqlite3_column_text(statement, 0),
                let actionText = sqlite3_column_text(statement, 1),
                let titleText = sqlite3_column_text(statement, 2),
                let detailText = sqlite3_column_text(statement, 3),
                let id = UUID(uuidString: String(cString: idText)),
                let action = LearningAction(rawValue: String(cString: actionText))
            else {
                continue
            }

            suggestions.append(
                LearningSuggestion(
                    id: id,
                    action: action,
                    title: String(cString: titleText),
                    detail: String(cString: detailText),
                    priority: Int(sqlite3_column_int(statement, 4)),
                    createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5))
                )
            )
        }

        return suggestions
    }

    func loadTopics() -> [LearningTopic] {
        let sql = """
        SELECT id, source_id, title, summary, mastery, created_at
        FROM learning_topics
        ORDER BY created_at DESC
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(statement) }

        var topics: [LearningTopic] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard
                let idText = sqlite3_column_text(statement, 0),
                let titleText = sqlite3_column_text(statement, 2),
                let summaryText = sqlite3_column_text(statement, 3),
                let id = UUID(uuidString: String(cString: idText))
            else {
                continue
            }

            let sourceID = sqlite3_column_text(statement, 1)
                .map { String(cString: $0) }
                .flatMap(UUID.init(uuidString:))

            topics.append(
                LearningTopic(
                    id: id,
                    sourceID: sourceID,
                    title: String(cString: titleText),
                    summary: String(cString: summaryText),
                    mastery: sqlite3_column_double(statement, 4),
                    createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5))
                )
            )
        }

        return topics
    }

    func loadQuestions() -> [LearningQuestion] {
        let sql = """
        SELECT id, source_id, topic_id, segment_id, topic_title, subtopic_title, question_type, prompt, answer, accepted_answers, grading_rubric, choices, importance, difficulty, created_at
        FROM learning_questions
        ORDER BY created_at DESC
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(statement) }

        var questions: [LearningQuestion] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard
                let idText = sqlite3_column_text(statement, 0),
                let topicTitleText = sqlite3_column_text(statement, 4),
                let subtopicTitleText = sqlite3_column_text(statement, 5),
                let typeText = sqlite3_column_text(statement, 6),
                let promptText = sqlite3_column_text(statement, 7),
                let answerText = sqlite3_column_text(statement, 8),
                let id = UUID(uuidString: String(cString: idText)),
                let type = LearningQuestion.QuestionType(rawValue: String(cString: typeText))
            else {
                continue
            }

            let sourceID = sqlite3_column_text(statement, 1)
                .map { String(cString: $0) }
                .flatMap(UUID.init(uuidString:))
            let topicID = sqlite3_column_text(statement, 2)
                .map { String(cString: $0) }
                .flatMap(UUID.init(uuidString:))
            let segmentID = sqlite3_column_text(statement, 3)
                .map { String(cString: $0) }
                .flatMap(UUID.init(uuidString:))
            let acceptedAnswersText = sqlite3_column_text(statement, 9).map { String(cString: $0) } ?? ""
            let acceptedAnswers = acceptedAnswersText.components(separatedBy: "\n").filter { $0.isEmpty == false }
            let gradingRubric = sqlite3_column_text(statement, 10).map { String(cString: $0) } ?? ""
            let choicesText = sqlite3_column_text(statement, 11).map { String(cString: $0) } ?? ""
            let choices = choicesText.components(separatedBy: "\n").filter { $0.isEmpty == false }

            questions.append(
                LearningQuestion(
                    id: id,
                    sourceID: sourceID,
                    topicID: topicID,
                    segmentID: segmentID,
                    topicTitle: String(cString: topicTitleText),
                    subtopicTitle: String(cString: subtopicTitleText),
                    type: type,
                    prompt: String(cString: promptText),
                    answer: String(cString: answerText),
                    acceptedAnswers: acceptedAnswers,
                    gradingRubric: gradingRubric,
                    choices: choices,
                    importance: sqlite3_column_double(statement, 12),
                    difficulty: sqlite3_column_double(statement, 13),
                    createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 14))
                )
            )
        }

        return questions
    }

    func loadSegments() -> [LearningSegment] {
        let sql = """
        SELECT id, source_id, topic_id, topic_title, subtopic_title, text, evidence, importance, difficulty, created_at
        FROM learning_segments
        ORDER BY created_at DESC
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(statement) }

        var segments: [LearningSegment] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard
                let idText = sqlite3_column_text(statement, 0),
                let topicTitleText = sqlite3_column_text(statement, 3),
                let subtopicTitleText = sqlite3_column_text(statement, 4),
                let text = sqlite3_column_text(statement, 5),
                let evidence = sqlite3_column_text(statement, 6),
                let id = UUID(uuidString: String(cString: idText))
            else {
                continue
            }

            let sourceID = sqlite3_column_text(statement, 1)
                .map { String(cString: $0) }
                .flatMap(UUID.init(uuidString:))
            let topicID = sqlite3_column_text(statement, 2)
                .map { String(cString: $0) }
                .flatMap(UUID.init(uuidString:))

            segments.append(
                LearningSegment(
                    id: id,
                    sourceID: sourceID,
                    topicID: topicID,
                    topicTitle: String(cString: topicTitleText),
                    subtopicTitle: String(cString: subtopicTitleText),
                    text: String(cString: text),
                    evidence: String(cString: evidence),
                    importance: sqlite3_column_double(statement, 7),
                    difficulty: sqlite3_column_double(statement, 8),
                    createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 9))
                )
            )
        }

        return segments
    }

    func loadAssignments() -> [JourneyAssignment] {
        let sql = """
        SELECT id, segment_id, question_id, type, reason, priority, due_at, status, created_at, completed_at
        FROM journey_assignments
        ORDER BY status ASC, due_at ASC, priority DESC, created_at DESC
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(statement) }

        var assignments: [JourneyAssignment] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard
                let idText = sqlite3_column_text(statement, 0),
                let typeText = sqlite3_column_text(statement, 3),
                let reasonText = sqlite3_column_text(statement, 4),
                let statusText = sqlite3_column_text(statement, 7),
                let id = UUID(uuidString: String(cString: idText)),
                let type = JourneyAssignment.AssignmentType(rawValue: String(cString: typeText)),
                let status = JourneyAssignment.Status(rawValue: String(cString: statusText))
            else {
                continue
            }

            let segmentID = sqlite3_column_text(statement, 1)
                .map { String(cString: $0) }
                .flatMap(UUID.init(uuidString:))
            let questionID = sqlite3_column_text(statement, 2)
                .map { String(cString: $0) }
                .flatMap(UUID.init(uuidString:))
            let completedAt = sqlite3_column_type(statement, 9) == SQLITE_NULL
                ? nil
                : Date(timeIntervalSince1970: sqlite3_column_double(statement, 9))

            assignments.append(
                JourneyAssignment(
                    id: id,
                    segmentID: segmentID,
                    questionID: questionID,
                    type: type,
                    reason: String(cString: reasonText),
                    priority: sqlite3_column_double(statement, 5),
                    dueAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 6)),
                    status: status,
                    createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 8)),
                    completedAt: completedAt
                )
            )
        }

        return assignments
    }

    func loadAttempts() -> [QuestionAttempt] {
        let sql = """
        SELECT id, question_id, response, score, feedback, matched_ideas, missing_ideas, created_at
        FROM question_attempts
        ORDER BY created_at DESC
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(statement) }

        var attempts: [QuestionAttempt] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard
                let idText = sqlite3_column_text(statement, 0),
                let questionIDText = sqlite3_column_text(statement, 1),
                let responseText = sqlite3_column_text(statement, 2),
                let id = UUID(uuidString: String(cString: idText)),
                let questionID = UUID(uuidString: String(cString: questionIDText))
            else {
                continue
            }

            attempts.append(
                QuestionAttempt(
                    id: id,
                    questionID: questionID,
                    response: String(cString: responseText),
                    score: sqlite3_column_double(statement, 3),
                    feedback: Self.optionalString(statement, column: 4),
                    matchedIdeas: Self.decodeStringArray(Self.optionalString(statement, column: 5)),
                    missingIdeas: Self.decodeStringArray(Self.optionalString(statement, column: 6)),
                    createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 7))
                )
            )
        }

        return attempts
    }

    func loadRecentAttemptPrompts(sourceID: UUID?, since: Date, minimumScore: Double) -> [String] {
        let sql: String
        if sourceID == nil {
            sql = """
            SELECT prompt
            FROM question_attempts
            WHERE prompt IS NOT NULL
              AND TRIM(prompt) != ''
              AND score >= ?
              AND created_at >= ?
            ORDER BY created_at DESC
            """
        } else {
            sql = """
            SELECT prompt
            FROM question_attempts
            WHERE prompt IS NOT NULL
              AND TRIM(prompt) != ''
              AND score >= ?
              AND created_at >= ?
              AND source_id = ?
            ORDER BY created_at DESC
            """
        }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_double(statement, 1, minimumScore)
        sqlite3_bind_double(statement, 2, since.timeIntervalSince1970)
        if let sourceID {
            sqlite3_bind_text(statement, 3, sourceID.uuidString, -1, sqliteTransient)
        }

        var prompts: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let promptText = sqlite3_column_text(statement, 0) else { continue }
            prompts.append(String(cString: promptText))
        }

        return prompts
    }

    func loadQuizHistory() -> [QuizHistoryEntry] {
        let sql = """
        SELECT id, source_id, title, score, question_count, got_count, close_count, review_count, attempt_ids, created_at
        FROM quiz_sessions
        ORDER BY created_at DESC
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(statement) }

        var history: [QuizHistoryEntry] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard
                let idText = sqlite3_column_text(statement, 0),
                let titleText = sqlite3_column_text(statement, 2),
                let id = UUID(uuidString: String(cString: idText))
            else {
                continue
            }

            let sourceID = sqlite3_column_text(statement, 1)
                .map { String(cString: $0) }
                .flatMap(UUID.init(uuidString:))

            history.append(
                QuizHistoryEntry(
                    id: id,
                    sourceID: sourceID,
                    title: String(cString: titleText),
                    score: sqlite3_column_double(statement, 3),
                    questionCount: Int(sqlite3_column_int(statement, 4)),
                    gotCount: Int(sqlite3_column_int(statement, 5)),
                    closeCount: Int(sqlite3_column_int(statement, 6)),
                    reviewCount: Int(sqlite3_column_int(statement, 7)),
                    attemptIDs: Self.decodeUUIDArray(Self.optionalString(statement, column: 8)),
                    createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 9))
                )
            )
        }

        return history
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
        INSERT OR REPLACE INTO study_sources (
            id, title, type, status, text, summary,
            quiz_build_state, quiz_build_detail, quiz_build_error,
            quiz_build_target_count, quiz_build_saved_count, quiz_build_updated_at,
            created_at
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
        sqlite3_bind_text(statement, 6, source.summary, -1, sqliteTransient)
        sqlite3_bind_text(statement, 7, source.quizBuildState.rawValue, -1, sqliteTransient)
        sqlite3_bind_text(statement, 8, source.quizBuildDetail, -1, sqliteTransient)
        sqlite3_bind_text(statement, 9, source.quizBuildError, -1, sqliteTransient)
        sqlite3_bind_int(statement, 10, Int32(source.quizBuildTargetCount))
        sqlite3_bind_int(statement, 11, Int32(source.quizBuildSavedCount))
        if let quizBuildUpdatedAt = source.quizBuildUpdatedAt {
            sqlite3_bind_double(statement, 12, quizBuildUpdatedAt.timeIntervalSince1970)
        } else {
            sqlite3_bind_null(statement, 12)
        }
        sqlite3_bind_double(statement, 13, source.createdAt.timeIntervalSince1970)
        sqlite3_step(statement)
    }

    func updateSourceStatus(id: UUID, status: StudySource.ProcessingStatus) {
        let sql = """
        UPDATE study_sources
        SET status = ?
        WHERE id = ?
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            return
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, status.rawValue, -1, sqliteTransient)
        sqlite3_bind_text(statement, 2, id.uuidString, -1, sqliteTransient)
        sqlite3_step(statement)
    }

    func updateQuizBuildState(
        id: UUID,
        state: StudySource.QuizBuildState,
        detail: String,
        error: String,
        targetCount: Int,
        savedCount: Int,
        stage: String
    ) {
        let updatedAt = Date.now
        let sql = """
        UPDATE study_sources
        SET quiz_build_state = ?,
            quiz_build_detail = ?,
            quiz_build_error = ?,
            quiz_build_target_count = ?,
            quiz_build_saved_count = ?,
            quiz_build_updated_at = ?
        WHERE id = ?
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            return
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, state.rawValue, -1, sqliteTransient)
        sqlite3_bind_text(statement, 2, detail, -1, sqliteTransient)
        sqlite3_bind_text(statement, 3, error, -1, sqliteTransient)
        sqlite3_bind_int(statement, 4, Int32(targetCount))
        sqlite3_bind_int(statement, 5, Int32(savedCount))
        sqlite3_bind_double(statement, 6, updatedAt.timeIntervalSince1970)
        sqlite3_bind_text(statement, 7, id.uuidString, -1, sqliteTransient)
        sqlite3_step(statement)

        saveQuizBuildAttempt(
            sourceID: id,
            state: state,
            stage: stage,
            targetCount: targetCount,
            savedCount: savedCount,
            detail: detail,
            error: error,
            createdAt: updatedAt
        )
    }

    private func saveQuizBuildAttempt(
        sourceID: UUID,
        state: StudySource.QuizBuildState,
        stage: String,
        targetCount: Int,
        savedCount: Int,
        detail: String,
        error: String,
        createdAt: Date
    ) {
        let sql = """
        INSERT INTO quiz_build_attempts (
            id, source_id, state, stage, target_count, saved_count, detail, error, created_at
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            return
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, UUID().uuidString, -1, sqliteTransient)
        sqlite3_bind_text(statement, 2, sourceID.uuidString, -1, sqliteTransient)
        sqlite3_bind_text(statement, 3, state.rawValue, -1, sqliteTransient)
        sqlite3_bind_text(statement, 4, stage, -1, sqliteTransient)
        sqlite3_bind_int(statement, 5, Int32(targetCount))
        sqlite3_bind_int(statement, 6, Int32(savedCount))
        sqlite3_bind_text(statement, 7, detail, -1, sqliteTransient)
        sqlite3_bind_text(statement, 8, error, -1, sqliteTransient)
        sqlite3_bind_double(statement, 9, createdAt.timeIntervalSince1970)
        sqlite3_step(statement)
    }

    func updateSourceSummary(id: UUID, summary: String) {
        let sql = """
        UPDATE study_sources
        SET summary = ?
        WHERE id = ?
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            return
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, summary, -1, sqliteTransient)
        sqlite3_bind_text(statement, 2, id.uuidString, -1, sqliteTransient)
        sqlite3_step(statement)
    }

    func deleteSource(id: UUID) {
        executeDelete("DELETE FROM study_sources WHERE id = ?", id: id.uuidString)
        executeDelete("DELETE FROM flashcards WHERE source_id = ?", id: id.uuidString)
        executeDelete("DELETE FROM learning_topics WHERE source_id = ?", id: id.uuidString)
        executeDelete("DELETE FROM learning_segments WHERE source_id = ?", id: id.uuidString)
        executeDelete("DELETE FROM learning_questions WHERE source_id = ?", id: id.uuidString)
        executeDelete("DELETE FROM quiz_sessions WHERE source_id = ?", id: id.uuidString)
        sqlite3_exec(database, "DELETE FROM journey_assignments WHERE segment_id NOT IN (SELECT id FROM learning_segments)", nil, nil, nil)
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

    func save(_ event: XPEvent) {
        let sql = """
        INSERT OR REPLACE INTO xp_events (id, action, points, reason, created_at)
        VALUES (?, ?, ?, ?, ?)
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            return
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, event.id.uuidString, -1, sqliteTransient)
        sqlite3_bind_text(statement, 2, event.action.rawValue, -1, sqliteTransient)
        sqlite3_bind_int(statement, 3, Int32(event.points))
        sqlite3_bind_text(statement, 4, event.reason, -1, sqliteTransient)
        sqlite3_bind_double(statement, 5, event.createdAt.timeIntervalSince1970)
        sqlite3_step(statement)
    }

    func save(_ topic: LearningTopic) {
        let sql = """
        INSERT OR REPLACE INTO learning_topics (id, source_id, title, summary, mastery, created_at)
        VALUES (?, ?, ?, ?, ?, ?)
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            return
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, topic.id.uuidString, -1, sqliteTransient)
        if let sourceID = topic.sourceID {
            sqlite3_bind_text(statement, 2, sourceID.uuidString, -1, sqliteTransient)
        } else {
            sqlite3_bind_null(statement, 2)
        }
        sqlite3_bind_text(statement, 3, topic.title, -1, sqliteTransient)
        sqlite3_bind_text(statement, 4, topic.summary, -1, sqliteTransient)
        sqlite3_bind_double(statement, 5, topic.mastery)
        sqlite3_bind_double(statement, 6, topic.createdAt.timeIntervalSince1970)
        sqlite3_step(statement)
    }

    func save(_ segment: LearningSegment) {
        let sql = """
        INSERT OR REPLACE INTO learning_segments (id, source_id, topic_id, topic_title, subtopic_title, text, evidence, importance, difficulty, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            return
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, segment.id.uuidString, -1, sqliteTransient)
        if let sourceID = segment.sourceID {
            sqlite3_bind_text(statement, 2, sourceID.uuidString, -1, sqliteTransient)
        } else {
            sqlite3_bind_null(statement, 2)
        }
        if let topicID = segment.topicID {
            sqlite3_bind_text(statement, 3, topicID.uuidString, -1, sqliteTransient)
        } else {
            sqlite3_bind_null(statement, 3)
        }
        sqlite3_bind_text(statement, 4, segment.topicTitle, -1, sqliteTransient)
        sqlite3_bind_text(statement, 5, segment.subtopicTitle, -1, sqliteTransient)
        sqlite3_bind_text(statement, 6, segment.text, -1, sqliteTransient)
        sqlite3_bind_text(statement, 7, segment.evidence, -1, sqliteTransient)
        sqlite3_bind_double(statement, 8, segment.importance)
        sqlite3_bind_double(statement, 9, segment.difficulty)
        sqlite3_bind_double(statement, 10, segment.createdAt.timeIntervalSince1970)
        sqlite3_step(statement)
    }

    func save(_ question: LearningQuestion) {
        let sql = """
        INSERT OR REPLACE INTO learning_questions (id, source_id, topic_id, segment_id, topic_title, subtopic_title, question_type, prompt, answer, accepted_answers, grading_rubric, choices, importance, difficulty, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            return
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, question.id.uuidString, -1, sqliteTransient)
        if let sourceID = question.sourceID {
            sqlite3_bind_text(statement, 2, sourceID.uuidString, -1, sqliteTransient)
        } else {
            sqlite3_bind_null(statement, 2)
        }
        if let topicID = question.topicID {
            sqlite3_bind_text(statement, 3, topicID.uuidString, -1, sqliteTransient)
        } else {
            sqlite3_bind_null(statement, 3)
        }
        if let segmentID = question.segmentID {
            sqlite3_bind_text(statement, 4, segmentID.uuidString, -1, sqliteTransient)
        } else {
            sqlite3_bind_null(statement, 4)
        }
        sqlite3_bind_text(statement, 5, question.topicTitle, -1, sqliteTransient)
        sqlite3_bind_text(statement, 6, question.subtopicTitle, -1, sqliteTransient)
        sqlite3_bind_text(statement, 7, question.type.rawValue, -1, sqliteTransient)
        sqlite3_bind_text(statement, 8, question.prompt, -1, sqliteTransient)
        sqlite3_bind_text(statement, 9, question.answer, -1, sqliteTransient)
        sqlite3_bind_text(statement, 10, question.acceptedAnswers.joined(separator: "\n"), -1, sqliteTransient)
        sqlite3_bind_text(statement, 11, question.gradingRubric, -1, sqliteTransient)
        sqlite3_bind_text(statement, 12, question.choices.joined(separator: "\n"), -1, sqliteTransient)
        sqlite3_bind_double(statement, 13, question.importance)
        sqlite3_bind_double(statement, 14, question.difficulty)
        sqlite3_bind_double(statement, 15, question.createdAt.timeIntervalSince1970)
        sqlite3_step(statement)
    }

    func save(_ assignment: JourneyAssignment) {
        let sql = """
        INSERT OR REPLACE INTO journey_assignments (id, segment_id, question_id, type, reason, priority, due_at, status, created_at, completed_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            return
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, assignment.id.uuidString, -1, sqliteTransient)
        if let segmentID = assignment.segmentID {
            sqlite3_bind_text(statement, 2, segmentID.uuidString, -1, sqliteTransient)
        } else {
            sqlite3_bind_null(statement, 2)
        }
        if let questionID = assignment.questionID {
            sqlite3_bind_text(statement, 3, questionID.uuidString, -1, sqliteTransient)
        } else {
            sqlite3_bind_null(statement, 3)
        }
        sqlite3_bind_text(statement, 4, assignment.type.rawValue, -1, sqliteTransient)
        sqlite3_bind_text(statement, 5, assignment.reason, -1, sqliteTransient)
        sqlite3_bind_double(statement, 6, assignment.priority)
        sqlite3_bind_double(statement, 7, assignment.dueAt.timeIntervalSince1970)
        sqlite3_bind_text(statement, 8, assignment.status.rawValue, -1, sqliteTransient)
        sqlite3_bind_double(statement, 9, assignment.createdAt.timeIntervalSince1970)
        if let completedAt = assignment.completedAt {
            sqlite3_bind_double(statement, 10, completedAt.timeIntervalSince1970)
        } else {
            sqlite3_bind_null(statement, 10)
        }
        sqlite3_step(statement)
    }

    func save(_ attempt: QuestionAttempt) {
        let sql = """
        INSERT INTO question_attempts (id, question_id, response, score, feedback, matched_ideas, missing_ideas, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            question_id = excluded.question_id,
            response = excluded.response,
            score = excluded.score,
            feedback = excluded.feedback,
            matched_ideas = excluded.matched_ideas,
            missing_ideas = excluded.missing_ideas,
            created_at = excluded.created_at
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            return
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, attempt.id.uuidString, -1, sqliteTransient)
        sqlite3_bind_text(statement, 2, attempt.questionID.uuidString, -1, sqliteTransient)
        sqlite3_bind_text(statement, 3, attempt.response, -1, sqliteTransient)
        sqlite3_bind_double(statement, 4, attempt.score)
        bindOptionalText(statement, index: 5, value: attempt.feedback)
        sqlite3_bind_text(statement, 6, Self.encodeStringArray(attempt.matchedIdeas), -1, sqliteTransient)
        sqlite3_bind_text(statement, 7, Self.encodeStringArray(attempt.missingIdeas), -1, sqliteTransient)
        sqlite3_bind_double(statement, 8, attempt.createdAt.timeIntervalSince1970)
        sqlite3_step(statement)
    }

    func save(_ attempt: QuestionAttempt, question: LearningQuestion) {
        let sql = """
        INSERT INTO question_attempts (
            id, question_id, source_id, topic_title, subtopic_title, question_type,
            prompt, answer, response, score, feedback, matched_ideas, missing_ideas, created_at
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            question_id = excluded.question_id,
            source_id = excluded.source_id,
            topic_title = excluded.topic_title,
            subtopic_title = excluded.subtopic_title,
            question_type = excluded.question_type,
            prompt = excluded.prompt,
            answer = excluded.answer,
            response = excluded.response,
            score = excluded.score,
            feedback = excluded.feedback,
            matched_ideas = excluded.matched_ideas,
            missing_ideas = excluded.missing_ideas,
            created_at = excluded.created_at
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            return
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, attempt.id.uuidString, -1, sqliteTransient)
        sqlite3_bind_text(statement, 2, attempt.questionID.uuidString, -1, sqliteTransient)
        if let sourceID = question.sourceID {
            sqlite3_bind_text(statement, 3, sourceID.uuidString, -1, sqliteTransient)
        } else {
            sqlite3_bind_null(statement, 3)
        }
        sqlite3_bind_text(statement, 4, question.topicTitle, -1, sqliteTransient)
        sqlite3_bind_text(statement, 5, question.subtopicTitle, -1, sqliteTransient)
        sqlite3_bind_text(statement, 6, question.type.rawValue, -1, sqliteTransient)
        sqlite3_bind_text(statement, 7, question.prompt, -1, sqliteTransient)
        sqlite3_bind_text(statement, 8, question.answer, -1, sqliteTransient)
        sqlite3_bind_text(statement, 9, attempt.response, -1, sqliteTransient)
        sqlite3_bind_double(statement, 10, attempt.score)
        bindOptionalText(statement, index: 11, value: attempt.feedback)
        sqlite3_bind_text(statement, 12, Self.encodeStringArray(attempt.matchedIdeas), -1, sqliteTransient)
        sqlite3_bind_text(statement, 13, Self.encodeStringArray(attempt.missingIdeas), -1, sqliteTransient)
        sqlite3_bind_double(statement, 14, attempt.createdAt.timeIntervalSince1970)
        sqlite3_step(statement)
    }

    func save(_ quiz: QuizHistoryEntry) {
        let sql = """
        INSERT OR REPLACE INTO quiz_sessions (
            id, source_id, title, score, question_count, got_count, close_count, review_count, attempt_ids, created_at
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            return
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, quiz.id.uuidString, -1, sqliteTransient)
        if let sourceID = quiz.sourceID {
            sqlite3_bind_text(statement, 2, sourceID.uuidString, -1, sqliteTransient)
        } else {
            sqlite3_bind_null(statement, 2)
        }
        sqlite3_bind_text(statement, 3, quiz.title, -1, sqliteTransient)
        sqlite3_bind_double(statement, 4, quiz.score)
        sqlite3_bind_int(statement, 5, Int32(quiz.questionCount))
        sqlite3_bind_int(statement, 6, Int32(quiz.gotCount))
        sqlite3_bind_int(statement, 7, Int32(quiz.closeCount))
        sqlite3_bind_int(statement, 8, Int32(quiz.reviewCount))
        sqlite3_bind_text(statement, 9, quiz.attemptIDs.map(\.uuidString).joined(separator: "\n"), -1, sqliteTransient)
        sqlite3_bind_double(statement, 10, quiz.createdAt.timeIntervalSince1970)
        sqlite3_step(statement)
    }

    func saveInteractionEvent(
        kind: String,
        sourceID: UUID? = nil,
        questionID: UUID? = nil,
        quizID: UUID? = nil,
        conceptSignature: String? = nil,
        detail: String = "",
        metadata: String = "{}",
        createdAt: Date = .now
    ) {
        let sql = """
        INSERT INTO learning_events (
            id, kind, source_id, question_id, quiz_id, concept_signature, detail, metadata, created_at
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            return
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, UUID().uuidString, -1, sqliteTransient)
        sqlite3_bind_text(statement, 2, kind, -1, sqliteTransient)
        bindOptionalText(statement, index: 3, value: sourceID?.uuidString)
        bindOptionalText(statement, index: 4, value: questionID?.uuidString)
        bindOptionalText(statement, index: 5, value: quizID?.uuidString)
        bindOptionalText(statement, index: 6, value: conceptSignature)
        sqlite3_bind_text(statement, 7, detail, -1, sqliteTransient)
        sqlite3_bind_text(statement, 8, metadata, -1, sqliteTransient)
        sqlite3_bind_double(statement, 9, createdAt.timeIntervalSince1970)
        sqlite3_step(statement)
    }

    func saveQuestionMemory(
        questionID: UUID,
        sourceID: UUID?,
        conceptSignature: String,
        assessmentAngle: String,
        generationSource: String,
        qualityFlags: [String],
        latestScore: Double?,
        attemptCount: Int,
        lastSeenAt: Date?,
        status: String
    ) {
        let sql = """
        INSERT INTO question_memory (
            question_id, source_id, concept_signature, assessment_angle, generation_source,
            quality_flags, latest_score, attempt_count, last_seen_at, status, updated_at
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(question_id) DO UPDATE SET
            source_id = excluded.source_id,
            concept_signature = excluded.concept_signature,
            assessment_angle = excluded.assessment_angle,
            generation_source = excluded.generation_source,
            quality_flags = excluded.quality_flags,
            latest_score = excluded.latest_score,
            attempt_count = excluded.attempt_count,
            last_seen_at = excluded.last_seen_at,
            status = excluded.status,
            updated_at = excluded.updated_at
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            return
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, questionID.uuidString, -1, sqliteTransient)
        bindOptionalText(statement, index: 2, value: sourceID?.uuidString)
        sqlite3_bind_text(statement, 3, conceptSignature, -1, sqliteTransient)
        sqlite3_bind_text(statement, 4, assessmentAngle, -1, sqliteTransient)
        sqlite3_bind_text(statement, 5, generationSource, -1, sqliteTransient)
        sqlite3_bind_text(statement, 6, Self.encodeStringArray(qualityFlags), -1, sqliteTransient)
        if let latestScore {
            sqlite3_bind_double(statement, 7, latestScore)
        } else {
            sqlite3_bind_null(statement, 7)
        }
        sqlite3_bind_int(statement, 8, Int32(attemptCount))
        if let lastSeenAt {
            sqlite3_bind_double(statement, 9, lastSeenAt.timeIntervalSince1970)
        } else {
            sqlite3_bind_null(statement, 9)
        }
        sqlite3_bind_text(statement, 10, status, -1, sqliteTransient)
        sqlite3_bind_double(statement, 11, Date.now.timeIntervalSince1970)
        sqlite3_step(statement)
    }

    func saveConceptMemory(
        sourceID: UUID?,
        conceptSignature: String,
        topicTitle: String,
        subtopicTitle: String,
        assessmentAngle: String,
        latestScore: Double?,
        averageScore: Double?,
        attemptCount: Int,
        lastSeenAt: Date?,
        nextDueAt: Date?,
        state: String,
        dueReason: String
    ) {
        let sql = """
        INSERT INTO concept_memory (
            source_id, concept_signature, topic_title, subtopic_title, assessment_angle,
            latest_score, average_score, attempt_count, last_seen_at, next_due_at,
            state, due_reason, updated_at
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(source_id, concept_signature) DO UPDATE SET
            topic_title = excluded.topic_title,
            subtopic_title = excluded.subtopic_title,
            assessment_angle = excluded.assessment_angle,
            latest_score = excluded.latest_score,
            average_score = excluded.average_score,
            attempt_count = excluded.attempt_count,
            last_seen_at = excluded.last_seen_at,
            next_due_at = excluded.next_due_at,
            state = excluded.state,
            due_reason = excluded.due_reason,
            updated_at = excluded.updated_at
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            return
        }
        defer { sqlite3_finalize(statement) }

        bindOptionalText(statement, index: 1, value: sourceID?.uuidString ?? "global")
        sqlite3_bind_text(statement, 2, conceptSignature, -1, sqliteTransient)
        sqlite3_bind_text(statement, 3, topicTitle, -1, sqliteTransient)
        sqlite3_bind_text(statement, 4, subtopicTitle, -1, sqliteTransient)
        sqlite3_bind_text(statement, 5, assessmentAngle, -1, sqliteTransient)
        if let latestScore {
            sqlite3_bind_double(statement, 6, latestScore)
        } else {
            sqlite3_bind_null(statement, 6)
        }
        if let averageScore {
            sqlite3_bind_double(statement, 7, averageScore)
        } else {
            sqlite3_bind_null(statement, 7)
        }
        sqlite3_bind_int(statement, 8, Int32(attemptCount))
        if let lastSeenAt {
            sqlite3_bind_double(statement, 9, lastSeenAt.timeIntervalSince1970)
        } else {
            sqlite3_bind_null(statement, 9)
        }
        if let nextDueAt {
            sqlite3_bind_double(statement, 10, nextDueAt.timeIntervalSince1970)
        } else {
            sqlite3_bind_null(statement, 10)
        }
        sqlite3_bind_text(statement, 11, state, -1, sqliteTransient)
        sqlite3_bind_text(statement, 12, dueReason, -1, sqliteTransient)
        sqlite3_bind_double(statement, 13, Date.now.timeIntervalSince1970)
        sqlite3_step(statement)
    }

    func saveQuizMemory(
        quizID: UUID,
        sourceID: UUID?,
        title: String,
        selectedFocus: String?,
        reason: String,
        targetConcepts: String,
        avoidedConcepts: String,
        questionMix: String,
        modelName: String,
        promptVersion: String
    ) {
        let sql = """
        INSERT OR REPLACE INTO quiz_memory (
            quiz_id, source_id, title, selected_focus, reason, target_concepts,
            avoided_concepts, question_mix, model_name, prompt_version, created_at
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            return
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, quizID.uuidString, -1, sqliteTransient)
        bindOptionalText(statement, index: 2, value: sourceID?.uuidString)
        sqlite3_bind_text(statement, 3, title, -1, sqliteTransient)
        bindOptionalText(statement, index: 4, value: selectedFocus)
        sqlite3_bind_text(statement, 5, reason, -1, sqliteTransient)
        sqlite3_bind_text(statement, 6, targetConcepts, -1, sqliteTransient)
        sqlite3_bind_text(statement, 7, avoidedConcepts, -1, sqliteTransient)
        sqlite3_bind_text(statement, 8, questionMix, -1, sqliteTransient)
        sqlite3_bind_text(statement, 9, modelName, -1, sqliteTransient)
        sqlite3_bind_text(statement, 10, promptVersion, -1, sqliteTransient)
        sqlite3_bind_double(statement, 11, Date.now.timeIntervalSince1970)
        sqlite3_step(statement)
    }

    func saveAnswerEvaluation(
        attemptID: UUID,
        questionID: UUID,
        sourceID: UUID?,
        localScore: Double,
        modelScore: Double?,
        finalScore: Double,
        grader: String,
        modelName: String,
        latencyMS: Int?,
        reason: String
    ) {
        let sql = """
        INSERT OR REPLACE INTO answer_evaluations (
            attempt_id, question_id, source_id, local_score, model_score, final_score,
            grader, model_name, latency_ms, reason, created_at
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            return
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, attemptID.uuidString, -1, sqliteTransient)
        sqlite3_bind_text(statement, 2, questionID.uuidString, -1, sqliteTransient)
        bindOptionalText(statement, index: 3, value: sourceID?.uuidString)
        sqlite3_bind_double(statement, 4, localScore)
        if let modelScore {
            sqlite3_bind_double(statement, 5, modelScore)
        } else {
            sqlite3_bind_null(statement, 5)
        }
        sqlite3_bind_double(statement, 6, finalScore)
        sqlite3_bind_text(statement, 7, grader, -1, sqliteTransient)
        sqlite3_bind_text(statement, 8, modelName, -1, sqliteTransient)
        if let latencyMS {
            sqlite3_bind_int(statement, 9, Int32(latencyMS))
        } else {
            sqlite3_bind_null(statement, 9)
        }
        sqlite3_bind_text(statement, 10, reason, -1, sqliteTransient)
        sqlite3_bind_double(statement, 11, Date.now.timeIntervalSince1970)
        sqlite3_step(statement)
    }

    func saveModelRun(
        taskType: String,
        modelName: String,
        promptVersion: String,
        inputChars: Int,
        outputChars: Int,
        success: Bool,
        latencyMS: Int,
        error: String? = nil,
        metadata: String = "{}"
    ) {
        let sql = """
        INSERT INTO model_runs (
            id, task_type, model_name, prompt_version, input_chars, output_chars,
            success, latency_ms, error, metadata, created_at
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            return
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, UUID().uuidString, -1, sqliteTransient)
        sqlite3_bind_text(statement, 2, taskType, -1, sqliteTransient)
        sqlite3_bind_text(statement, 3, modelName, -1, sqliteTransient)
        sqlite3_bind_text(statement, 4, promptVersion, -1, sqliteTransient)
        sqlite3_bind_int(statement, 5, Int32(inputChars))
        sqlite3_bind_int(statement, 6, Int32(outputChars))
        sqlite3_bind_int(statement, 7, success ? 1 : 0)
        sqlite3_bind_int(statement, 8, Int32(latencyMS))
        bindOptionalText(statement, index: 9, value: error)
        sqlite3_bind_text(statement, 10, metadata, -1, sqliteTransient)
        sqlite3_bind_double(statement, 11, Date.now.timeIntervalSince1970)
        sqlite3_step(statement)
    }

    func replaceSuggestions(_ suggestions: [LearningSuggestion]) {
        sqlite3_exec(database, "DELETE FROM learning_suggestions", nil, nil, nil)
        suggestions.forEach(saveSuggestion)
    }

    func replaceTopics(for sourceID: UUID, topics: [LearningTopic]) {
        executeDelete("DELETE FROM learning_topics WHERE source_id = ?", id: sourceID.uuidString)
        topics.forEach(save)
    }

    func replaceSegments(for sourceID: UUID, segments: [LearningSegment]) {
        executeDelete("DELETE FROM learning_segments WHERE source_id = ?", id: sourceID.uuidString)
        segments.forEach(save)
    }

    func replaceQuestions(for sourceID: UUID, questions: [LearningQuestion]) {
        executeDelete("DELETE FROM learning_questions WHERE source_id = ?", id: sourceID.uuidString)
        questions.forEach(save)
    }

    func replaceAssignments(_ assignments: [JourneyAssignment]) {
        sqlite3_exec(database, "DELETE FROM journey_assignments", nil, nil, nil)
        assignments.forEach(save)
    }

    func completeAssignment(id: UUID, completedAt: Date = .now) {
        let sql = """
        UPDATE journey_assignments
        SET status = ?, completed_at = ?
        WHERE id = ?
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            return
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, JourneyAssignment.Status.completed.rawValue, -1, sqliteTransient)
        sqlite3_bind_double(statement, 2, completedAt.timeIntervalSince1970)
        sqlite3_bind_text(statement, 3, id.uuidString, -1, sqliteTransient)
        sqlite3_step(statement)
    }

    func deleteAll() {
        sqlite3_exec(database, "DELETE FROM messages", nil, nil, nil)
    }

    private func saveSuggestion(_ suggestion: LearningSuggestion) {
        let sql = """
        INSERT OR REPLACE INTO learning_suggestions (id, action, title, detail, priority, created_at)
        VALUES (?, ?, ?, ?, ?, ?)
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            return
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, suggestion.id.uuidString, -1, sqliteTransient)
        sqlite3_bind_text(statement, 2, suggestion.action.rawValue, -1, sqliteTransient)
        sqlite3_bind_text(statement, 3, suggestion.title, -1, sqliteTransient)
        sqlite3_bind_text(statement, 4, suggestion.detail, -1, sqliteTransient)
        sqlite3_bind_int(statement, 5, Int32(suggestion.priority))
        sqlite3_bind_double(statement, 6, suggestion.createdAt.timeIntervalSince1970)
        sqlite3_step(statement)
    }

    private func executeDelete(_ sql: String, id: String) {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            return
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, id, -1, sqliteTransient)
        sqlite3_step(statement)
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
            summary TEXT NOT NULL DEFAULT '',
            quiz_build_state TEXT NOT NULL DEFAULT 'idle',
            quiz_build_detail TEXT NOT NULL DEFAULT '',
            quiz_build_error TEXT NOT NULL DEFAULT '',
            quiz_build_target_count INTEGER NOT NULL DEFAULT 0,
            quiz_build_saved_count INTEGER NOT NULL DEFAULT 0,
            quiz_build_updated_at REAL,
            created_at REAL NOT NULL
        );

        CREATE INDEX IF NOT EXISTS idx_study_sources_created_at
        ON study_sources(created_at);

        CREATE TABLE IF NOT EXISTS quiz_build_attempts (
            id TEXT PRIMARY KEY NOT NULL,
            source_id TEXT NOT NULL,
            state TEXT NOT NULL,
            stage TEXT NOT NULL DEFAULT '',
            target_count INTEGER NOT NULL DEFAULT 0,
            saved_count INTEGER NOT NULL DEFAULT 0,
            detail TEXT NOT NULL DEFAULT '',
            error TEXT NOT NULL DEFAULT '',
            created_at REAL NOT NULL
        );

        CREATE INDEX IF NOT EXISTS idx_quiz_build_attempts_source_created
        ON quiz_build_attempts(source_id, created_at);

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

        CREATE TABLE IF NOT EXISTS xp_events (
            id TEXT PRIMARY KEY NOT NULL,
            action TEXT NOT NULL,
            points INTEGER NOT NULL,
            reason TEXT NOT NULL,
            created_at REAL NOT NULL
        );

        CREATE INDEX IF NOT EXISTS idx_xp_events_created_at
        ON xp_events(created_at);

        CREATE TABLE IF NOT EXISTS learning_suggestions (
            id TEXT PRIMARY KEY NOT NULL,
            action TEXT NOT NULL,
            title TEXT NOT NULL,
            detail TEXT NOT NULL,
            priority INTEGER NOT NULL,
            created_at REAL NOT NULL
        );

        CREATE INDEX IF NOT EXISTS idx_learning_suggestions_priority
        ON learning_suggestions(priority);

        CREATE TABLE IF NOT EXISTS learning_topics (
            id TEXT PRIMARY KEY NOT NULL,
            source_id TEXT,
            title TEXT NOT NULL,
            summary TEXT NOT NULL,
            mastery REAL NOT NULL DEFAULT 0,
            created_at REAL NOT NULL
        );

        CREATE INDEX IF NOT EXISTS idx_learning_topics_source_id
        ON learning_topics(source_id);

        CREATE INDEX IF NOT EXISTS idx_learning_topics_created_at
        ON learning_topics(created_at);

        CREATE TABLE IF NOT EXISTS learning_segments (
            id TEXT PRIMARY KEY NOT NULL,
            source_id TEXT,
            topic_id TEXT,
            topic_title TEXT NOT NULL,
            subtopic_title TEXT NOT NULL,
            text TEXT NOT NULL,
            evidence TEXT NOT NULL DEFAULT '',
            importance REAL NOT NULL DEFAULT 1,
            difficulty REAL NOT NULL DEFAULT 1,
            created_at REAL NOT NULL
        );

        CREATE INDEX IF NOT EXISTS idx_learning_segments_source_id
        ON learning_segments(source_id);

        CREATE INDEX IF NOT EXISTS idx_learning_segments_topic_id
        ON learning_segments(topic_id);

        CREATE TABLE IF NOT EXISTS learning_questions (
            id TEXT PRIMARY KEY NOT NULL,
            source_id TEXT,
            topic_id TEXT,
            segment_id TEXT,
            topic_title TEXT NOT NULL,
            subtopic_title TEXT NOT NULL,
            question_type TEXT NOT NULL,
            prompt TEXT NOT NULL,
            answer TEXT NOT NULL,
            accepted_answers TEXT NOT NULL DEFAULT '',
            grading_rubric TEXT NOT NULL DEFAULT '',
            choices TEXT NOT NULL DEFAULT '',
            importance REAL NOT NULL DEFAULT 1,
            difficulty REAL NOT NULL DEFAULT 1,
            created_at REAL NOT NULL
        );

        CREATE INDEX IF NOT EXISTS idx_learning_questions_source_id
        ON learning_questions(source_id);

        CREATE INDEX IF NOT EXISTS idx_learning_questions_topic_id
        ON learning_questions(topic_id);

        CREATE INDEX IF NOT EXISTS idx_learning_questions_segment_id
        ON learning_questions(segment_id);

        CREATE TABLE IF NOT EXISTS question_attempts (
            id TEXT PRIMARY KEY NOT NULL,
            question_id TEXT NOT NULL,
            source_id TEXT,
            topic_title TEXT,
            subtopic_title TEXT,
            question_type TEXT,
            prompt TEXT,
            answer TEXT,
            response TEXT NOT NULL,
            score REAL NOT NULL,
            feedback TEXT,
            matched_ideas TEXT NOT NULL DEFAULT '',
            missing_ideas TEXT NOT NULL DEFAULT '',
            created_at REAL NOT NULL
        );

        CREATE INDEX IF NOT EXISTS idx_question_attempts_question_id
        ON question_attempts(question_id);

        CREATE TABLE IF NOT EXISTS journey_assignments (
            id TEXT PRIMARY KEY NOT NULL,
            segment_id TEXT,
            question_id TEXT,
            type TEXT NOT NULL,
            reason TEXT NOT NULL,
            priority REAL NOT NULL,
            due_at REAL NOT NULL,
            status TEXT NOT NULL DEFAULT 'pending',
            created_at REAL NOT NULL,
            completed_at REAL
        );

        CREATE INDEX IF NOT EXISTS idx_journey_assignments_status_due
        ON journey_assignments(status, due_at);

        CREATE INDEX IF NOT EXISTS idx_journey_assignments_question_id
        ON journey_assignments(question_id);

        CREATE TABLE IF NOT EXISTS quiz_sessions (
            id TEXT PRIMARY KEY NOT NULL,
            source_id TEXT,
            title TEXT NOT NULL,
            score REAL NOT NULL,
            question_count INTEGER NOT NULL,
            got_count INTEGER NOT NULL,
            close_count INTEGER NOT NULL,
            review_count INTEGER NOT NULL,
            created_at REAL NOT NULL
        );

        CREATE INDEX IF NOT EXISTS idx_quiz_sessions_source_created
        ON quiz_sessions(source_id, created_at);

        CREATE TABLE IF NOT EXISTS learning_events (
            id TEXT PRIMARY KEY NOT NULL,
            kind TEXT NOT NULL,
            source_id TEXT,
            question_id TEXT,
            quiz_id TEXT,
            concept_signature TEXT,
            detail TEXT NOT NULL DEFAULT '',
            metadata TEXT NOT NULL DEFAULT '{}',
            created_at REAL NOT NULL
        );

        CREATE INDEX IF NOT EXISTS idx_learning_events_kind_created
        ON learning_events(kind, created_at);

        CREATE INDEX IF NOT EXISTS idx_learning_events_source_created
        ON learning_events(source_id, created_at);

        CREATE TABLE IF NOT EXISTS question_memory (
            question_id TEXT PRIMARY KEY NOT NULL,
            source_id TEXT,
            concept_signature TEXT NOT NULL,
            assessment_angle TEXT NOT NULL,
            generation_source TEXT NOT NULL DEFAULT '',
            quality_flags TEXT NOT NULL DEFAULT '',
            latest_score REAL,
            attempt_count INTEGER NOT NULL DEFAULT 0,
            last_seen_at REAL,
            status TEXT NOT NULL DEFAULT 'untested',
            updated_at REAL NOT NULL
        );

        CREATE INDEX IF NOT EXISTS idx_question_memory_source_concept
        ON question_memory(source_id, concept_signature);

        CREATE TABLE IF NOT EXISTS concept_memory (
            source_id TEXT NOT NULL DEFAULT 'global',
            concept_signature TEXT NOT NULL,
            topic_title TEXT NOT NULL,
            subtopic_title TEXT NOT NULL,
            assessment_angle TEXT NOT NULL,
            latest_score REAL,
            average_score REAL,
            attempt_count INTEGER NOT NULL DEFAULT 0,
            last_seen_at REAL,
            next_due_at REAL,
            state TEXT NOT NULL DEFAULT 'untested',
            due_reason TEXT NOT NULL DEFAULT '',
            updated_at REAL NOT NULL,
            PRIMARY KEY (source_id, concept_signature)
        );

        CREATE INDEX IF NOT EXISTS idx_concept_memory_state_due
        ON concept_memory(state, next_due_at);

        CREATE TABLE IF NOT EXISTS quiz_memory (
            quiz_id TEXT PRIMARY KEY NOT NULL,
            source_id TEXT,
            title TEXT NOT NULL,
            selected_focus TEXT,
            reason TEXT NOT NULL DEFAULT '',
            target_concepts TEXT NOT NULL DEFAULT '[]',
            avoided_concepts TEXT NOT NULL DEFAULT '[]',
            question_mix TEXT NOT NULL DEFAULT '{}',
            model_name TEXT NOT NULL DEFAULT '',
            prompt_version TEXT NOT NULL DEFAULT '',
            created_at REAL NOT NULL
        );

        CREATE INDEX IF NOT EXISTS idx_quiz_memory_source_created
        ON quiz_memory(source_id, created_at);

        CREATE TABLE IF NOT EXISTS answer_evaluations (
            attempt_id TEXT PRIMARY KEY NOT NULL,
            question_id TEXT NOT NULL,
            source_id TEXT,
            local_score REAL NOT NULL,
            model_score REAL,
            final_score REAL NOT NULL,
            grader TEXT NOT NULL,
            model_name TEXT NOT NULL DEFAULT '',
            latency_ms INTEGER,
            reason TEXT NOT NULL DEFAULT '',
            created_at REAL NOT NULL
        );

        CREATE INDEX IF NOT EXISTS idx_answer_evaluations_question
        ON answer_evaluations(question_id, created_at);

        CREATE TABLE IF NOT EXISTS model_runs (
            id TEXT PRIMARY KEY NOT NULL,
            task_type TEXT NOT NULL,
            model_name TEXT NOT NULL,
            prompt_version TEXT NOT NULL DEFAULT '',
            input_chars INTEGER NOT NULL DEFAULT 0,
            output_chars INTEGER NOT NULL DEFAULT 0,
            success INTEGER NOT NULL DEFAULT 0,
            latency_ms INTEGER NOT NULL DEFAULT 0,
            error TEXT,
            metadata TEXT NOT NULL DEFAULT '{}',
            created_at REAL NOT NULL
        );

        CREATE INDEX IF NOT EXISTS idx_model_runs_task_created
        ON model_runs(task_type, created_at);
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
        sqlite3_exec(database, "ALTER TABLE study_sources ADD COLUMN summary TEXT NOT NULL DEFAULT ''", nil, nil, nil)
        sqlite3_exec(database, "ALTER TABLE study_sources ADD COLUMN quiz_build_state TEXT NOT NULL DEFAULT 'idle'", nil, nil, nil)
        sqlite3_exec(database, "ALTER TABLE study_sources ADD COLUMN quiz_build_detail TEXT NOT NULL DEFAULT ''", nil, nil, nil)
        sqlite3_exec(database, "ALTER TABLE study_sources ADD COLUMN quiz_build_error TEXT NOT NULL DEFAULT ''", nil, nil, nil)
        sqlite3_exec(database, "ALTER TABLE study_sources ADD COLUMN quiz_build_target_count INTEGER NOT NULL DEFAULT 0", nil, nil, nil)
        sqlite3_exec(database, "ALTER TABLE study_sources ADD COLUMN quiz_build_saved_count INTEGER NOT NULL DEFAULT 0", nil, nil, nil)
        sqlite3_exec(database, "ALTER TABLE study_sources ADD COLUMN quiz_build_updated_at REAL", nil, nil, nil)
        sqlite3_exec(database, "ALTER TABLE learning_questions ADD COLUMN topic_id TEXT", nil, nil, nil)
        sqlite3_exec(database, "ALTER TABLE learning_questions ADD COLUMN segment_id TEXT", nil, nil, nil)
        sqlite3_exec(database, "ALTER TABLE learning_questions ADD COLUMN accepted_answers TEXT NOT NULL DEFAULT ''", nil, nil, nil)
        sqlite3_exec(database, "ALTER TABLE learning_questions ADD COLUMN grading_rubric TEXT NOT NULL DEFAULT ''", nil, nil, nil)
        sqlite3_exec(database, "ALTER TABLE question_attempts ADD COLUMN source_id TEXT", nil, nil, nil)
        sqlite3_exec(database, "ALTER TABLE question_attempts ADD COLUMN topic_title TEXT", nil, nil, nil)
        sqlite3_exec(database, "ALTER TABLE question_attempts ADD COLUMN subtopic_title TEXT", nil, nil, nil)
        sqlite3_exec(database, "ALTER TABLE question_attempts ADD COLUMN question_type TEXT", nil, nil, nil)
        sqlite3_exec(database, "ALTER TABLE question_attempts ADD COLUMN prompt TEXT", nil, nil, nil)
        sqlite3_exec(database, "ALTER TABLE question_attempts ADD COLUMN answer TEXT", nil, nil, nil)
        sqlite3_exec(database, "ALTER TABLE question_attempts ADD COLUMN feedback TEXT", nil, nil, nil)
        sqlite3_exec(database, "ALTER TABLE question_attempts ADD COLUMN matched_ideas TEXT NOT NULL DEFAULT ''", nil, nil, nil)
        sqlite3_exec(database, "ALTER TABLE question_attempts ADD COLUMN missing_ideas TEXT NOT NULL DEFAULT ''", nil, nil, nil)
        sqlite3_exec(database, "ALTER TABLE quiz_sessions ADD COLUMN attempt_ids TEXT NOT NULL DEFAULT ''", nil, nil, nil)
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
        return baseURL.appending(path: "QuizLoop", directoryHint: .isDirectory).appending(path: "conversations.sqlite")
    }

    private static func optionalString(_ statement: OpaquePointer?, column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL,
              let text = sqlite3_column_text(statement, column)
        else {
            return nil
        }

        let value = String(cString: text)
        return value.isEmpty ? nil : value
    }

    private static func encodeStringArray(_ values: [String]) -> String {
        guard values.isEmpty == false,
              let data = try? JSONEncoder().encode(values),
              let encoded = String(data: data, encoding: .utf8)
        else {
            return ""
        }

        return encoded
    }

    private static func decodeStringArray(_ value: String?) -> [String] {
        guard let value,
              let data = value.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String].self, from: data)
        else {
            return []
        }

        return decoded
    }

    private static func decodeUUIDArray(_ value: String?) -> [UUID] {
        value?
            .components(separatedBy: .newlines)
            .compactMap { UUID(uuidString: $0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? []
    }

    private func bindOptionalText(_ statement: OpaquePointer?, index: Int32, value: String?) {
        if let value, value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            sqlite3_bind_text(statement, index, value, -1, sqliteTransient)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private static func defaultQuizBuildState(
        status: StudySource.ProcessingStatus,
        savedCount: Int
    ) -> StudySource.QuizBuildState {
        if savedCount > 0 {
            return .ready
        }

        switch status {
        case .ready:
            return .idle
        case .processing:
            return .building
        case .failed:
            return .failed
        }
    }
}

private extension TutorTurn.Speaker {
    init?(databaseValue: String) {
        switch databaseValue {
        case "learner":
            self = .learner
        case "quizLoop", "waves":
            self = .quizLoop
        default:
            return nil
        }
    }

    var databaseValue: String {
        switch self {
        case .learner:
            "learner"
        case .quizLoop:
            "quizLoop"
        }
    }
}
