import Foundation

struct TutorTurn: Identifiable, Equatable {
    enum Speaker {
        case learner
        case waves
    }

    let id: UUID
    let speaker: Speaker
    let text: String
    let sourceTitles: [String]
    let createdAt: Date

    init(id: UUID = UUID(), speaker: Speaker, text: String, sourceTitles: [String] = [], createdAt: Date) {
        self.id = id
        self.speaker = speaker
        self.text = text
        self.sourceTitles = sourceTitles
        self.createdAt = createdAt
    }
}

struct LearningTopic: Identifiable, Equatable {
    let id: UUID
    let sourceID: UUID?
    let title: String
    let summary: String
    let mastery: Double
    let createdAt: Date

    init(
        id: UUID = UUID(),
        sourceID: UUID? = nil,
        title: String,
        summary: String,
        mastery: Double = 0,
        createdAt: Date = .now
    ) {
        self.id = id
        self.sourceID = sourceID
        self.title = title
        self.summary = summary
        self.mastery = mastery
        self.createdAt = createdAt
    }
}

struct LearningInsight: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let detail: String
    let systemImage: String
}

enum LearningAction: String, CaseIterable {
    case teach
    case test
    case makeCards
    case review

    var title: String {
        switch self {
        case .teach:
            "Teach"
        case .test:
            "Test"
        case .makeCards:
            "Cards"
        case .review:
            "Review"
        }
    }

    var detail: String {
        switch self {
        case .teach:
            "Explain simply"
        case .test:
            "Ask one question"
        case .makeCards:
            "Save practice"
        case .review:
            "Find gaps"
        }
    }

    var systemImage: String {
        switch self {
        case .teach:
            "text.book.closed"
        case .test:
            "questionmark.circle"
        case .makeCards:
            "rectangle.stack"
        case .review:
            "checklist"
        }
    }

    var baseXP: Int {
        switch self {
        case .teach:
            5
        case .test:
            10
        case .makeCards:
            8
        case .review:
            12
        }
    }
}

struct XPEvent: Identifiable, Equatable {
    let id: UUID
    let action: LearningAction
    let points: Int
    let reason: String
    let createdAt: Date

    init(id: UUID = UUID(), action: LearningAction, points: Int? = nil, reason: String, createdAt: Date = .now) {
        self.id = id
        self.action = action
        self.points = points ?? action.baseXP
        self.reason = reason
        self.createdAt = createdAt
    }
}

struct LearningSuggestion: Identifiable, Equatable {
    let id: UUID
    let action: LearningAction
    let title: String
    let detail: String
    let priority: Int
    let createdAt: Date

    init(
        id: UUID = UUID(),
        action: LearningAction,
        title: String,
        detail: String,
        priority: Int,
        createdAt: Date = .now
    ) {
        self.id = id
        self.action = action
        self.title = title
        self.detail = detail
        self.priority = priority
        self.createdAt = createdAt
    }
}

struct LearningSegment: Identifiable, Equatable {
    let id: UUID
    let sourceID: UUID?
    let topicID: UUID?
    let topicTitle: String
    let subtopicTitle: String
    let text: String
    let evidence: String
    let importance: Double
    let difficulty: Double
    let createdAt: Date

    init(
        id: UUID = UUID(),
        sourceID: UUID? = nil,
        topicID: UUID? = nil,
        topicTitle: String,
        subtopicTitle: String,
        text: String,
        evidence: String,
        importance: Double = 1,
        difficulty: Double = 1,
        createdAt: Date = .now
    ) {
        self.id = id
        self.sourceID = sourceID
        self.topicID = topicID
        self.topicTitle = topicTitle
        self.subtopicTitle = subtopicTitle
        self.text = text
        self.evidence = evidence
        self.importance = importance
        self.difficulty = difficulty
        self.createdAt = createdAt
    }
}

struct LearningQuestion: Identifiable, Equatable {
    enum QuestionType: String, CaseIterable {
        case multipleChoice
        case fillBlank
        case shortAnswer
        case flashcard

        var title: String {
            switch self {
            case .multipleChoice:
                "Multiple Choice"
            case .fillBlank:
                "Fill Blank"
            case .shortAnswer:
                "Short Answer"
            case .flashcard:
                "Flashcard"
            }
        }

        var weight: Double {
            switch self {
            case .multipleChoice:
                0.6
            case .fillBlank:
                1.4
            case .shortAnswer:
                2.4
            case .flashcard:
                1.25
            }
        }
    }

    let id: UUID
    let sourceID: UUID?
    let topicID: UUID?
    let segmentID: UUID?
    let topicTitle: String
    let subtopicTitle: String
    let type: QuestionType
    let prompt: String
    let answer: String
    let choices: [String]
    let importance: Double
    let difficulty: Double
    let createdAt: Date

    init(
        id: UUID = UUID(),
        sourceID: UUID? = nil,
        topicID: UUID? = nil,
        segmentID: UUID? = nil,
        topicTitle: String,
        subtopicTitle: String,
        type: QuestionType,
        prompt: String,
        answer: String,
        choices: [String] = [],
        importance: Double = 1,
        difficulty: Double = 1,
        createdAt: Date = .now
    ) {
        self.id = id
        self.sourceID = sourceID
        self.topicID = topicID
        self.segmentID = segmentID
        self.topicTitle = topicTitle
        self.subtopicTitle = subtopicTitle
        self.type = type
        self.prompt = prompt
        self.answer = answer
        self.choices = choices
        self.importance = importance
        self.difficulty = difficulty
        self.createdAt = createdAt
    }
}

struct JourneyAssignment: Identifiable, Equatable {
    enum AssignmentType: String {
        case learn
        case review
        case strengthen

        var title: String {
            switch self {
            case .learn:
                "Learn"
            case .review:
                "Review"
            case .strengthen:
                "Strengthen"
            }
        }
    }

    enum Status: String {
        case pending
        case completed
        case skipped
    }

    let id: UUID
    let segmentID: UUID?
    let questionID: UUID?
    let type: AssignmentType
    let reason: String
    let priority: Double
    let dueAt: Date
    let status: Status
    let createdAt: Date
    let completedAt: Date?

    init(
        id: UUID = UUID(),
        segmentID: UUID? = nil,
        questionID: UUID? = nil,
        type: AssignmentType,
        reason: String,
        priority: Double,
        dueAt: Date = .now,
        status: Status = .pending,
        createdAt: Date = .now,
        completedAt: Date? = nil
    ) {
        self.id = id
        self.segmentID = segmentID
        self.questionID = questionID
        self.type = type
        self.reason = reason
        self.priority = priority
        self.dueAt = dueAt
        self.status = status
        self.createdAt = createdAt
        self.completedAt = completedAt
    }
}

struct QuestionAttempt: Identifiable, Equatable {
    let id: UUID
    let questionID: UUID
    let response: String
    let score: Double
    let createdAt: Date

    init(id: UUID = UUID(), questionID: UUID, response: String, score: Double, createdAt: Date = .now) {
        self.id = id
        self.questionID = questionID
        self.response = response
        self.score = score
        self.createdAt = createdAt
    }
}

struct MasterySnapshot: Equatable {
    let testedCount: Int
    let totalCount: Int
    let weightedMastery: Double
    let dimensions: [UnderstandingDimension]

    var title: String {
        if totalCount == 0 {
            return "No Map"
        }

        switch weightedMastery {
        case 0:
            return "Unstarted"
        case ..<0.4:
            return "Learning"
        case ..<0.75:
            return "Getting Strong"
        default:
            return "Mastered"
        }
    }
}

struct LearningGrowthEvidence: Equatable {
    enum Direction: String, Equatable {
        case rising
        case steady
        case slipping
        case waiting
    }

    let direction: Direction
    let points: [Double]
    let recentStrongCount: Int
    let recentCloseCount: Int
    let recentReviewCount: Int
    let evidenceText: String
}

struct QuizHistoryEntry: Identifiable, Equatable {
    let id: UUID
    let sourceID: UUID?
    let title: String
    let score: Double
    let questionCount: Int
    let gotCount: Int
    let closeCount: Int
    let reviewCount: Int
    let createdAt: Date

    init(
        id: UUID = UUID(),
        sourceID: UUID?,
        title: String,
        score: Double,
        questionCount: Int,
        gotCount: Int,
        closeCount: Int,
        reviewCount: Int,
        createdAt: Date = .now
    ) {
        self.id = id
        self.sourceID = sourceID
        self.title = title
        self.score = min(max(score, 0), 1)
        self.questionCount = questionCount
        self.gotCount = gotCount
        self.closeCount = closeCount
        self.reviewCount = reviewCount
        self.createdAt = createdAt
    }
}

struct QuizProgressEvidence: Equatable {
    enum Direction: Equatable {
        case rising
        case steady
        case slipping
        case waiting
    }

    let latest: QuizHistoryEntry?
    let previous: QuizHistoryEntry?
    let points: [Double]

    var direction: Direction {
        guard let latest, let previous else {
            return latest == nil ? .waiting : .steady
        }

        let delta = latest.score - previous.score
        if delta > 0.03 {
            return .rising
        }
        if delta < -0.03 {
            return .slipping
        }
        return .steady
    }
}

struct UnderstandingDimension: Identifiable, Equatable {
    let id: String
    let title: String
    let value: Double

    init(id: String, title: String, value: Double) {
        self.id = id
        self.title = title
        self.value = min(max(value, 0), 1)
    }
}

struct LearningCoverageMap: Equatable {
    let root: LearningCoverageNode

    var topics: [LearningCoverageNode] {
        root.children
    }
}

struct LearningCoverageNode: Identifiable, Equatable {
    enum Level: String {
        case allNotes
        case topic
        case subtopic
    }

    let id: String
    let level: Level
    let title: String
    let summary: String
    let snapshot: MasterySnapshot
    let children: [LearningCoverageNode]
}

struct SubtopicMastery: Identifiable, Equatable {
    let id: String
    let title: String
    let topicTitle: String
    let snapshot: MasterySnapshot
}

struct LearningExtraction: Codable, Equatable {
    let topics: [ExtractedTopic]
}

struct AnswerEvaluation: Codable, Equatable {
    let score: Double
    let reason: String?
}

struct ExtractedTopic: Codable, Equatable {
    let title: String
    let summary: String
    let subtopics: [ExtractedSubtopic]
}

struct ExtractedSubtopic: Codable, Equatable {
    let title: String
    let importance: Double
    let segments: [ExtractedSegment]?
    let questions: [ExtractedQuestion]?
}

struct ExtractedSegment: Codable, Equatable {
    let text: String
    let evidence: String?
    let importance: Double?
    let difficulty: Double?
    let questions: [ExtractedQuestion]
}

struct ExtractedQuestion: Codable, Equatable {
    let type: String
    let prompt: String
    let answer: String
    let choices: [String]?
    let difficulty: Double
}

struct StudySource: Identifiable, Equatable {
    enum SourceType: String {
        case notes
        case pastedText
        case pdf
        case audio
        case video
        case link

        var title: String {
            switch self {
            case .notes, .pastedText:
                "Notes"
            case .pdf:
                "PDF"
            case .audio:
                "Audio"
            case .video:
                "Video"
            case .link:
                "Link"
            }
        }

        var systemImage: String {
            switch self {
            case .notes, .pastedText:
                "doc.text"
            case .pdf:
                "doc.richtext"
            case .audio:
                "waveform"
            case .video:
                "play.rectangle"
            case .link:
                "link"
            }
        }
    }

    enum ProcessingStatus: String {
        case ready
        case processing
        case failed

        var title: String {
            switch self {
            case .ready:
                "Ready"
            case .processing:
                "Processing"
            case .failed:
                "Failed"
            }
        }
    }

    let id: UUID
    let title: String
    let type: SourceType
    let status: ProcessingStatus
    let text: String
    let createdAt: Date

    init(
        id: UUID = UUID(),
        title: String,
        type: SourceType = .notes,
        status: ProcessingStatus = .ready,
        text: String,
        createdAt: Date = .now
    ) {
        self.id = id
        self.title = title
        self.type = type
        self.status = status
        self.text = text
        self.createdAt = createdAt
    }
}

struct StudyFlashcard: Identifiable, Equatable {
    enum ReviewGrade {
        case again
        case hard
        case good
    }

    enum CardType: String {
        case definition
        case causeEffect
        case compareContrast
        case process
        case misconception
        case application
        case recall

        var title: String {
            switch self {
            case .definition:
                "Definition"
            case .causeEffect:
                "Cause"
            case .compareContrast:
                "Compare"
            case .process:
                "Process"
            case .misconception:
                "Mistake"
            case .application:
                "Apply"
            case .recall:
                "Recall"
            }
        }

        var systemImage: String {
            switch self {
            case .definition:
                "text.book.closed"
            case .causeEffect:
                "arrow.triangle.branch"
            case .compareContrast:
                "arrow.left.arrow.right"
            case .process:
                "list.number"
            case .misconception:
                "exclamationmark.triangle"
            case .application:
                "lightbulb"
            case .recall:
                "questionmark.circle"
            }
        }
    }

    let id: UUID
    let sourceID: UUID?
    let sourceTitle: String
    let deckTitle: String
    let topic: String
    let cardType: CardType
    let front: String
    let back: String
    let referenceText: String
    let createdAt: Date
    let dueAt: Date
    let confidence: Int

    init(
        id: UUID = UUID(),
        sourceID: UUID? = nil,
        sourceTitle: String,
        deckTitle: String? = nil,
        topic: String = "General",
        cardType: CardType = .recall,
        front: String,
        back: String,
        referenceText: String = "",
        createdAt: Date = .now,
        dueAt: Date = .now,
        confidence: Int = 0
    ) {
        self.id = id
        self.sourceID = sourceID
        self.sourceTitle = sourceTitle
        self.deckTitle = deckTitle ?? (topic == "General" ? sourceTitle : topic)
        self.topic = topic
        self.cardType = cardType
        self.front = front
        self.back = back
        self.referenceText = referenceText
        self.createdAt = createdAt
        self.dueAt = dueAt
        self.confidence = confidence
    }

    var isDue: Bool {
        dueAt <= .now
    }

    var isWeak: Bool {
        confidence < 0
    }

    func reviewed(_ grade: ReviewGrade) -> StudyFlashcard {
        let nextDueAt: Date
        let nextConfidence: Int

        switch grade {
        case .again:
            nextDueAt = .now
            nextConfidence = confidence - 1
        case .hard:
            nextDueAt = Calendar.current.date(byAdding: .day, value: 1, to: .now) ?? .now
            nextConfidence = max(confidence, 0)
        case .good:
            nextDueAt = Calendar.current.date(byAdding: .day, value: 3, to: .now) ?? .now
            nextConfidence = confidence + 1
        }

        return StudyFlashcard(
            id: id,
            sourceID: sourceID,
            sourceTitle: sourceTitle,
            deckTitle: deckTitle,
            topic: topic,
            cardType: cardType,
            front: front,
            back: back,
            referenceText: referenceText,
            createdAt: createdAt,
            dueAt: nextDueAt,
            confidence: nextConfidence
        )
    }
}

enum ModelReadiness: Equatable {
    case checking
    case ready
    case serverUnavailable
    case modelMissing(String)
    case deviceNotEligible
    case appleIntelligenceNotEnabled
    case appleModelNotReady

    var isReady: Bool {
        self == .ready
    }
}

struct ModelRuntimeConfiguration: Equatable {
    enum Mode: String, CaseIterable {
        case localServer
        case onDevice

        var title: String {
            switch self {
            case .localServer:
                "Local Server"
            case .onDevice:
                "On Device"
            }
        }
    }

    var mode: Mode
    var serverURLString: String
    var modelName: String

    var normalizedServerURLString: String {
        var value = serverURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasSuffix("/") {
            value.removeLast()
        }
        return value
    }

    var chatEndpoint: URL? {
        URL(string: normalizedServerURLString)?.appending(path: "api/chat")
    }

    var tagsEndpoint: URL? {
        URL(string: normalizedServerURLString)?.appending(path: "api/tags")
    }

    static let `default` = ModelRuntimeConfiguration(
        mode: .localServer,
        serverURLString: "http://127.0.0.1:11434",
        modelName: "gemma4:e2b"
    )
}
