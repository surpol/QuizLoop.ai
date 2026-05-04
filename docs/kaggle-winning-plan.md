# Waves Kaggle Submission Plan

## Positioning

Waves is an offline-first learning assistant for students without reliable cloud access. The demo should not present it as a generic chatbot. It should present one concrete workflow: a learner asks a question by voice, Gemma explains it simply, checks understanding, and saves useful learning context locally.

## Why It Fits Gemma 4 Good

- Impact: helps self-learners and low-connectivity classrooms get private tutoring support.
- Technical depth: local Gemma runtime through Ollama today, with a path to mobile runtime packaging.
- Trust: setup clearly shows when the model is local, missing, or unavailable.
- Story: the app is useful even without accounts, cloud APIs, or school infrastructure.

## Demo Story

1. Open Waves with Gemma missing and show the setup journey.
2. Install or verify `gemma4:e2b`.
3. Ask a voice question: "Explain fractions like I am new to them."
4. Ask a follow-up: "Quiz me."
5. Show the saved local conversation and explain SQLite memory.
6. Close with the offline classroom use case: private, portable, and low-friction.

## Product Work That Raises Winning Odds

- Add a dedicated Learning Coach mode with explain, quiz, and review actions.
- Add explicit saved insights so users choose what memory persists.
- Add multimodal support for a worksheet photo if the selected Gemma runtime supports image input.
- Add a model package screen for true on-device download once the mobile runtime is selected.
- Add a short evaluation script with example prompts and expected response traits.

## Submission Assets

- Public repo that includes `Waves.xcodeproj`, source, README, and demo instructions.
- 3-minute YouTube demo focused on the learner workflow.
- 1,500-word writeup covering problem, user, architecture, safety, and future deployment.
- Screenshots of setup, voice session, and local history.

## Current Risk

The only `.git` repository is inside `Waves/`, while `Waves.xcodeproj` and the root README are at the project root. Before submission, move git to `/Users/suryapolina/Desktop/kaggle` or relocate the Xcode project into the tracked repository so judges can clone and build the app.
