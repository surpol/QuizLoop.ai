# QuizLoop Learning API

This API is the contract between SQLite, Gemma, and the SwiftUI interface. The UI should not calculate learning state on its own. It should ask the learning API for one coverage object, render one chart, and drill into children when the user taps.

## Core Objects

### StudySource

Saved input from the learner.

- `id`
- `title`
- `type`: notes, audio, video, pdf, link
- `text`
- `status`
- `createdAt`

### LearningTopic

A concept group created from notes.

- `id`
- `sourceID`
- `title`
- `summary`
- `createdAt`

### LearningQuestion

The smallest testable unit.

- `id`
- `sourceID`
- `topicID`
- `topicTitle`
- `subtopicTitle`
- `type`: multiple choice, fill blank, short answer, flashcard
- `prompt`
- `answer`
- `choices`
- `importance`
- `difficulty`
- `createdAt`

### QuestionAttempt

One learner answer against one question.

- `id`
- `questionID`
- `response`
- `score`: `0...1`
- `createdAt`

### LearningCoverageNode

The only object the coverage UI should render.

- `id`
- `level`: all notes, topic, subtopic
- `title`
- `summary`
- `snapshot`
- `children`

### MasterySnapshot

The canonical percentage object.

- `testedCount`
- `totalCount`
- `weightedMastery`
- `title`: No Map, Unstarted, Learning, Getting Strong, Mastered

## Canonical Percentage Formula

Each question has a possible weight:

```text
possibleWeight = question.type.weight * question.importance * question.difficulty
```

Each latest attempt earns:

```text
earnedWeight = latestAttempt.score * possibleWeight
```

Coverage percentage:

```text
weightedMastery = sum(earnedWeight) / sum(possibleWeight)
```

Untested questions count as `0` earned weight. Only the latest attempt per question counts. This keeps the percentage stable and understandable:

- a missed question lowers coverage
- a passed question raises coverage
- a harder or more important question moves coverage more
- duplicate attempts do not double-count

## Public API Shape

### Add Notes

```swift
func addStudySource(title: String, text: String, type: StudySource.SourceType)
```

Effects:

- saves `StudySource` in SQLite
- asks Gemma to structure topics when available
- creates fallback topics/questions immediately
- persists `LearningTopic` and `LearningQuestion`

## Prompt Framework

The model is used as a structured parser, not as the app's controller. The app sends one extraction prompt when notes are saved.

### System Prompt

```text
You are QuizLoop's learning parser.
Return valid JSON only. Do not include markdown, prose, comments, or code fences.
Use only the supplied notes.
Extract a compact learning map for a student.
Create practical test questions that can be saved in SQLite.
```

### User Prompt Contract

The user prompt asks Gemma to return:

```json
{
  "topics": [
    {
      "title": "short title",
      "summary": "one sentence",
      "subtopics": [
        {
          "title": "short subtopic",
          "importance": 0.8,
          "questions": [
            {
              "type": "multipleChoice",
              "prompt": "question",
              "answer": "exact choice",
              "choices": ["choice", "choice", "choice", "choice"],
              "difficulty": 0.6
            }
          ]
        }
      ]
    }
  ]
}
```

### Validation Rules

The app validates the model output before saving:

- topics: max 4
- subtopics per topic: max 4
- questions per subtopic: max 4
- question types: `multipleChoice`, `fillBlank`, `shortAnswer`
- multiple choice must have exactly 4 choices
- multiple choice answer must match one choice
- `importance` and `difficulty` are clamped to `0.2...1.0`
- invalid questions are skipped
- if the extraction fails, the fallback local parser creates simple topics/questions

This keeps the app robust even when the model returns malformed text.

### Get Coverage Map

```swift
func coverageMap() -> LearningCoverageMap
```

Returns:

```text
All Notes
  Topic
    Subtopic
```

The interface should show one chart for the current node. Tapping that chart opens `children`.

### Get Next Check

```swift
func nextQuestion(for topic: LearningTopic?) -> LearningQuestion?
```

Selection priority:

- weak latest score
- untested questions
- importance
- difficulty
- question type
- time since last attempt

### Submit Attempt

```swift
func answerQuestion(_ question: LearningQuestion, response: String) -> QuestionAttempt
```

Effects:

- scores answer
- saves `QuestionAttempt`
- awards XP
- changes future coverage through `coverageMap()`

## UI Contract

Ask should render:

1. One coverage chart for the current node.
2. One primary action: `Start Check`.
3. A drill-down surface only after tapping the chart.

Notes should render:

1. One coverage chart for all saved notes.
2. Add Notes.
3. Saved note rows.

Avoid showing overall chart, selected topic chart, and subtopic charts all at once. That makes the system feel mathematically noisy even when the data is correct.
