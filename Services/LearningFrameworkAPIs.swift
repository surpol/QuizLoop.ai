import Foundation

protocol NoteRepository {
    func save(_ note: Note)
    func loadNotes() -> [Note]
    func loadNote(id: UUID) -> Note?
    func updateNoteStatus(id: UUID, status: Note.ProcessingStatus)
    func deleteNote(id: UUID)
}

protocol LearningMapRepository {
    func saveProcessedNote(_ processedNote: ProcessedNote)
    func loadTopics(noteID: UUID?) -> [Topic]
    func loadEvidenceSegments(topicID: UUID?) -> [EvidenceSegment]
    func loadChecks(topicID: UUID?) -> [Check]
}

protocol AttemptRepository {
    func save(_ attempt: Attempt)
    func loadAttempts(noteID: UUID?) -> [Attempt]
    func loadAttempts(checkID: UUID) -> [Attempt]
}

protocol JourneyRepository {
    func save(_ item: JourneyItem)
    func replaceJourneyItems(_ items: [JourneyItem], noteID: UUID?)
    func loadPendingJourneyItems(noteID: UUID?) -> [JourneyItem]
    func completeJourneyItem(id: UUID, completedAt: Date)
}

protocol NoteProcessor {
    func process(note: Note) async throws -> ProcessedNote
}

protocol EvidenceValidator {
    func validate(_ processedNote: ProcessedNote, against note: Note) -> ValidationResult
}

protocol CheckGenerator {
    func generateChecks(for topic: Topic, evidence: EvidenceSegment, note: Note) async throws -> [Check]
}

protocol AnswerEvaluator {
    func evaluate(response: String, for check: Check, evidence: EvidenceSegment) async -> AttemptScore
}

protocol CoverageCalculator {
    func exposure(for topic: Topic, evidenceSegments: [EvidenceSegment]) -> Double
    func mastery(for topic: Topic, checks: [Check], attempts: [Attempt]) -> Double
}

protocol JourneyScheduler {
    func refreshJourney(for note: Note?)
    func nextItem(noteID: UUID?) -> JourneyItem?
}

struct LearningFramework {
    let notes: NoteRepository
    let map: LearningMapRepository
    let attempts: AttemptRepository
    let journey: JourneyRepository
    let processor: NoteProcessor
    let validator: EvidenceValidator
    let evaluator: AnswerEvaluator
    let coverage: CoverageCalculator
    let scheduler: JourneyScheduler
}
