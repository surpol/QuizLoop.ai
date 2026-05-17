# QuizLoop.ai: Evidence-Based Learning with Gemma 4

Subtitle: An iOS-first tutor that turns notes into adaptive quizzes, stores learning evidence in SQLite, and uses Gemma 4 to guide mastery.

## Motivation

QuizLoop.ai was built for the Future of Education track from a classroom problem I saw directly as a programming teacher at theCoderSchool. Students are excited to use AI, but open chat is often a poor learning interface. A student has to know what to ask, paste the right context, judge whether the answer is correct, and then decide how to test themselves. That is too much friction.

QuizLoop changes the interaction. The learner gives the app a stream of text, such as notes, Wikipedia text, a book excerpt, or a math template. The app turns that material into a guided quiz journey. The student does not need to prompt-engineer a tutor. They only need to keep answering checks, reviewing feedback, and moving through the learning loop.

## Product Design

The product is intentionally quiz-first rather than chat-first. Chat is flexible, but it hides whether learning is happening. Quizzes create evidence. Every answer gives the system a signal about what the learner understands, what is weak, and what should be tested next.

The core loop is:

1. Save a note.
2. Let Gemma 4 decompose it into learnable concepts.
3. Generate grounded questions from those concepts.
4. Quiz the learner.
5. Grade the answers.
6. Store the evidence.
7. Build the next quiz from the learner's history.

The interface is kept small: Home, Library, History, and Settings. Home focuses on one active learning journey. Library stores the user's notes and source text. History shows quiz attempts and feedback. Settings controls the model runtime.

## Learning Objects

The technical core is a set of learning objects stored in SQLite:

- `Note`: raw source text, title, source type, processing state, and summary.
- `Topic`: a high-level area extracted from the note.
- `Segment`: the smallest learnable concept anchored to source evidence.
- `Question`: prompt, answer, choices, type, topic, subtopic, segment reference, importance, difficulty, and canonical concept key.
- `Attempt`: the learner's response, score, feedback, timestamp, matched ideas, and missed ideas.
- `QuizSession`: a completed quiz with grouped attempts, score, note relationship, and history.

These objects keep QuizLoop from becoming a random worksheet generator. Questions are durable learning objects. Attempts are evidence. Quiz sessions are memory. SQLite gives Gemma structured context instead of asking the model to infer everything from a loose chat transcript.

## How Gemma 4 Is Used

Gemma 4 is used as bounded intelligence inside the learning system.

During note processing, Gemma receives the note text and returns structured JSON: topics, concepts, grounded questions, correct answers, distractors, importance, difficulty, and source references. The prompt asks Gemma to stay inside the note, avoid meta questions, and produce checks that actually test understanding.

During quiz planning, Gemma and SQLite work together. SQLite provides prior questions, recent attempts, weak concepts, mastered concepts, selected focus, and relevant source excerpts. Gemma uses that context to expand the quiz bank with new, related, or harder questions. If the learner misses an idea, it can return later in another form. If the learner performs well, the next quiz should move to adjacent or more difficult material.

During grading, multiple-choice questions can be scored deterministically. Open-ended answers can be graded by Gemma using the saved answer, source evidence, and a rubric. The goal is semantic grading: did the learner express the idea, not did they match exact wording.

## Quiz Framework

A quiz is not generated from scratch blindly each time. QuizLoop stores a bank of question objects and selects from that bank using understanding score, last-seen time, prior misses, difficulty, importance, and optional focus. The system also rejects weak material before showing it to the learner.

Validation checks include:

- duplicate or near-duplicate prompts
- overlapping answer choices
- answer choices that reveal the correct answer
- questions not grounded in the note
- shallow distractors
- vague practice-plan questions
- repeated concepts inside the same quiz

This validation work was one of the biggest engineering lessons. A good tutor is not just a model call. It is a model call inside a system that can remember, reject, retry, and measure.

## iOS Architecture and Model Runtime

The product-ready direction is the SwiftUI iOS app. It owns the learning interface, local SQLite database, quiz history, and `GemmaService` protocol. `GemmaService` is the boundary that lets the learning engine switch runtimes without rewriting the quiz framework.

The competition-facing runtime direction is on-device Gemma 4. The app is being wired to run a locally stored Gemma 4 GGUF model through a `llama.cpp`-based runtime using `llama.swift`. This is the practical App Store-style direction: notes, quiz history, and inference stay on the device. During development, the same service boundary can also talk to an Ollama-compatible endpoint, but that is a convenience path rather than the product thesis.

We also investigated the Google AI Edge / LiteRT-LM path for Gemma 4 mobile files. The app is structured so that runtime can be added behind the same `GemmaService` boundary when the public Swift/iOS runtime supports the needed format. The key design choice is that the learning system is runtime-agnostic: the memory and quiz engine do not depend on one model host.

## Validation

Testing focused on repeated quiz loops rather than one-off prompts. I used topics such as Photosynthesis, Java basics, LeBron James, Baltimore Ravens, Cleveland Cavaliers, Steve Jobs, Google, clock-hand angle problems, and Pythagorean theorem practice.

The most important bugs were educational: repeated questions, shallow distractors, unsupported facts, quiz banks getting stuck, and progress that did not reflect answers. These failures pushed the system toward canonical concept keys, background quiz expansion, source-grounded validation, history-aware selection, and better quiz reports.

## Impact

QuizLoop.ai reimagines AI tutoring as an evidence loop. The note is the curriculum. Gemma creates and grades bounded checks. SQLite remembers the learner's evidence. The interface keeps the student moving forward without requiring prompt engineering or manual study planning.

For students, this lowers friction. For educators, it suggests a safer classroom pattern: AI can be powerful when it is constrained by source material, structured memory, and measurable learning actions.

## Project Links

- Code repository: https://github.com/surpol/QuizLoop.ai
- Public demo: https://accordian-bgp.pages.dev/
- Primary track: Future of Education
- Technical direction: SwiftUI, SQLite, Gemma 4, on-device GGUF inference through `llama.cpp`/`llama.swift`, and an optional Ollama-compatible development endpoint.
