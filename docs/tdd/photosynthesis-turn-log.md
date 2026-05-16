# Photosynthesis Turn Log

This file documents each test turn for the fixed photosynthesis fixture.

Fixture: [photosynthesis-note.md](/Users/suryapolina/Desktop/kaggle/QuizLoop/docs/tdd/photosynthesis-note.md)

Spec: [photosynthesis-quiz-tdd.md](/Users/suryapolina/Desktop/kaggle/QuizLoop/docs/tdd/photosynthesis-quiz-tdd.md)

## Turn 0: Local Gemma Probe

Date: 2026-05-12

Model:

- `gemma4:e2b`

Prompt shape:

- Shortened photosynthesis text.
- Asked Gemma for 8 high-quality questions.
- Required mostly multiple choice.
- Required JSON only.

Latency:

- About 47 seconds total on first local request.
- About 6 seconds were model load time.

Generated coverage:

- Photosynthesis overview
- Oxygenic photosynthesis inputs and outputs
- Light-dependent reaction location
- Light-dependent reaction products
- Calvin cycle location
- Calvin cycle inputs
- Limiting factors
- Misconceptions

Positive results:

- Generated 8 questions.
- All questions were multiple choice.
- Most major concepts were covered.
- Distractors were mostly plausible and related to the note.
- Correct answers were not always first.

Failures / risks found:

- Gemma wrapped the JSON in a markdown code fence even though the prompt said JSON only.
- The response included hidden model reasoning outside the final content in the API payload.
- One multiple-choice answer did not exactly match the corresponding choice text:
  - answer: `oxygenic photosynthesis uses carbon dioxide and water to produce glucose and oxygen`
  - closest choice: `uses carbon dioxide and water to produce glucose and oxygen`
- Some choices used LaTeX-like formatting, which is unnecessary in the app.
- Some prompts were broad and could be made more student-friendly.

TDD conclusion:

- The question quality is promising.
- The app must keep strict post-generation validation.
- For multiple choice, `answer` must exactly equal one of the 4 choices after normalization or the question should be repaired/rejected.
- The JSON parser must continue stripping code fences.
- The app should prefer generated MC questions but still reject low-quality or malformed ones.

Next action:

- Run the full fixture through the app.
- Inspect SQLite for the saved question bank.
- Take Quiz 1 and record every question, response, grade, and missed idea.

## Turn 1: First App Quiz

Status: Completed with important failures.

App setup:

- Added fixture through the real Notes UI.
- Text was verified clean in the editor after disabling autocorrect.
- SQLite saved the note immediately.

First extraction evidence:

- `study_sources.status`: `ready`
- `learning_topics`: `1`
- `learning_segments`: `3`
- `learning_questions`: `7`

Generated questions:

1. Where do the light-dependent reactions take place?
2. What molecules are produced during the light-dependent reactions?
3. What molecules are used in the Calvin cycle to build sugar?
4. Where do the light-dependent reactions occur in chloroplasts?
5. What happens to water molecules during the light-dependent reactions?
6. What energy-carrying molecules are produced during the light-dependent reactions?
7. What are the inputs of photosynthesis?

Positive results:

- Questions were grounded in the note.
- All questions were multiple choice.
- Choices were plausible enough for a first pass.
- The app wording now says `Creating questions`, not `Building checks`.
- SQLite saved each answer attempt and the quiz session.

Failures / risks found:

- The note was still marked `ready` after only 7 questions.
- The quiz only asked 4 questions because duplicate/near-duplicate filtering removed much of the bank.
- The generated bank over-focused on light-dependent reactions.
- The fixture did not produce enough coverage for:
  - chloroplast structure
  - why photosynthesis matters
  - limiting factors
  - misconceptions
- The quiz score displayed `80%` even though the deterministic MC score was 3 correct out of 4. This may be weighted, but the UI does not explain it.
- After the quiz, background expansion added only 1 new question, leaving the bank at 8.
- The new question was another Calvin cycle variant, not a missing concept like limiting factors or misconceptions.

Quiz 1 questions and responses:

| # | Question | Response | Expected | Result |
| --- | --- | --- | --- | --- |
| 1 | What are the inputs of photosynthesis? | light energy, water, and carbon dioxide | light energy, water, and carbon dioxide | Correct |
| 2 | Where do the light-dependent reactions occur in chloroplasts? | stroma of the chloroplast | thylakoid membranes of chloroplasts | Review |
| 3 | What molecules are used in the Calvin cycle to build sugar? | carbon dioxide, ATP, and NADPH | carbon dioxide, ATP, and NADPH | Correct |
| 4 | What molecules are produced during the light-dependent reactions? | ATP and NADPH | ATP and NADPH | Correct |

Quiz 1 stored result:

- `quiz_sessions.score`: `0.80`
- `question_count`: `4`
- `got_count`: `3`
- `review_count`: `1`

TDD conclusion:

- A starter bank is useful, but it must not be treated as complete.
- `ready` should mean the bank is broad enough for the note, or the UI should distinguish `quiz available` from `map complete`.
- If only a starter bank exists, the UI should say questions are still being created, while allowing a quick quiz if useful.
- The app should continue expanding the bank until the note-size target or concept coverage target is reached.
- The next quiz cannot reach 100% understanding until extraction covers every expected concept area.

Next fix:

- Keep partially generated questions saved.
- Do not mark the note fully ready when saved question count is below the planner minimum.
- Trigger background expansion until the question bank reaches the target.
- Make expansion target missing concept areas, not only underserved subtopics that already exist.
- Make the score shown in the report match the visible grading model or explain the weighting.

## Turn 2: Personalized Follow-Up

Status: In progress.

Target behavior:

- Repeat weak concepts in different wording.
- Avoid strong same-day prompts.
- Add adjacent untested concepts.

Record:

- Repeated prompts: still too many light-dependent reaction variants.
- New prompts: background expansion added one Calvin cycle variant, but did not add limiting factors or misconceptions.
- Weak-area variants: the missed thylakoid/stroma idea was eligible for review.
- Score: not run yet for Turn 2.
- Next quiz expectation: should include the missed thylakoid location concept plus at least one untested concept from limiting factors or misconceptions.

Fix attempted:

- Added uncovered note targets to the expansion plan.
- Expansion now compares question coverage against note sentences and sends high-signal uncovered sentences into the Gemma follow-up prompt.
- Added prompt rules that uncovered note targets are higher priority than existing subtopics.

New risk discovered:

- Small-note extraction can still sit in `processing` for too long when the local model request stalls.
- Aggressive local timeouts may not immediately free the Ollama model, so the next request can be delayed behind an abandoned generation.

Next fix:

- Add a true quiz-bank build state machine with request ownership, cancellation, and retry visibility.
- Avoid launching overlapping Gemma requests for the same note.
- Persist build attempts and errors so SQLite can explain whether a note is `ready`, `building`, `partial`, or `failed`.

## Turn 3: Coverage Push

Status: Not run yet.

Target behavior:

- Focus on untested concept areas.
- Use more difficult questions only after foundation questions are strong.

Record:

- Untested concept areas:
- Questions added by Gemma:
- Score:
- Remaining gaps:

## Completion: 100% Evidence

Status: Not reached yet.

A topic is complete when it has a recent strong answer and no unresolved high-importance missing idea.

Checklist:

- Definition and purpose: not reached
- Inputs and outputs: not reached
- Light-dependent reactions: not reached
- Calvin cycle: not reached
- Chloroplast structures: not reached
- Why photosynthesis matters: not reached
- Limiting factors: not reached
- Common misconceptions: not reached
