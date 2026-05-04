# Waves Student Experience Design

## Product Thesis

Waves should feel like a private study companion, not a chat app. The student brings their class context, asks questions by voice or text, and Waves turns that context into explanations, quizzes, flashcards, study plans, and review loops that work offline.

The winning version is simple on the surface and strong underneath:

- one calm assistant screen for asking and learning
- one library for study materials, saved cards, quizzes, and notes
- one local memory/RAG layer that grounds answers in the student's own context

## Primary Student Jobs

1. "Help me understand this."
   - The student asks a question or photographs/pastes class material.
   - Waves explains at the right level and asks a quick check question.

2. "Help me remember this."
   - Waves turns an answer, syllabus section, video notes, or worksheet into flashcards.
   - The student reviews cards using spaced repetition.

3. "Help me prepare."
   - Waves builds a quiz from uploaded context.
   - It scores answers, explains mistakes, and saves weak topics.

4. "Help me plan."
   - The student adds a syllabus, exam date, or assignment list.
   - Waves creates a study plan and adapts it based on quiz performance.

## App Structure

### Today

The app opens into the assistant because the product must be instantly useful.

### Next

Use a three-tab structure:

- Ask: voice/text assistant, camera/document input, answer actions
- Practice: flashcards, quizzes, weak-topic review
- Library: syllabus, documents, video notes, saved conversations, local memory settings

This keeps the main interaction simple while giving students a place to return to their study assets.

## Ask Screen

The Ask screen should stay minimal.

Core controls:

- mic button
- message field
- add context button
- send button

After a Waves response, show three compact actions:

- Make Flashcards
- Quiz Me
- Save Insight

Do not overload the composer with modes. The student should ask naturally, then choose what to do with the answer.

## Personal RAG System

Yes, Waves needs a personal RAG system. This is how it stops being a generic assistant and becomes a student's assistant.

### User Inputs

Support these context sources in order:

1. pasted text
2. photos/screenshots of worksheets or notes
3. PDFs and syllabus files
4. web links or YouTube/video transcripts
5. voice notes

For the hackathon prototype, prioritize pasted text, photos, and PDFs. Video support can start as transcript paste/import rather than full video processing.

### Local Data Model

Store everything locally:

- StudySource: title, type, created date, original file path, extracted text
- StudyChunk: source id, chunk text, position, embedding vector or lexical index terms
- SavedInsight: short memory chosen by the user
- Flashcard: front, back, source id, next review date, confidence
- QuizAttempt: prompt, answer, score, feedback, weak topic

### Retrieval Flow

1. Student asks a question.
2. Waves searches local study chunks and saved insights.
3. The prompt includes the most relevant snippets with source labels.
4. Gemma answers using the snippets and says when the context is insufficient.
5. The student can save the answer, generate cards, or quiz themselves.

### Trust UX

Every grounded answer should show a small source indicator:

- "Using: Biology Syllabus, Chapter 3 Notes"
- "No class context found"

This matters for Kaggle because it demonstrates safety, trust, and technical depth.

## Flashcards

Flashcards should be a first-class experience, not just generated text.

Card generation:

- From any answer
- From selected document sections
- From quiz mistakes

Review UX:

- front/back card
- Again, Hard, Good buttons
- small daily target
- weak-topic queue

Minimal spaced repetition:

- Again: review today
- Hard: review tomorrow
- Good: review in 3 days

## Quizzes

Quiz types:

- quick oral quiz after an explanation
- multiple-choice quiz from context
- short-answer quiz for deeper learning

The best hackathon demo is short-answer because it shows Gemma reasoning:

1. Waves asks a question grounded in the student's material.
2. Student answers by voice.
3. Waves scores the answer, explains what was missing, and saves the weak topic.

## Onboarding

Onboarding should be functional, not decorative.

Steps:

1. Set up local Gemma.
2. Add first study context.
3. Ask first question.
4. Generate first practice item.

The "aha" moment should happen within one minute: a student adds a syllabus or note and gets a useful quiz or flashcards from it.

## Competition Demo Flow

Use one fictional but realistic student:

"Maya has a biology test, weak internet at home, and a PDF syllabus plus class notes."

Demo:

1. Open Waves and show local Gemma readiness.
2. Add a biology syllabus/context snippet.
3. Ask: "Explain cellular respiration simply."
4. Waves answers with source context.
5. Tap Quiz Me.
6. Student answers by voice.
7. Waves gives feedback and saves "ATP production steps" as a weak topic.
8. Tap Make Flashcards.
9. Show the Practice tab with generated cards.

## Implementation Task List

### Foundation

- [ ] Move git to the project root or move `Waves.xcodeproj` into the tracked repo.
- [ ] Add a three-tab shell: Ask, Practice, Library.
- [ ] Keep the existing Ask screen minimal and voice-first.
- [ ] Add a source/context import model.
- [ ] Extend SQLite schema for sources, chunks, insights, flashcards, and quiz attempts.

### RAG

- [ ] Add pasted-text context import.
- [ ] Add local chunking for imported text.
- [ ] Add simple local retrieval using keyword scoring first.
- [ ] Add source labels to Gemma prompts.
- [ ] Show source chips under grounded answers.
- [ ] Later: add embeddings if the runtime/package choice supports it cleanly.

### Practice

- [ ] Add Flashcard model and SQLite persistence.
- [ ] Add "Make Flashcards" action on assistant responses.
- [ ] Add Practice tab with review queue.
- [ ] Add Again, Hard, Good buttons.
- [ ] Add Quiz model and short-answer quiz flow.
- [ ] Save weak topics from quiz feedback.

### UX Polish

- [ ] Replace broad mode picker with contextual actions.
- [ ] Add an Add Context button to the composer.
- [ ] Add Library screen for imported materials.
- [ ] Add empty states that invite one useful action.
- [ ] Add privacy/local indicators without making the UI noisy.

### Kaggle Submission

- [ ] Record a 3-minute story-driven demo.
- [ ] Include architecture diagram in README.
- [ ] Include local setup instructions for Gemma.
- [ ] Include example study materials for reproducible demo.
- [ ] Include evaluation prompts and expected behavior.

## Design Principle

Make the interface feel calm enough for a tired student, but make every answer actionable. The student should never wonder, "What do I do with this response?" They should always have a next learning move: save it, quiz it, card it, or plan from it.
