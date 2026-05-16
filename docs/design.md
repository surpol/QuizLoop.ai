# QuizLoop Design

## Purpose

QuizLoop turns a stream of student notes into a guided quiz journey.

The student should not have to decide what to study, how to test themselves, or when to revisit something. The app should receive notes, analyze them, create grounded questions, quiz the student, grade the answers, save evidence, and prepare the next useful quiz.

For the Kaggle Future of Education track, QuizLoop should be presented as a multi-tool learning agent:

- `Input Tool`: receives raw notes, copied pages, transcripts, or syllabus text.
- `Map Tool`: uses Gemma to deconstruct the note into topics, subtopics, concepts, and evidence.
- `Test Tool`: uses Gemma to generate grounded checks with plausible distractors.
- `Grade Tool`: uses Gemma to judge free-form answers against the saved note context.
- `Memory Tool`: uses SQLite to store notes, learning objects, questions, quiz history, attempts, and weak areas.
- `Planner Tool`: uses the stored evidence to decide the next quiz focus without asking the learner to navigate.

The app should make these tools visible enough that judges understand the architecture, while keeping the learner experience simple: paste notes, start quiz, see result, repeat.

## Product Loop

1. Receive a note.
2. Analyze the note with Gemma.
3. Store the learning map in SQLite.
4. Create a question bank from the note.
5. Show the selected note on `Learn`.
6. Start the next quiz.
7. Capture answers without interruption.
8. Grade the quiz after completion.
9. Save quiz history and answer evidence.
10. Prepare the next quiz in the background.

Each step must produce a concrete object. If a step does not produce an object, it should not be part of the core loop.

## Step 1: Receive Note

User action:

- The student pastes text into `Notes`.
- Text can come from Wikipedia, class notes, a syllabus, a transcript, or any copied text stream.

System output:

- A `Note` object.

Required fields:

- `id`
- `title`
- `raw_text`
- `cleaned_text`
- `created_at`
- `updated_at`
- `status`: `saved`, `analyzing`, `ready`, `failed`

Rules:

- Save the note immediately before Gemma runs.
- Never block the student on analysis.
- The original text must remain editable.
- If the note is edited, mark derived learning objects stale and rebuild in the background.

## Step 2: Clean Note

System action:

- Remove webpage chrome, reference markers, repeated navigation text, empty lines, and obvious copy artifacts.

System output:

- Updated `cleaned_text` on the `Note`.

Rules:

- Do not summarize at this step.
- Do not invent structure.
- Cleaning should preserve enough source text for exact grounding.

## Step 3: Analyze Note With Gemma

Gemma job:

- Convert one note into a learning map.

Gemma input:

- `note_id`
- `title`
- `cleaned_text`
- strict JSON schema

Gemma output:

- `Topic` objects
- `Subtopic` objects
- `Concept` objects
- grounded evidence spans
- importance and difficulty estimates

Required objects:

`Topic`

- `id`
- `note_id`
- `title`
- `summary`
- `importance`

`Subtopic`

- `id`
- `topic_id`
- `title`
- `summary`
- `importance`

`Concept`

- `id`
- `subtopic_id`
- `claim`
- `source_text_span`
- `importance`
- `difficulty`

Rules:

- Gemma must only use the note.
- Every concept should trace back to a source span.
- A concept is the smallest testable idea.
- Topics and subtopics are organization. Concepts are what the student must learn.

## Step 4: Validate Learning Map

System action:

- Check Gemma output before storing it.

Validation rules:

- Reject empty titles.
- Reject concepts without source evidence.
- Reject questions about webpage metadata, URLs, references, or licenses.
- Reject answers that are too vague.
- Reject duplicate concept claims.
- Keep old valid learning objects if the rebuild fails.

System output:

- A stored, valid learning map in SQLite.

## Step 5: Create Question Bank

Gemma job:

- Create questions from concepts.

Gemma input:

- selected concepts
- source spans
- known prior questions for the note
- requested question style mix

Gemma output:

- `Question` objects.

Required fields:

- `id`
- `note_id`
- `topic_id`
- `subtopic_id`
- `concept_id`
- `type`: `multiple_choice`, `short_answer`, `fill_blank`
- `prompt`
- `correct_answer`
- `choices`
- `distractors`
- `difficulty`
- `importance`
- `created_at`
- `last_used_at`
- `retired_at`

Rules:

- Most questions should be multiple choice.
- Short answer should be used for explanation, process, comparison, or causal reasoning.
- Fill blank should be rare.
- Distractors must be plausible misconceptions, not random wrong words.
- Question count should scale with note size and concept count.
- Do not create a fixed number of questions per note.
- Do not show fallback questions as if they are real Gemma questions.

## Step 6: Show Learn Screen

User sees:

- Selected note chips.
- One widget for the selected note.
- Focus selector when useful.
- One main action: `Start Quiz`, `Start Review`, or a clear build state.

Widget purpose:

- Answer: what should I do next?

Widget should show:

- selected note title
- readiness state
- simple progress signal
- build progress if questions are being generated

Widget should not show:

- deep quiz history
- many competing metrics
- raw database counts
- confusing coverage terms

## Step 7: Select Next Quiz

System action:

- Build a quiz session from SQLite.

Quiz selection input:

- selected note
- optional focus
- latest quiz history
- latest answer attempts
- concept importance
- concept difficulty
- last used time
- whether new questions are ready

Quiz selection output:

- `QuizSession`

Required fields:

- `id`
- `note_id`
- `focus`
- `question_ids`
- `started_at`
- `completed_at`
- `status`: `active`, `grading`, `graded`

Selection rules:

- Prefer new questions for concepts not yet tested.
- Reuse questions the student missed or barely passed.
- Avoid questions from the last 1-2 quiz sessions if they were answered strongly.
- Bring old questions back after enough time has passed.
- Increase difficulty slowly after strong performance.
- Mix adjacent concepts after the student performs well.
- Never show unrelated note questions.

Known current problem:

- The app can repeat the same questions across consecutive quizzes when fresh questions are still building.
- This violates the product promise. Review questions should be intentional, not accidental.

## Step 8: Take Quiz

User sees:

- Full-screen quiz interface.
- One question at a time.
- Progress text such as `2 of 8`.
- No tab bar.
- No widget.

User action:

- Answer each question.

System output:

- `QuizAnswer` objects.

Required fields:

- `id`
- `quiz_session_id`
- `question_id`
- `response`
- `submitted_at`

Rules:

- Do not grade visibly after every question.
- Keep the student moving forward.
- Clear text input between written questions.
- Use big tappable answer choices.
- Do not interrupt with explanations mid-quiz.

## Step 9: Grade Quiz

System action:

- Grade after the quiz is complete.

Grading rules:

- Multiple choice is graded locally.
- Short answer and fill blank can use Gemma.
- Gemma must grade only against the saved expected answer and source evidence.
- Gemma should return structured JSON, not a general explanation.

Grading output:

- `QuestionAttempt` objects.

Required fields:

- `id`
- `question_id`
- `quiz_session_id`
- `response`
- `score`
- `feedback`
- `matched_ideas`
- `missing_ideas`
- `created_at`

Rules:

- Store every answer.
- Store every score.
- Store every feedback object.
- The user does not need to see every detail immediately.
- The result screen should first show the quiz grade and then allow viewing details.

## Step 10: Update Understanding

System action:

- Update concept mastery from attempts.

Mastery dimensions:

- accuracy: did the student answer correctly?
- coverage: how many concepts have been tested?
- recency: has the concept been checked recently?
- difficulty: was the check basic or advanced?
- importance: how central is the concept to the note?
- consistency: has the student answered related questions reliably?

System output:

- Updated concept, subtopic, topic, and note mastery.

Rules:

- Understanding is not just quiz score.
- A 100% quiz on 3 easy repeated questions should not mean full note mastery.
- A lower score can still be useful because it finds weak concepts.
- UI can simplify this, but SQLite must preserve the details.

## Step 11: Show Quiz Result

User sees:

- Quiz grade.
- Short status message.
- `Back to Widget`.
- `View Results`.

Detailed result should show:

- question
- user answer
- correct answer
- Gemma grading reason when used
- matched ideas
- missing ideas

Rules:

- Do not show the same percentage in multiple competing places.
- Do not make the details dropdown feel janky.
- Results should feel like evidence, not a punishment.

## Step 12: Save Quiz History

System output:

- `QuizHistoryEntry`

Required fields:

- `id`
- `note_id`
- `score`
- `question_count`
- `got_count`
- `close_count`
- `review_count`
- `created_at`

Used by:

- `Quizzes` tab
- next quiz selection
- progress trend
- spaced review

Rules:

- The widget should not be the main history screen.
- `Quizzes` owns history, trends, and old session evidence.

## Step 13: Prepare Next Quiz

System action:

- Immediately after grading, prepare a next quiz in the background.

Inputs:

- latest quiz result
- missed concepts
- strong concepts
- untested concepts
- adjacent concepts
- question bank freshness

Output:

- New or selected questions ready for the next session.

Rules:

- The student should not wait on quiz construction.
- If fresh questions are not ready, the UI may offer review.
- Review must be labeled clearly.
- Review should avoid repeating strongly answered questions from the immediate previous quiz.

## Tabs

`Learn`

- Start the next quiz.
- Show the selected note widget.
- Keep the student moving forward.

`Notes`

- Add, edit, delete, and rebuild notes.
- Show processing status.
- Own the raw text.

`Quizzes`

- Show quiz history.
- Show score trend.
- Filter by note.
- Show session evidence.

`Settings`

- Model selection.
- Gemma/Ollama connection.
- Local runtime status.

## SQLite Responsibilities

SQLite is the memory of the app.

It should store:

- notes
- topics
- subtopics
- concepts
- questions
- quiz sessions
- quiz answers
- question attempts
- quiz history
- model processing status

SQLite should make the app usable without asking Gemma every time.

## Gemma Responsibilities

Gemma is the intelligence of the app.

It should:

- analyze notes
- identify concepts
- create questions
- create distractors
- grade written answers
- explain missing ideas in result details

Gemma should not:

- control navigation
- own memory
- decide what UI to show
- create content unrelated to the note
- be required to answer every tap

## Current Highest-Priority UX Bug

The quiz loop can repeat the same questions too soon.

Desired fix:

- Track question usage per quiz session.
- Mark strong answers as temporarily cooled down.
- Select untested or adjacent concepts first.
- Only repeat recent questions if the answer was weak, close, or explicitly due for review.

This is the next algorithmic improvement because it directly affects whether QuizLoop feels like a learning journey or a repeated worksheet.
