# Photosynthesis Quiz TDD

## Goal

Use one fixed photosynthesis note as a repeatable benchmark for QuizLoop's learning loop.

The test passes when the app can:

1. Turn the note into a broad quiz bank.
2. Ask varied, note-grounded questions.
3. Grade answers accurately.
4. Save attempts and quiz sessions.
5. Use the attempt history to make the next quiz smarter.
6. Document each quiz turn until every topic reaches strong evidence of understanding.

For this test, "100%" means every important topic has at least one strong recent answer and no topic is left untested.

## Fixture

Use [photosynthesis-note.md](/Users/suryapolina/Desktop/kaggle/QuizLoop/docs/tdd/photosynthesis-note.md) as the source note.

Approximate concept map expected from the fixture:

- Definition and purpose of photosynthesis
- Inputs and outputs
- Light-dependent reactions
- Calvin cycle
- Chloroplast structures
- Why photosynthesis matters
- Limiting factors
- Common misconceptions

## Test Cases

### T01: Note Ingestion

Action:

- Add the fixture note as a new note.

Expected:

- A `study_sources` row is saved immediately.
- The note status becomes `processing`.
- The UI says `Creating questions`, not `Building checks`.
- The learner can leave the screen while Gemma works.

Pass criteria:

- The note exists in SQLite before Gemma completes.
- No quiz UI blocks the learner with an indefinite spinner.

### T02: Gemma Learning Map Extraction

Action:

- Let Gemma process the fixture.

Expected:

- Gemma creates topics, segments, and questions using only the note text.
- The generated material excludes webpage chrome, source labels, and metadata.
- Every question answer is supported by the note.

Minimum expected objects:

- `5+` subtopics
- `8+` segments
- `10+` questions
- at least `70%` multiple choice
- no more than `10%` fill blank

Pass criteria:

- SQLite contains saved `learning_segments` and `learning_questions` for the note.
- The quiz bank covers every expected concept area above.

### T03: Question Quality

Action:

- Inspect the generated quiz bank.

Expected:

- Questions are specific, not vague.
- Multiple-choice distractors are plausible misconceptions.
- Correct choices are not always in the same position.
- Fill blanks are short terms only.
- Short answers ask "why", "how", comparison, or process questions.

Fail examples:

- "What is Photosynthesis?"
- "Which option is correct?"
- Choices like `not mentioned`, `none of the above`, or obvious unrelated answers.
- Questions about Wikipedia, source URL, licenses, page references, or article structure.

### T04: Quiz 1 Starts Broad

Action:

- Start the first quiz with no focus selected.

Expected:

- Quiz includes mostly multiple choice.
- Quiz samples across several subtopics.
- Written input is limited.
- Questions are ordered so the learner can move forward without waiting.

Pass criteria:

- Quiz has `8...12` questions when enough banked questions exist.
- The first quiz includes at least `4` distinct concept areas.

### T05: Grading Is Correct

Action:

- Submit a mixed quiz:
  - answer some multiple choice correctly
  - answer one multiple choice incorrectly
  - answer one written question with a paraphrase
  - answer one written question partially

Expected:

- Multiple choice uses exact saved answer matching.
- Written answers are graded by Gemma if available.
- Scores are saved to `question_attempts`.
- Feedback includes matched ideas and missing ideas in the quiz report.

Pass criteria:

- Correct MC = `1.0`.
- Incorrect MC = `0.0`.
- Good paraphrase = high score.
- Partial answer = middle score with clear missing idea.

### T06: Quiz History Is Stored

Action:

- Finish Quiz 1.

Expected:

- A `quiz_sessions` row is saved.
- The quiz report shows one clear score and a button to inspect results.
- Each answer can be traced to the saved question and expected answer.

Pass criteria:

- The Quizzes tab shows the completed quiz.
- The selected note widget can use the latest score as evidence.

### T07: Next Quiz Becomes Smarter

Action:

- Start Quiz 2 after Quiz 1 is graded.

Expected:

- Weak or partial topics return in new wording.
- Strong questions from Quiz 1 are avoided for at least the same day.
- New adjacent concepts appear.
- The quiz does not repeat the same prompts unless review is due.

Pass criteria:

- Quiz 2 has fewer repeated prompts than Quiz 1.
- At least one missed or partial concept is retested differently.
- At least one previously untested concept appears.

### T08: Turn Log Reaches 100%

Action:

- Continue taking quizzes until all expected concept areas are strong.

Expected:

- Each turn records:
  - quiz number
  - focus
  - questions asked
  - learner responses
  - grading result
  - missed ideas
  - next quiz reason

Pass criteria:

- Every concept area has a recent strong attempt.
- No high-importance concept remains untested.
- The turn log explains why the next quiz was chosen.

## Turn Log

Live test runs should be recorded in [photosynthesis-turn-log.md](/Users/suryapolina/Desktop/kaggle/QuizLoop/docs/tdd/photosynthesis-turn-log.md).

### Turn 0: Fixture Setup

Status:

- Fixture note created.
- Local `gemma4:e2b` availability checked.
- First local Gemma probe recorded in the turn log.

Expected next action:

- Add the fixture note into the app.
- Wait until the first question bank is ready.
- Export or inspect the generated questions.

### Turn 1: First Quiz

Status:

- Not run yet.

Record:

- Quiz questions:
- Responses:
- Score:
- Strong areas:
- Missed areas:
- Next quiz expectation:

### Turn 2: Personalized Follow-Up

Status:

- Not run yet.

Record:

- Repeated prompts:
- New prompts:
- Weak-area variants:
- Score:
- Next quiz expectation:

### Turn 3: Coverage Push

Status:

- Not run yet.

Record:

- Untested concept areas:
- Questions added by Gemma:
- Score:
- Remaining gaps:

### Turn N: 100% Evidence

Status:

- Not reached yet.

Completion evidence:

- Definition and purpose:
- Inputs and outputs:
- Light-dependent reactions:
- Calvin cycle:
- Chloroplast structures:
- Why photosynthesis matters:
- Limiting factors:
- Common misconceptions:

## Developer Notes

The current implementation path to watch:

- `TutorEngine.addStudySource(...)`
- `TutorEngine.organizeTopics(for:)`
- `TutorEngine.extractLearningObjects(...)`
- `TutorEngine.requestLearningExtraction(...)`
- `TutorEngine.buildQuizSelections(...)`
- `TutorEngine.gradeQuizAnswers(...)`
- `TutorEngine.buildNextQuizQuestionsInBackground(...)`

The database tables to inspect:

- `study_sources`
- `learning_topics`
- `learning_segments`
- `learning_questions`
- `question_attempts`
- `quiz_sessions`

## Current Open Questions

- Should the UI expose "100%" at all, or should the system keep it internally and show simpler language?
- Should quizzes be capped at `12`, or should long notes sometimes create longer challenge sessions?
- Should the first quiz wait for a broad bank, or start from a small starter bank immediately?
- Should "all topics strong" require one strong answer or multiple spaced strong answers?
