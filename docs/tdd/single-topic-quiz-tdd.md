# Single Topic Quiz TDD

## Goal

Use one topic at a time to prove QuizLoop can move a learner forward, not just ask isolated questions.

Current test topic:

- Source: `TDD Photosynthesis timeout coverage v3 v2 Fixture`
- Focus: `Light-Dependent Reactions`

## Pass Criteria

For one selected topic, the app passes when:

- The bank contains at least `6` unique questions for the focus.
- No duplicate normalized prompts appear.
- A focused quiz can ask `4...6` questions without leaving the topic.
- After a quiz, the next quiz avoids strong same-day prompts.
- If the learner is strong, the next quiz asks adjacent, deeper questions from the same topic.
- If the learner misses something, the next quiz retests that idea in different wording.
- SQLite stores every attempt and quiz session.

## Current Run

Date: 2026-05-12

SQLite state after dedupe:

- Source target: `10` questions
- Saved unique questions: `6`
- Focus questions for `Light-Dependent Reactions`: `2`
- Duplicate normalized prompts: `0`

Current focus questions:

- `Where do the light-dependent reactions occur in the chloroplast?`
- `Which energy-carrying molecules are produced during the light-dependent reactions?`

Quiz run:

- Started a quiz from the fixture.
- Quiz sampled `Overall Process` and `Light-Dependent Reactions`.
- Finished with `100%`.
- Attempts and quiz session were saved.

Expansion result:

- Background build attempted after the quiz.
- SQLite recorded: `Quiz available. No new questions added this pass.`
- Focus depth did not improve.

## Verdict

Fail.

The app passes storage, grading, and flow mechanics, but it does not yet pass the single-topic learning-progress test. The current loop cannot prove mastery of `Light-Dependent Reactions` because there are only two unique questions for that focus and background expansion did not add deeper variants.

## Next Required Fix

The quiz builder must support explicit focused expansion:

- When the learner selects a focus, Gemma should generate more questions inside that focus first.
- The prompt should ask for multiple angles within the focus: location, inputs, outputs, sequence, purpose, misconception, and relationship to the next stage.
- Expansion should not be considered successful unless at least one non-duplicate focus question is saved.
- The Learn page should make focus selection feel like choosing the next learning lane.
