# QuizLoop.ai

QuizLoop.ai is a Gemma 4 learning assistant that turns notes into adaptive quizzes. The product thesis is simple: students should not need to prompt a chatbot to learn. They should be able to add source material, take short checks, review feedback, and keep moving through a guided learning loop.

This repository contains two surfaces:

- **iOS app**: the product direction and main architecture for the Kaggle writeup. It is built in SwiftUI with local SQLite memory and a `GemmaService` boundary for Gemma runtimes.
- **Web/PWA demo**: the public demo surface used for the video. It mirrors the same learning framework with Cloudflare Pages, Cloudflare Functions, D1, and a Gemma-compatible endpoint.

## Kaggle Positioning

Primary track: **Future of Education**.

The project fits this track because it reimagines AI tutoring as an evidence loop instead of chat. Gemma 4 decomposes notes, creates grounded questions, generates distractors, expands quizzes from learning history, and grades open-ended responses. SQLite stores the learner's evidence so future quizzes can target weak concepts and avoid shallow repetition.

The iOS app also includes a Google AI Edge / MediaPipe runtime path for a bundled Gemma model. That path is documented as the production offline direction, while the web app remains the easiest public artifact for judges to open during the video.

## Architecture

```text
Source material
  -> Note object
  -> Gemma 4 decomposition
  -> Topics / segments / question objects
  -> Quiz sessions
  -> Attempts, scores, feedback
  -> SQLite memory
  -> Next personalized quiz
```

Key objects:

- `Note`: raw learning material from pasted text, Wikipedia, books, or math templates.
- `Topic`: high-level grouping from the note.
- `Segment`: small source-grounded concept.
- `Question`: durable quiz object with prompt, answer, choices, topic, difficulty, and canonical concept key.
- `Attempt`: learner answer, score, feedback, and timestamp.
- `QuizSession`: one completed quiz and its grouped attempts.

## Repository Map

```text
AppView.swift, QuizLoopApp.swift     SwiftUI app entry points
Features/                         iOS feature screens
Models/                           Learning objects and runtime configuration
Services/                         SQLite store, TutorEngine, Gemma services
Views/                            Shared SwiftUI views
Podfile                           Google AI Edge / MediaPipe iOS dependencies
web/                              PWA demo and Cloudflare backend
docs/kaggle-report.md             Current Kaggle writeup body
docs/ios-google-ai-edge.md        iOS on-device Gemma runtime notes
docs/quiz-lifecycle.md            Quiz creation and scheduling details
docs/tdd/                         Learning-loop test notes
```

## Install the iOS App

The iOS app is the product-ready QuizLoop experience. It can be installed on an iPhone or run in the iOS Simulator from Xcode.

Requirements:

- macOS with Xcode installed
- iOS 17 or newer simulator/device
- CocoaPods for the Google AI Edge dependency path
- Optional for development: Ollama with `gemma4:e2b`

Clone the repo:

```bash
git clone https://github.com/surpol/QuizLoop.ai.git
cd QuizLoop.ai
```

Run the app in Xcode:

```bash
open QuizLoop.xcodeproj
```

Then choose an iPhone simulator or a connected iPhone and press **Run**.

For local development with Ollama, start Gemma first:

```bash
ollama pull gemma4:e2b
ollama serve
```

In the app, open **Settings**, choose **Gemma Server**, and use the local Ollama endpoint while developing.

For the production offline / on-device path, install the Google AI Edge dependencies and open the workspace:

```bash
pod install
open QuizLoop.xcworkspace
```

Then add a compatible Gemma model file to the Xcode app target and switch the app to **Google AI Edge** mode in Settings. The goal of this path is that notes, quiz history, and inference all stay on the device.

The app supports two runtime modes through the same `GemmaService` protocol:

- **Gemma Server**: development mode using an Ollama-compatible endpoint.
- **Google AI Edge**: production offline path designed to load a bundled Gemma model through MediaPipe.

## Run the Web Demo

```bash
cd web
npm run dev
```

Open:

```text
http://localhost:4173
```

Public demo:

```text
https://quizloop.ai
```

The hosted web app needs a reachable Gemma-compatible endpoint for live generation. The current demo endpoint is protected by a token and is intended for the app backend, not raw browser use.

## Gemma 4 Runtime

Local development uses Ollama:

```bash
ollama pull gemma4:e2b
ollama serve
```

The web backend reads:

```text
GEMMA_BASE_URL
GEMMA_API_TOKEN
GEMMA_MODEL=gemma4:e2b
```

The iOS production path is documented in [docs/ios-google-ai-edge.md](docs/ios-google-ai-edge.md).

## Submission Links

- Live web demo: https://quizloop.ai
- Kaggle writeup source: [docs/kaggle-report.md](docs/kaggle-report.md)
- iOS edge notes: [docs/ios-google-ai-edge.md](docs/ios-google-ai-edge.md)
- Web deployment notes: [web/DEPLOYMENT.md](web/DEPLOYMENT.md)
