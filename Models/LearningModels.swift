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
    let id = UUID()
    let title: String
    let summary: String
    let mastery: Double
}

struct LearningInsight: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let detail: String
    let systemImage: String
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
