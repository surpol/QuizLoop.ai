# Waves Design System

## Product Feel

Waves should feel like a quiet Apple-native study tool: calm, local, private, and useful immediately. The UI should never feel like a marketing site or a generic chatbot wrapper. Every screen should help a student do one of three things:

- ask a question
- add study context
- practice what they need to remember

The design language is minimal, spacious enough to read, but not wasteful. Avoid decorative gradients, hero panels, oversized empty states, and explanatory blocks that repeat what the controls already say.

## Visual Principles

1. **Utility first**
   The first screen is the assistant, not a landing page. The primary action should always be visible.

2. **Native over custom**
   Prefer SwiftUI system controls, SF Symbols, system grouped backgrounds, native sheets, Forms, segmented controls, and toolbars.

3. **Private/local confidence**
   Show small status signals like `Local Gemma`, `On-Device`, source counts, and source chips. Do not make privacy copy visually loud.

4. **Student-owned memory**
   Library and Practice should make saved material feel durable and organized. Sources, flashcards, transcripts, and review status are product objects, not temporary chat artifacts.

5. **Low cognitive load**
   Use short labels. Avoid explaining workflows in long paragraphs inside the UI.

## Color

Use system colors wherever possible.

- App background: `Color(.systemGroupedBackground)`
- Primary surface: `Color(.systemBackground)`
- Secondary surface: `Color(.secondarySystemBackground)`
- Accent: `Color.teal`
- Destructive/recording: `Color.red`
- Primary text: `.primary`
- Secondary text: `.secondary`
- Disabled controls: gray opacity around `0.3`

Teal is the brand accent, not the whole palette. Use it for active states, primary buttons, selected tab tint, recording/voice accents, and trusted model/source indicators.

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

- **Ask**: assistant, voice/text composer, add material, voice/model settings.
- **Practice**: due queue, topic/source/weak flashcard decks.
- **Library**: saved sources and material capture.

Each tab should represent a stable student workspace. Avoid adding more tabs until the product has a proven need.

## Ask Screen

Ask is chat-first.

Current pattern:

- Navigation title: `Waves`
- Top trailing toolbar:
  - model setup: `server.rack`
  - voice controls: `speaker.wave.2`
  - reset conversation: `arrow.counterclockwise`
- Compact session status row:
  - `Local Gemma` or `On-Device`
  - saved source count
- Conversation bubbles:
  - learner: teal bubble, right aligned
  - Waves: secondary surface bubble, left aligned
- Latest Waves response can show:
  - `Flashcards`
  - `Quiz Me`
  - `Save`

Only the latest actionable assistant response should show action buttons. Showing actions under every historical message makes the chat noisy.

## Composer

The composer is the main control surface.

Controls:

- Mic: large teal circle, red when recording.
- Add material: small circular `plus`.
- Voice toggle/settings: small circular speaker icon.
- Message field: rounded rectangle.
- Close keyboard: `keyboard.chevron.compact.down`, visible while typing.
- Send: circular `arrow.up`, disabled when empty.

Behavior:

- Submitting text dismisses the keyboard.
- Scrolling the conversation dismisses the keyboard interactively.
- Keyboard toolbar includes `Done`.
- Recording transcript can appear as the text field placeholder.

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

## Voice

Voice should support accessibility and feel calm.

Defaults:

- Auto-speak on.
- Speech rate around `0.39`.
- Prefer premium or enhanced US English voices.
- Natural pitch: `1.0`.
- Small pre/post utterance pauses.

Voice controls:

- `Read answers aloud`
- `Voice speed`
- `Preview Voice`
- `Stop Speaking`

Answers should be cleaned before speech:

- remove markdown marks
- remove bullets when possible
- convert `Front:` and `Back:` into spoken sentences
- avoid reading UI labels awkwardly

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

Practice is a flashcard organizer, not a generic progress page.

Top layout:

- Screen title: `Practice`
- Total card count
- compact metrics:
  - Due
  - Cards
  - Weak
- Segmented control:
  - Due
  - Topics
  - Sources
  - Weak

Review buttons:

- `Again`: missed it; card stays due and becomes weak.
- `Hard`: remembered with effort; due tomorrow.
- `Good`: remembered; due in 3 days.

Deck rows:

- deck/source title
- due count
- total card count
- weak count when applicable
- chevron for focus

Selecting a deck should focus the review session and show a compact selected-deck banner with a clear close button.

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
- Voice can be stopped.
- Text fields support selection where setup commands/URLs are shown.
- Recording state is visible through text, color, and icon, not color alone.

## Current Known Design Debt

- Add Material’s type picker is functional but can become a more guided capture choice.
- Audio capture currently stores transcript only, not raw audio.
- Model setup still requires Mac-hosted Ollama for phone use until on-device runtime lands.
- Long lecture recording needs background transcription and chunking.
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
