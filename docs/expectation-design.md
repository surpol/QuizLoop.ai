# Accordian Expectation Design

## Product Promise

Accordian is a private offline notes assistant. The student saves learning material locally, then asks questions against those notes.

The app should not feel like a general chatbot with notes bolted on. It should feel like the student's own small knowledge base with an assistant on top.

## Mental Model

The student should understand this loop:

1. Add notes.
2. Inspect what was saved.
3. Choose a topic.
4. Choose a suggested learning move.
5. Accordian retrieves matching local notes.
6. Gemma explains or tests using those notes.
7. Accordian says when notes are missing.

SQLite owns persistence. Retrieval chooses local context. Gemma explains and reasons.

## Expected Answer Behavior

When saved notes match:

- Answer directly.
- Keep the answer short.
- Use the saved note first.
- Show the note title under the response.
- Show clean learner action labels such as `Teach: Photosynthesis`, not raw prompt text.

When the student opens saved notes:

- Show the exact note text.
- Show lightweight metadata, such as note type, saved date, and word count.
- Provide an `Ask From These Notes` action that preloads a note-specific prompt.
- The follow-up answer should cite that note.
- Provide a clear delete action for wrong or outdated notes.
- Deleting notes should also remove flashcards generated from them.

When the prompt is broad but notes-related:

- Treat it as a request over all saved notes.
- Examples: `What did I learn?`, `Summarize my saved notes`, `What should I review next?`, `Quiz me from my notes`.
- Use the newest/relevant saved notes even if keyword matching is weak.

When no saved notes match:

- Do not pretend the answer came from notes.
- Say that no matching local notes were found.
- If giving general knowledge, label it as general knowledge.
- Suggest adding or naming the relevant material.

When there are no saved notes at all:

- Guide the student to add notes, transcript text, or class material.
- Keep chat useful, but do not oversell personalization.

## Test Matrix

| Prompt | Desired behavior | Observed before fix | Current expectation |
| --- | --- | --- | --- |
| `Photosynthesis` | Use the saved Photosynthesis source and answer from it. | Passed. Answer cited `Photosynthesis`. | Should continue to pass. |
| `What did I learn?` | Interpret as a broad notes query and summarize saved material. | Failed. Asked for more context. | Should answer from saved notes and cite the note. |
| `Summarize my saved notes.` | Summarize all saved notes. | Risky. Keyword search may not match note text. | Should use recent saved notes by default. |
| `What should I review next?` | Suggest review based on saved notes. | Risky. Keyword search may not match note text. | Should use recent saved notes by default. |
| `What is mitochondria?` with only Photosynthesis saved | Say no matching local notes were found, then optionally answer generally. | Risky. Could answer like a generic chatbot. | Should distinguish notes answer from general knowledge. |
| Open `Photosynthesis`, tap `Ask From These Notes` | Preload an Ask prompt tied to that note and answer from it. | Not available before enhancement. | Should cite `Photosynthesis`. |

## UX Copy Rules

Use product language that reinforces notes:

- `Ask from notes`
- `Talk About`
- `Choose a suggestion`
- `Saved Notes`
- `Offline assistant ready`
- `Stored locally`
- `No matching notes found`

Avoid language that makes Accordian sound like a generic tutor:

- broad dashboards
- complex practice modes
- vague progress claims
- generic "I can help with anything" onboarding

## Demo Script Expectation

The best demo path is:

1. Show Notes with one saved note and its grouped topics.
2. Open the saved note and show the exact note text.
3. Tap `Ask From These Notes`.
4. Accordian answers from that note.
5. Ask: `What did I learn?`
6. Accordian answers from that note.
7. Ask: `What is mitochondria?`
8. Accordian says it does not have matching local notes, then distinguishes any general answer.

That contrast proves the product: Accordian knows when it is using the student's local notes and when it is not.
