# QuizLoop OOP Learning API Design

## Purpose

QuizLoop turns a raw stream of text into a guided learning journey.

The user should only have to:

1. Paste text.
2. Tap Continue Journey.
3. Answer small checks.

The system handles the rest: decomposition, evidence grounding, testing, coverage, scheduling, and review.

## Object Model

```text
Note
  -> Topic
      -> EvidenceSegment
      -> Check
  -> JourneyItem
  -> Attempt
```

The `Note` is the aggregate root. Everything belongs to a note.

## Note

A `Note` is the raw text object. It is the source of truth.

```swift
struct Note: Identifiable, Equatable {
    let id: UUID
    var title: String
    var rawText: String
    var sourceType: NoteSourceType
    var status: ProcessingStatus
    var createdAt: Date
    var updatedAt: Date
}
```

Responsibilities:

- Own the raw text.
- Track processing state.
- Provide the source material Gemma is allowed to use.

Rules:

- `rawText` is never overwritten by Gemma.
- All derived objects must point back to a `noteID`.
- If Gemma output cannot be grounded in `rawText`, reject it.

## Topic

A `Topic` is a concept extracted from a note.

```swift
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
}
```

Responsibilities:

- Group related evidence from the note.
- Hold learner state at the concept level.
- Act as the main unit for progress display.

Definitions:

- `exposurePercentage`: how much of the topic the learner has encountered.
- `masteryPercentage`: how well the learner has proven understanding.

Topic state is calculated from evidence segments, checks, and attempts.

## EvidenceSegment

An `EvidenceSegment` is the exact piece of the note that supports a topic.

```swift
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
}
```

Responsibilities:

- Ground Gemma output in actual note text.
- Prevent hallucinated topics and answers.
- Provide source evidence for checks and feedback.
- Let the app later highlight the original note text.

Rules:

- `text` must be found in `Note.rawText`.
- `startOffset` and `endOffset` must point to the exact span.
- Checks must be generated from one or more evidence segments.

## Check

A `Check` is one test of a topic, grounded in evidence.

```swift
struct Check: Identifiable, Equatable {
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
}
```

Check types:

```swift
enum CheckType: String {
    case multipleChoice
    case fillBlank
    case shortAnswer
    case misconception
    case ordering
}
```

Responsibilities:

- Test understanding of evidence.
- Feed attempts into exposure and mastery.
- Give the Journey engine concrete actions.

Rules:

- Multiple-choice answers must exactly match one choice.
- Choices should be shuffled before storage or per session.
- Prompt and answer must be supported by evidence.

## Attempt

An `Attempt` records the learner's answer to a check.

```swift
struct Attempt: Identifiable, Equatable {
    let id: UUID
    let noteID: UUID
    let topicID: UUID
    let checkID: UUID
    let evidenceSegmentID: UUID
    var response: String
    var score: Double
    var feedback: String
    var createdAt: Date
}
```

Responsibilities:

- Persist learner performance.
- Update topic exposure.
- Update topic mastery.
- Inform future journey scheduling.

Scoring:

- MC: app grades locally.
- Fill blank: app grades locally first.
- Short answer: app grades locally first; Gemma only grades uncertain cases.

## JourneyItem

A `JourneyItem` is one teacher-directed next action.

```swift
struct JourneyItem: Identifiable, Equatable {
    let id: UUID
    let noteID: UUID
    let topicID: UUID
    let checkID: UUID?
    let evidenceSegmentID: UUID?
    var type: JourneyItemType
    var reason: String
    var priority: Double
    var dueAt: Date
    var status: JourneyStatus
    var createdAt: Date
    var completedAt: Date?
}
```

Journey item types:

```swift
enum JourneyItemType: String {
    case introduce
    case test
    case review
    case strengthen
    case mixedReview
}
```

Responsibilities:

- Tell the learner what to do next.
- Hide navigation complexity.
- Convert the learning map into a path.

Rules:

- The user should not manually pick topics in the main flow.
- The next item is selected by SQLite/scoring logic, not Gemma.
- Gemma can provide importance and difficulty, but the app owns scheduling.

## Services

### NoteProcessor

Turns raw note text into topics, evidence, and checks.

```swift
protocol NoteProcessor {
    func process(note: Note) async throws -> ProcessedNote
}
```

Gemma implementation:

```swift
struct GemmaNoteProcessor: NoteProcessor {
    func process(note: Note) async throws -> ProcessedNote
}
```

Output:

```swift
struct ProcessedNote {
    let topics: [Topic]
    let evidenceSegments: [EvidenceSegment]
    let checks: [Check]
}
```

### EvidenceValidator

Validates Gemma output before saving.

```swift
protocol EvidenceValidator {
    func validate(_ processedNote: ProcessedNote, against note: Note) -> ValidationResult
}
```

Validation rules:

- Evidence text exists in note.
- Offsets match note text.
- Every topic has evidence.
- Every check points to evidence.
- Every answer is supported by evidence.

### JourneyScheduler

Creates the next learning actions from stored state.

```swift
protocol JourneyScheduler {
    func refreshJourney(for noteID: UUID?)
    func nextItem() -> JourneyItem?
}
```

Priority inputs:

- Low exposure.
- Low mastery.
- High importance.
- Due for review.
- Recent incorrect attempts.
- Daily XP target.

### AnswerEvaluator

Scores attempts.

```swift
protocol AnswerEvaluator {
    func evaluate(response: String, for check: Check, evidence: EvidenceSegment) async -> AttemptScore
}
```

Rules:

- Local grading first.
- Gemma only when local confidence is uncertain.
- Gemma receives only evidence, expected answer, and student response.

## Gemma Usage

Gemma is bounded. It is not the teacher.

Allowed tasks:

1. Extract topics from a note.
2. Extract evidence segments from a note.
3. Generate checks from evidence.
4. Grade uncertain free-text answers using evidence only.

Not allowed:

- Deciding what the learner studies next.
- Inventing curriculum outside the note.
- Updating coverage directly.
- Writing journey items directly.
- Using general knowledge in learning checks.

## Processing Flow

```text
String input
-> Note object
-> GemmaNoteProcessor
-> ProcessedNote proposal
-> EvidenceValidator
-> SQLite save
-> JourneyScheduler
-> Continue Journey
```

## Runtime Flow

```text
User taps Continue Journey
-> JourneyScheduler.nextItem()
-> App shows Check
-> User answers
-> AnswerEvaluator scores
-> Attempt saved
-> Topic exposure/mastery recalculated
-> JourneyScheduler refreshes
```

## Database Tables

```text
notes
topics
evidence_segments
checks
attempts
journey_items
xp_events
```

The database mirrors the object model. SQLite is the durable teacher memory.

## Product Language

User-facing:

- Notes
- Topics
- Journey
- Checks
- Coverage

Internal:

- EvidenceSegment
- Attempt
- JourneyItem
- ProcessingStatus

## First Implementation Slice

1. Add `Note`, `Topic`, `EvidenceSegment`, `Check`, `Attempt`, `JourneyItem`.
2. Persist them in SQLite.
3. Build fallback local processing for one-note demos.
4. Update Gemma prompt to output topics, evidence, and checks.
5. Make `Continue Journey` select a `JourneyItem`.
6. Keep UI simple: one progress strip, one current check.
