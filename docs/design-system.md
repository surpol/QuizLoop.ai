# Accordian Design System

## Product Feel

Accordian should feel like a quiet Apple-native notes assistant: calm, local, private, and useful immediately. The UI should never feel like a marketing site, a generic chatbot wrapper, or a full study platform. Every screen should help a student do one of three things:

- choose what to learn
- add notes
- prove what they know

The design language is minimal, spacious enough to read, but not wasteful. Avoid decorative gradients, hero panels, dashboards, complex practice modes, oversized empty states, and explanatory blocks that repeat what the controls already say.

## Visual Principles

1. **Utility first**
   The first screen is the assistant, not a landing page. The primary action should always be visible.

2. **Native over custom**
   Prefer SwiftUI system controls, SF Symbols, system grouped backgrounds, native sheets, Forms, segmented controls, and toolbars.

3. **Private/local confidence**
   Show small status signals like `Local Gemma`, `On-Device`, source counts, and source chips. Do not make privacy copy visually loud.

4. **Student-owned notes**
   Notes should make saved material feel durable and organized. Note text, transcripts, grouped topics, and generated study artifacts are product objects, not temporary chat artifacts.

5. **Low cognitive load**
   Use short labels. Avoid explaining workflows in long paragraphs inside the UI.

## Color

Use system colors wherever possible.

- App background: `Color(.systemGroupedBackground)`
- Primary surface: `Color(.systemBackground)`
- Secondary surface: `Color(.secondarySystemBackground)`
- Accent: `Color.teal`
- Destructive: `Color.red`
- Primary text: `.primary`
- Secondary text: `.secondary`
- Disabled controls: gray opacity around `0.3`

Teal is the brand accent, not the whole palette. Use it for active states, primary buttons, selected tab tint, and trusted model/source indicators.

## Typography

Use system typography.

- Screen title: `.largeTitle.weight(.semibold)`
- Section title: `.headline`
- Row title: `.headline` or `.subheadline.weight(.semibold)`
- Body copy: `.body`
- Supporting copy: `.subheadline` with `.secondary`
- Metadata/chips: `.caption.weight(.medium)` or `.caption.weight(.semibold)`

Do not use viewport-scaled type. Keep compact surfaces compact; reserve large type for actual screen titles.

## Shape And Spacing

- Corner radius: `8` for cards, inputs, and small surfaces.
- Circular icon controls for high-frequency actions.
- Capsule only for prominent full-width primary actions or compact status chips.
- Standard page padding: `16`.
- Compact vertical spacing: `10-16`.
- Avoid nested cards. A card should contain content, not another card-like section.

## App Navigation

The app uses three tabs:

- **Ask**: topic picker, suggested learning actions, local status, recent conversation.
- **Notes**: saved notes, grouped topics, local knowledge-base counts, material capture.
- **Settings**: model status, model setup, local storage counts.

Each tab should represent a stable student workspace. Avoid adding more tabs until the product has a proven need.

## Ask Screen

Ask is suggestions-first learning. It is the main study loop, not an open-ended chatbot.

Current pattern:

- Navigation title: `Accordian`
- Top trailing toolbar:
  - reset conversation: `arrow.counterclockwise`
- Compact session status row:
  - selected model
  - readiness
  - saved note count
- Inline test card:
  - appears immediately after `Quiz`
  - scrolls into focus
  - supports multiple choice, fill-in-the-blank, and short answer
  - shows answer feedback and a `Next Question` action

The student should not need to invent prompts. They choose a topic, then choose a learning move: Teach, Quiz, Cards, or Review.

Avoid exposing raw generated prompts in the conversation. Show clean action labels such as `Test: Photosynthesis` while the app sends the fuller instruction to Gemma behind the scenes.

Mastery is calculated from stored questions and attempts in SQLite. Each question has a topic, subtopic, type, importance, and difficulty. Each attempt updates the local mastery map so Accordian can pick the next useful question without asking the model to make every study decision.

## Suggestions

Suggestions are the main control surface.

Controls:

- Topic chips: `All Notes` plus generated topics.
- Suggestion rows: full-width actions with clear titles and short outcomes.

Behavior:

- Tapping `Quiz` opens an inline test card.
- Tapping explanation or review actions may send a structured prompt.
- Suggestion labels should be specific to the selected topic, for example `Quiz Photosynthesis`.
- Do not show a persistent text box or voice bar on Ask.

## Model Setup

Model setup should be understandable to a nontechnical student.

Modes:

- `Local Server`: current working path. The Mac runs Gemma; the phone connects over Wi-Fi.
- `On Device`: production direction. The phone runs the model locally when mobile runtime support is implemented.

Local Server fields:

- `Mac Address`
- `Model`
- `Send Mac Setup`
- `Save and Test`

Plain-language steps:

1. Send this to your Mac.
2. Paste your Mac address.
3. Save and test.

Avoid exposing raw API endpoints like `/api/chat` in the UI. The user enters the base host, for example `http://192.168.1.10:11434`.

## Library

Library is source-first.

Current pattern:

- Large title: `Library`
- Small source count
- Circular `+` button
- Saved source rows immediately below

Saved source row:

- Icon from source type
- Source title
- Type and status
- 1-2 lines of text preview
- Timestamp

Do not show a large material-type brochure on the Library screen. Material types belong inside Add Material.

## Add Material

Add Material is a capture sheet.

Material types:

- Notes
- PDF
- Audio
- Video
- Link

Current supported flow:

- Notes/text entry
- Audio transcript capture

Audio mode should support:

- `Record Lecture`
- `Stop Recording`
- transcript preview
- `Use transcript`
- `Save Material`

The current implementation saves the transcript as an `Audio` source. Future production work should also save the raw audio file and transcribe/chunk in the background.

Keyboard behavior:

- text fields and text editors have `Done`
- scroll dismisses keyboard interactively
- saving dismisses keyboard first

## Practice

Practice is a focused study surface, not a generic progress page.

Top layout:

- Screen title: `Practice`
- Total card count
- Today card:
  - due count
  - weak-card count
  - play button to return to today's due cards
- Study Set picker:
  - Today
  - All Cards
  - Needs Work
  - generated deck names

The main study area shows exactly one flashcard at a time. A learner should never need to understand deck taxonomy before they can start reviewing.

Review buttons:

- `Missed`: card stays due and becomes weak.
- `Almost`: due tomorrow.
- `Know`: due in 3 days.

Deck rows:

- deck title
- total card count
- selected-state checkmark when active

Selecting a deck should reset the card index and start that study set immediately.

## Flashcards

Flashcards should show learning intent.

Stored fields:

- deck title
- topic
- card type
- front
- back
- source title
- reference text
- due date
- confidence

Card types:

- Definition
- Cause
- Compare
- Process
- Mistake
- Apply
- Recall

UI:

- Front/Back label
- card type chip
- main question/answer in strong title text
- deck title and source title as metadata
- reference excerpt only when useful

## Empty States

Empty states should invite one action.

Good:

- “No study material yet”
- “Add one class source so Waves can ground answers…”

Avoid:

- large decorative art
- multiple competing buttons
- long explanations of future features

## Accessibility

Minimum expectations:

- Every icon-only button has an accessibility label.
- Keyboard can always be dismissed.
- Text fields support selection where setup commands/URLs are shown.

## Current Known Design Debt

- Add Material’s type picker is functional but can become a more guided capture choice.
- Model setup still requires Mac-hosted Ollama for phone use until on-device runtime lands.
- Practice cards need edit/delete controls before this becomes a full study product.

## Design Checklist For New Work

Before shipping a new screen or feature:

- Does the first viewport show the real task?
- Is the primary action obvious?
- Are there fewer words than before?
- Can the keyboard be dismissed easily?
- Does the screen use existing surfaces and spacing?
- Does it preserve local/private trust?
- Does saved student work appear durable and organized?
