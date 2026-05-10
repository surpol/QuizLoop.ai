import Foundation

struct Note: Identifiable, Equatable {
    enum SourceType: String, Equatable {
        case text
        case transcript
        case pdf
        case web
        case audio
        case video
    }

    enum ProcessingStatus: String, Equatable {
        case unprocessed
        case processing
        case ready
        case failed
    }

    let id: UUID
    var title: String
    var rawText: String
    var sourceType: SourceType
    var status: ProcessingStatus
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        title: String,
        rawText: String,
        sourceType: SourceType = .text,
        status: ProcessingStatus = .unprocessed,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.title = title
        self.rawText = rawText
        self.sourceType = sourceType
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

struct Topic: Identifiable, Equatable {
    let id: UUID
    let noteID: UUID
    var title: String
    var summary: String
    var importance: Double
    var difficulty: Double
    var exposurePercentage: Double
    var masteryPercentage: Double
    var createdAt: Date

    init(
        id: UUID = UUID(),
        noteID: UUID,
        title: String,
        summary: String,
        importance: Double,
        difficulty: Double,
        exposurePercentage: Double = 0,
        masteryPercentage: Double = 0,
        createdAt: Date = .now
    ) {
        self.id = id
        self.noteID = noteID
        self.title = title
        self.summary = summary
        self.importance = importance
        self.difficulty = difficulty
        self.exposurePercentage = exposurePercentage
        self.masteryPercentage = masteryPercentage
        self.createdAt = createdAt
    }
}

struct EvidenceSegment: Identifiable, Equatable {
    let id: UUID
    let noteID: UUID
    let topicID: UUID
    var text: String
    var startOffset: Int
    var endOffset: Int
    var importance: Double
    var difficulty: Double
    var exposureCount: Int
    var lastSeenAt: Date?

    init(
        id: UUID = UUID(),
        noteID: UUID,
        topicID: UUID,
        text: String,
        startOffset: Int,
        endOffset: Int,
        importance: Double,
        difficulty: Double,
        exposureCount: Int = 0,
        lastSeenAt: Date? = nil
    ) {
        self.id = id
        self.noteID = noteID
        self.topicID = topicID
        self.text = text
        self.startOffset = startOffset
        self.endOffset = endOffset
        self.importance = importance
        self.difficulty = difficulty
        self.exposureCount = exposureCount
        self.lastSeenAt = lastSeenAt
    }
}

struct Check: Identifiable, Equatable {
    enum CheckType: String, Equatable {
        case multipleChoice
        case fillBlank
        case shortAnswer
        case misconception
        case ordering
    }

    let id: UUID
    let noteID: UUID
    let topicID: UUID
    let evidenceSegmentID: UUID
    var type: CheckType
    var prompt: String
    var answer: String
    var choices: [String]
    var difficulty: Double
    var createdAt: Date

    init(
        id: UUID = UUID(),
        noteID: UUID,
        topicID: UUID,
        evidenceSegmentID: UUID,
        type: CheckType,
        prompt: String,
        answer: String,
        choices: [String] = [],
        difficulty: Double,
        createdAt: Date = .now
    ) {
        self.id = id
        self.noteID = noteID
        self.topicID = topicID
        self.evidenceSegmentID = evidenceSegmentID
        self.type = type
        self.prompt = prompt
        self.answer = answer
        self.choices = choices
        self.difficulty = difficulty
        self.createdAt = createdAt
    }
}

struct Attempt: Identifiable, Equatable {
    let id: UUID
    let noteID: UUID
    let topicID: UUID
    let evidenceSegmentID: UUID
    let checkID: UUID
    var response: String
    var score: Double
    var feedback: String
    var createdAt: Date

    init(
        id: UUID = UUID(),
        noteID: UUID,
        topicID: UUID,
        evidenceSegmentID: UUID,
        checkID: UUID,
        response: String,
        score: Double,
        feedback: String,
        createdAt: Date = .now
    ) {
        self.id = id
        self.noteID = noteID
        self.topicID = topicID
        self.evidenceSegmentID = evidenceSegmentID
        self.checkID = checkID
        self.response = response
        self.score = score
        self.feedback = feedback
        self.createdAt = createdAt
    }
}

struct JourneyItem: Identifiable, Equatable {
    enum ItemType: String, Equatable {
        case introduce
        case test
        case review
        case strengthen
        case mixedReview
    }

    enum Status: String, Equatable {
        case pending
        case completed
        case skipped
    }

    let id: UUID
    let noteID: UUID
    let topicID: UUID
    let evidenceSegmentID: UUID?
    let checkID: UUID?
    var type: ItemType
    var reason: String
    var priority: Double
    var dueAt: Date
    var status: Status
    var createdAt: Date
    var completedAt: Date?

    init(
        id: UUID = UUID(),
        noteID: UUID,
        topicID: UUID,
        evidenceSegmentID: UUID? = nil,
        checkID: UUID? = nil,
        type: ItemType,
        reason: String,
        priority: Double,
        dueAt: Date = .now,
        status: Status = .pending,
        createdAt: Date = .now,
        completedAt: Date? = nil
    ) {
        self.id = id
        self.noteID = noteID
        self.topicID = topicID
        self.evidenceSegmentID = evidenceSegmentID
        self.checkID = checkID
        self.type = type
        self.reason = reason
        self.priority = priority
        self.dueAt = dueAt
        self.status = status
        self.createdAt = createdAt
        self.completedAt = completedAt
    }
}

struct ProcessedNote: Equatable {
    let noteID: UUID
    var topics: [Topic]
    var evidenceSegments: [EvidenceSegment]
    var checks: [Check]
}

struct ValidationResult: Equatable {
    var acceptedTopics: [Topic]
    var acceptedEvidenceSegments: [EvidenceSegment]
    var acceptedChecks: [Check]
    var rejectedReasons: [String]

    var isValid: Bool {
        rejectedReasons.isEmpty
            && acceptedTopics.isEmpty == false
            && acceptedEvidenceSegments.isEmpty == false
            && acceptedChecks.isEmpty == false
    }
}

struct AttemptScore: Equatable {
    var score: Double
    var feedback: String
    var requiresAIReview: Bool
}
