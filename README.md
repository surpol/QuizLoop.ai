# QuizLoop.ai

QuizLoop.ai is a Gemma 4 learning app that turns notes into adaptive quizzes. The product thesis is simple: students should not need to prompt a chatbot to learn. They should be able to add source material, take focused checks, review feedback, and keep moving through a guided learning loop.

This repository contains two surfaces:

- **iOS app**: the product direction and main architecture for the Kaggle writeup. It is built in SwiftUI with local SQLite memory and a `GemmaService` boundary for Gemma runtimes.
- **Web/PWA demo**: the public demo surface used for the video. It mirrors the same learning framework with a browser interface, Cloudflare Pages/Functions support, and a Gemma-compatible backend.

## Kaggle Positioning

Primary track: **Future of Education**.

The project fits this track because it reimagines AI tutoring as an evidence loop instead of chat. Gemma 4 decomposes notes, creates grounded questions, generates distractors, expands quizzes from learning history, and grades open-ended responses. SQLite stores the learner's evidence so future quizzes can target weak concepts and avoid shallow repetition.

The iOS app is designed around a runtime-agnostic `GemmaService` protocol. The competition-facing direction is on-device Gemma 4: the official `gemma-4-E2B-it.litertlm` model through Google AI Edge / LiteRT-LM when the public Swift runtime is available, with a GGUF + `llama.cpp` path kept as the current native fallback. An Ollama-compatible endpoint is available only as a development convenience.

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
Podfile                           Optional iOS dependency path
QuizLoop.xcodeproj                Xcode project with Swift Package dependencies
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
- Swift Package resolution in Xcode
- CocoaPods only if you are experimenting with the optional MediaPipe path
- Optional developer convenience: a local Gemma 4 endpoint

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

### Primary Runtime Target: LiteRT-LM Gemma 4

The production offline target is the official LiteRT-LM Gemma 4 E2B model:

```text
gemma-4-E2B-it.litertlm
```

This model card describes the artifact as ready for deployment on Android, iOS, desktop, IoT, and web, with support for long text context. QuizLoop keeps this behind the `GemmaService` runtime boundary so the learning framework does not change as the public Swift runtime matures.

### Current Native Fallback: GGUF

The current working native fallback is an on-device Gemma 4 GGUF model stored locally and run through `llama.cpp` via `llama.swift`. For a judge/demo build, add the model file below to the Xcode app target so setup is instant and does not depend on a slow first-run download:

```text
gemma-4-e2b-Q4_K_S.gguf
```

The Settings screen detects a packaged model automatically. If the model is not bundled, Settings can still import a local `.gguf` file or use the web download fallback.

### Optional Runtime: Local Development Server

For development, the same `GemmaService` boundary can talk to an Ollama-compatible Gemma endpoint:

```bash
ollama pull gemma4:e2b
ollama serve
```

This is useful while building and debugging, but it is not the core submission architecture. On a physical iPhone, `127.0.0.1` points to the phone, not your Mac. Use your Mac's LAN IP address if you are testing this path.

If you are experimenting with the optional Google AI Edge / MediaPipe path, install pods and open the workspace:

```bash
pod install
open QuizLoop.xcworkspace
```

The app supports runtime modes through the same `GemmaService` protocol:

- **LiteRT-LM**: official Gemma 4 E2B mobile artifact target, using `gemma-4-E2B-it.litertlm`.
- **On-device Gemma**: current native fallback using a local GGUF model through `llama.cpp`/`llama.swift`.
- **Gemma Server**: development-only mode using an Ollama-compatible endpoint.

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
https://accordian-bgp.pages.dev/
```

The hosted web app needs a reachable Gemma-compatible backend for live generation. The public web demo is useful for showing the learning loop, while the iOS app is the product-ready offline direction.

## Gemma 4 Runtime

The iOS app is designed to make Gemma 4 local to the product rather than a cloud chatbot. The preferred official target is LiteRT-LM with `gemma-4-E2B-it.litertlm`; the current working native fallback is GGUF inference through `llama.cpp`/`llama.swift`.

For local development only, you can use an Ollama-compatible endpoint:

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

The iOS runtime path is documented in [docs/ios-google-ai-edge.md](docs/ios-google-ai-edge.md).

## Submission Links

- Live web demo: https://accordian-bgp.pages.dev/
- Kaggle writeup source: [docs/kaggle-report.md](docs/kaggle-report.md)
- iOS edge notes: [docs/ios-google-ai-edge.md](docs/ios-google-ai-edge.md)
- Web deployment notes: [web/DEPLOYMENT.md](web/DEPLOYMENT.md)
