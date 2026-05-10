# Accordian Current Behavior

Last reviewed: 2026-05-09

## App Shape Today

Accordian is a SwiftUI iOS app with three main tabs:

- `Ask`: guided journey and active checks
- `Notes`: saved study sources
- `Settings`: model/runtime setup

SQLite stores notes, topics, segments, questions, attempts, assignments, suggestions, XP events, chat turns, and flashcards.

## Home Screen

Current behavior:

- Shows horizontal note stack chips from saved `StudySource` records.
- Defaults to the first saved source.
- Selecting a chip resets the active question and scopes the home widget.
- The widget now shows selected-note progress, not all-notes progress.
- The widget can be tapped to show checked count, remaining checks, and coverage.
- `Continue Journey` uses the selected source to fetch the next question.

Known gap:

- The chip UI is functional but still visually plain.
- The term `checked` is more honest than `understood`, but the data model still blends attempt count and mastery in some places.
- The widget progress bar uses weighted mastery, while the supporting text says checked count. This may still need clearer separation.

## Note Processing

Current behavior:

- When a note is added, it is saved immediately with `processing` status.
- The app seeds fallback topics/questions so the user can start without waiting.
- `TutorEngine.organizeTopics(for:)` asks Gemma for a JSON learning extraction.
- Before Gemma receives text, pasted notes are cleaned to remove common webpage chrome and reference markers.
- Long notes send a larger cleaned context window to Gemma rather than the first raw page characters.
- If Gemma succeeds, topics, segments, and questions are replaced with Gemma output.
- If Gemma fails, fallback objects remain and the source status becomes `failed`.
- Failed notes retry processing on app launch so they can upgrade when the local Gemma runtime becomes available.

Known gap:

- Existing learning attempts are not fully migrated if questions are regenerated.
- Fallback segmentation is simple and not true evidence-span extraction.
- The database has learning segments, but the UI still mostly operates through questions.
- Fallback questions are still shallow compared with Gemma output, especially for broad encyclopedia-style notes.

## Gemma Usage

Current behavior:

- `GemmaService.swift` wraps local Ollama and placeholder on-device service modes.
- Gemma is used for note decomposition through `learningParserSystemPrompt` and `learningExtractionPrompt`.
- Gemma is also used for general submit/chat responses.
- The note decomposition prompt asks for topics, subtopics, segments, and questions.
- The prompt now asks for plausible multiple-choice distractors and bans obvious giveaway choices.

Known gap:

- The app does not yet validate that every Gemma segment is an exact span in the original note text.
- Gemma-generated short answers are trusted after parsing if they pass basic shape checks.
- On-device Gemma is still a placeholder.

## Question Flow

Current behavior:

- `Continue Journey` calls `nextJourneyStep(for: selectedSource)`.
- The engine scopes candidate questions to the selected source.
- Untested multiple-choice questions are preferred first.
- If all questions have attempts, the engine schedules review/strengthen assignments.
- Multiple-choice answers are graded locally as exact matches.
- Fill blank and short answer use Gemma grading when the configured model is ready.
- Gemma grading is bounded: it receives the prompt, expected answer from saved notes, student response, and local heuristic score, then returns JSON with a 0-1 score.
- If Gemma is unavailable, fill blank and short answer fall back instantly to local overlap scoring.
- The local fallback caps vague one-word short answers low.
- New attempts save a question snapshot: source id, topic, subtopic, type, prompt, expected answer, response, score, and timestamp.
- Regenerated questions preserve ids when the prompt/type/answer signature matches, so saved answers stay linked after startup processing.

Known gap:

- The journey engine is still relatively simple priority sorting, not a complete spaced repetition scheduler.
- Review assignments are not strongly tied to due dates or learning intervals yet.
- Short-answer grading is heuristic and should eventually use a stricter rubric or bounded Gemma grading for uncertain cases.
- Older attempts that were orphaned before the id-preservation fix remain in SQLite, but cannot all be re-linked because their original question rows were already deleted.

## Progress Behavior

Current behavior:

- `MasterySnapshot` calculates weighted mastery from latest attempts.
- Question weights, importance, and difficulty influence mastery.
- Wrong answers lower mastery.
- `Journey completed` appears only when selected-note weighted mastery reaches about 100%.
- The UI separately shows checked count from total checks.

Known gap:

- Checked count means attempted, not mastered.
- The product language now avoids saying `understood` for attempted checks, but the data model does not yet have separate exposure, checked, and mastered counters.

## Notes Screen

Current behavior:

- The notes screen lists saved sources and shows coverage metadata.
- Notes can be deleted.
- Saved note text is persisted locally.

Known gap:

- Notes are still called `StudySource` in code.
- Topics and notes can still feel conceptually blurred in the UI.
- The note detail flow is not yet the primary path; Ask is now the main journey surface.

## Alignment Status

Aligned:

- App is moving toward note-stack based learning.
- Questions are scoped to the active selected note.
- Gemma is used mainly for decomposition and bounded learning content.
- SQLite is the durable memory layer.
- The widget no longer shows daily completion as the core model.

Not aligned yet:

- Mastery, checked coverage, and exposure are not cleanly separated.
- Evidence segments are not fully enforced as exact spans.
- The UI does not yet show a beautiful or obvious note-stack switcher.
- The journey algorithm is not yet a mature learning scheduler.
- On-device Gemma is not production-ready.
