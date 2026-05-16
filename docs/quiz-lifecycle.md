# Quiz Lifecycle

## Purpose

Quizzes are the core learning loop in QuizLoop. A quiz is not a random set of questions. It is a short, directed check built from the student's saved notes, their previous answers, and the app's stored learning map.

The learner should feel one simple loop:

1. Add notes.
2. Take a quiz.
3. See what changed.
4. Take the next quiz.

Everything else should happen in the background.

## Main Objects

### Note

A note is the raw learning input. It can be pasted text, a Wikipedia article, a transcript, or any other text stream.

Stored in SQLite as `study_sources`.

Key fields:

- `id`
- `title`
- `type`
- `status`
- `text`
- `summary`
- `created_at`

### Topic

A topic is Gemma's high-level grouping of the note.

Stored in SQLite as `learning_topics`.

Purpose:

- Help organize a large note.
- Give the system broad areas to balance across.
- Make the learning map explainable.

### Segment

A segment is the smallest learnable idea extracted from the note. This is closer to a concept than a UI category.

Stored in SQLite as `learning_segments`.

Purpose:

- Anchor questions to specific note evidence.
- Measure which ideas have been tested.
- Help future quizzes target gaps instead of repeating randomly.

### Question

A question is a testable check created from a segment or subtopic.

Stored in SQLite as `learning_questions`.

Key fields:

- `source_id`
- `topic_id`
- `segment_id`
- `topic_title`
- `subtopic_title`
- `question_type`
- `prompt`
- `answer`
- `choices`
- `importance`
- `difficulty`

Question types:

- `multipleChoice`: default for most checks.
- `shortAnswer`: used for explanation, process, comparison, or reasoning.
- `fillBlank`: rare, only for short core terms.

### Attempt

An attempt is the student's answer to one question.

Stored in SQLite as `question_attempts`.

Purpose:

- Record the response.
- Store a score from `0` to `1`.
- Store feedback, matched ideas, and missing ideas.
- Drive the next quiz.

### Quiz Session

A quiz session is the completed quiz summary.

Stored in SQLite as `quiz_sessions`.

Purpose:

- Show history.
- Compare recent performance.
- Give evidence that understanding is changing over time.

## When Quizzes Are Made

### 1. Immediately After A Note Is Saved

When the student saves a note, `TutorEngine.addStudySource(...)` creates a `StudySource` with status `.processing`.

The app immediately saves the note to SQLite, clears old learning objects for that note, and starts `organizeTopics(for:)` in the background.

User-facing meaning:

- The note is saved right away.
- The app can show a build state.
- The learner should not be trapped on a loading screen.

Current UI wording should say:

- `Creating questions`

Not:

- `Building checks`

### 2. During Gemma Extraction

`organizeTopics(for:)` asks Gemma to extract:

- topics
- subtopics
- segments
- questions
- answers
- multiple-choice distractors
- importance
- difficulty

Gemma is bounded by a prompt that says:

- use only supplied notes
- return JSON only
- create many high-signal questions
- make at least 70% multiple choice
- use fill-in-the-blank rarely
- make question count proportional to note size

The generated objects are validated before they become quiz material.

### 3. In Partial Passes For Large Notes

Large notes can take longer. To avoid making the learner wait forever, the app creates a starter bank from the beginning of the note, saves partial objects, then continues chunk-by-chunk.

Current behavior:

- For notes over about `1,200` characters, a starter extraction creates the first few questions.
- For larger notes, the text is chunked into parts of about `4,500` characters.
- Partial topics, segments, and questions are saved as they arrive.

Product goal:

- The first quiz should become available quickly.
- The bank should keep expanding in the background.

### 4. Before Starting A Quiz

The quiz screen calls `buildQuizSelections(for:focusSubtopic:seed:)`.

This does not create new questions by itself. It selects from the existing SQLite question bank.

Selection considers:

- selected note
- optional focus subtopic
- untested questions
- weak attempts
- close attempts
- importance
- difficulty
- question type
- recent strong answers
- repeated prompt signatures
- spaced review timing

The target quiz size is based on available question count:

- `1...5` questions available: use all available questions.
- `6...12`: use up to `8`.
- More than `12`: use `8...12`, roughly one quarter of the bank.

### 5. After A Quiz Is Completed

The app grades the submitted answers in `gradeQuizAnswers(...)`.

Grading behavior:

- Multiple choice is exact-match against the saved answer.
- Written answers are graded with Gemma when available.
- If Gemma is unavailable, local semantic scoring is used.
- Attempts are saved to SQLite.
- Quiz history is saved separately.

After grading, the app calls `buildNextQuizQuestionsInBackground(...)`.

This is where the next quiz starts becoming smarter.

### 6. Background Expansion After A Quiz

After a quiz, QuizLoop may ask Gemma to create fresh follow-up questions.

The expansion plan looks at:

- current question count
- maximum feasible question count for the note
- missed answers
- close answers
- underserved subtopics
- note length

Expansion rules:

- If the bank is too small, backfill it.
- If the student missed ideas, create variants around weak concepts.
- If the student did well, add nearby untested ideas.
- Do not repeat exact questions.
- Do not exceed note-size capacity.

This is the key personalization loop:

`answers -> attempts -> weakness/strength evidence -> fresh questions -> next quiz`

## How Many Questions Are Created

Initial question count is proportional to useful note size.

Current planning rules:

- Under `80` words: about one question per `20` words, minimum `3`.
- `80...300` words: about one question per `35` words.
- `300...1,000` words: about one question per `50` words.
- Over `1,000` words: about one question per `70` words.
- Hard cap: `80` target questions for initial planning.

Maximum feasible bank size is higher:

- Very short note: up to `6`.
- Short note: up to `16`.
- Medium note: up to `36`.
- Long note: up to `64`.
- Very long note: up to `120`.

This means a Wikipedia article should not stay at only a few questions. It should start with enough questions to quiz, then keep expanding until the note has broad coverage.

## Quiz Selection Policy

Each quiz should feel forward-moving.

The algorithm should prefer:

1. Weak questions the student missed.
2. New questions from untested concepts.
3. Close questions that need strengthening.
4. Important questions due for spaced recall.

The algorithm should avoid:

- repeating questions answered strongly today
- near-duplicate prompts
- too many fill blanks
- too many written answers in one quiz
- over-testing one subtopic when no focus is selected

Current balancing rules:

- Prefer multiple choice.
- Limit fill blank to about one per quiz.
- Limit written answers to about 25% of the quiz.
- Spread questions across subtopics when no focus is selected.

## Grading Policy

### Multiple Choice

Multiple choice is deterministic:

- selected answer equals saved answer: `1.0`
- otherwise: `0.0`

### Written Answers

Written answers should be graded after quiz completion, not interrupting every question.

Gemma grading prompt is bounded:

- grade only against the saved answer
- allow paraphrases
- be strict about missing core ideas
- return JSON
- do not use outside knowledge

Stored grading evidence:

- score
- feedback
- matched ideas
- missing ideas

## What The UI Should Communicate

The UI should not expose internal system words like `checks`, `segments`, or `coverage` unless they are clearly explained.

Recommended learner-facing labels:

- `Creating questions`
- `Quiz ready`
- `Grading`
- `Next quiz ready`
- `Review results`

Avoid:

- `Building checks`
- `Coverage recall`
- raw question counts as the primary signal
- multiple competing progress metrics

## Current Gaps To Watch

1. The UI still sometimes says `checks`; replace this with `questions` or `quiz`.
2. Quiz generation can still feel slow for large notes if no partial bank is ready.
3. Quiz history exists, but the visual explanation of improvement needs to be simpler.
4. The system should make it obvious when a note is saved but questions are still being created.
5. The learner should never have to understand the database model to know what to do next.

## North Star

QuizLoop should feel like test-driven learning.

The note is the source code. Gemma writes the tests. SQLite remembers every run. The learner keeps taking small quizzes until the system has evidence that the note is understood.
