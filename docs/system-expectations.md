# Accordian System Expectations

## Product Purpose

Accordian turns a raw note into a forward learning journey.

The student should not have to design a study plan, choose a practice mode, or decide what matters. They should paste notes, choose the note stack they want to learn, and press `Continue Journey`.

## Core Loop

1. Student adds a note.
2. Gemma deconstructs the note into topics, evidence, and checks.
3. The student chooses a note stack on the home screen.
4. Accordian shows progress for that selected stack only.
5. `Continue Journey` serves the next most useful check for that stack.
6. The answer is scored.
7. Progress updates.
8. The journey is marked completed only when that note stack reaches 100%.

## Home Screen Expectations

The home screen should answer one question: what am I learning right now?

Expected elements:

- Note stack switcher: lets the student choose the active note.
- Selected note journey widget: shows progress for the active note only.
- `Continue Journey`: starts or continues the next check for the active note.

The widget should not show daily goals, all-notes progress, XP-first metrics, or abstract dashboard language.

Default widget state:

- selected note title
- remaining checks or `Journey completed`
- one simple progress bar
- checked count
- `Details` affordance

Details state:

- checked count
- remaining checks
- coverage percentage

## Note Stack Expectations

A note stack is one saved note object plus everything derived from it.

Switching stacks should:

- reset the visible active question
- scope the journey widget to that note
- scope `Continue Journey` to that note
- prevent questions from unrelated notes appearing

## Gemma Usage Expectations

Gemma should be bounded.

Allowed Gemma jobs:

- deconstruct a note into topics, subtopics, evidence segments, and checks
- generate multiple-choice distractors that are plausible misconceptions
- help explain from saved notes when the student asks a note-grounded question

Gemma should not:

- invent topics outside the note
- decide app navigation
- determine progress rules
- replace SQLite as memory
- grade simple multiple-choice answers

Bounded grading expectation:

- MC is graded locally.
- Fill blank and short answer may be graded by Gemma.
- Gemma must grade only against the expected answer from saved notes.
- Gemma must return a numeric score, not free-form teaching.
- If Gemma is unavailable, the local scorer must keep the journey moving.

If Gemma is unavailable, the app should create a simple local fallback journey so the student can keep moving.

## Progress Expectations

Progress should represent demonstrated understanding of a selected note stack.

Rules:

- `Journey completed` means weighted mastery is effectively 100%.
- A weak or wrong attempt should not be called understood.
- The UI may say `checked` for attempted checks.
- The system should distinguish checked coverage from mastery when possible.

## Question Expectations

Questions should be relevant to the selected note stack.

Multiple choice:

- exactly four choices
- one correct answer
- incorrect choices should be plausible misconceptions
- answer order should not always be first

Fill blank and short answer:

- should be scored relative to the expected concept, not just whether one word overlaps
- vague answers should receive low partial credit
- feedback should show the grounded answer from the note

## Alignment Principle

Every visible UI element should push the student forward.

If a metric does not help the student decide what to do next, hide it behind details or remove it.
