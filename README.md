# QuizLoop.ai

QuizLoop.ai is a Gemma 4 learning app that turns notes into adaptive quizzes. The product thesis is simple: students should not need to prompt a chatbot to learn. They should be able to add source material, take focused checks, review feedback, and keep moving through a guided learning loop.

This repository contains two surfaces:

- **iOS app**: the product direction and main architecture for the Kaggle writeup. It is built in SwiftUI with local SQLite memory and a `GemmaService` boundary for Gemma runtimes.
- **Web/PWA demo**: the public demo surface used for the video. It mirrors the same learning framework with a browser interface, Cloudflare Pages/Functions support, and a Gemma-compatible backend.

## Kaggle Positioning

Primary track: **Future of Education**.

The project fits this track because it reimagines AI tutoring as an evidence loop instead of chat. Gemma 4 decomposes notes, creates grounded questions, generates distractors, expands quizzes from learning history, and grades open-ended responses. SQLite stores the learner's evidence so future quizzes can target weak concepts and avoid shallow repetition.

The iOS app is designed around a runtime-agnostic `GemmaService` protocol. The competition-facing direction is on-device Gemma 4: the `gemma-4-E2B-it.litertlm` model through LiteRT-LM. QuizLoop uses a text-only LiteRT-LM runner on iPhone, keeps the engine warm between calls, and saves all learning state in SQLite. An Ollama-compatible endpoint is available only as a development convenience.

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
QuizLoop.xcworkspace              Open this in Xcode for normal iOS builds
QuizLoop.xcodeproj                Underlying Xcode project
web/                              PWA demo and Cloudflare backend
docs/kaggle-report.md             Current Kaggle writeup body
docs/ios-google-ai-edge.md        iOS on-device Gemma runtime notes
docs/quiz-lifecycle.md            Quiz creation and scheduling details
docs/tdd/                         Learning-loop test notes
```

## Run the iOS App

The iOS app is the product-ready QuizLoop experience. It can be installed on an iPhone or run in the iOS Simulator from Xcode.

Requirements:

- macOS with Xcode installed
- iOS 17 or newer simulator/device
- A recent iPhone for on-device Gemma 4 E2B inference. The model is large, so newer devices with more memory work best.
- Swift Package resolution in Xcode
- Optional for simulator development: a local Ollama Gemma endpoint

Clone the repo:

```bash
git clone https://github.com/surpol/QuizLoop.ai.git
cd QuizLoop.ai
```

If the workspace is missing or Xcode reports missing Pods, install CocoaPods dependencies once:

```bash
pod install
```

Always open the workspace, not only the project:

```bash
open QuizLoop.xcworkspace
```

### Run on iOS Simulator

The simulator is best for UI testing and fast development. For model generation, use the development Gemma server mode because the simulator can reach your Mac's local Ollama server.

1. Start Ollama on your Mac:

   ```bash
   ollama pull gemma4:e2b
   ollama serve
   ```

2. Confirm the server is reachable:

   ```bash
   curl http://127.0.0.1:11434/api/tags
   ```

3. In Xcode, select:

   ```text
   Scheme: QuizLoop
   Destination: any iPhone Simulator
   ```

4. Press **Run**.
5. In the app, open **Settings -> Model**.
6. Choose **Connect to My Computer** / **Gemma Server**.
7. Use:

   ```text
   Base URL: http://127.0.0.1:11434
   Model: gemma4:e2b
   ```

8. Add a note in **Library**, wait for QuizLoop to create starter questions, then take a quiz from **Home**.

### Run on a Physical iPhone

The physical iPhone path is the production offline direction. It uses the LiteRT-LM Gemma 4 model stored on the phone.

1. Connect the iPhone to your Mac with USB-C or Lightning.
2. Unlock the iPhone and tap **Trust This Computer** if prompted.
3. Open the workspace:

   ```bash
   open QuizLoop.xcworkspace
   ```

4. In Xcode, select:

   ```text
   Scheme: QuizLoop
   Destination: your connected iPhone
   ```

5. Open the QuizLoop target's **Signing & Capabilities** tab.
6. Select your Apple developer team. If Xcode asks, change the bundle identifier to something unique for your account.
7. Press **Run**.
8. If iOS blocks the app, enable Developer Mode or trust the developer profile in iPhone Settings.
9. In QuizLoop, open **Settings -> Model**.
10. Choose **Use LiteRT-LM Gemma 4**.
11. Download, import, or bundle:

   ```text
   gemma-4-E2B-it.litertlm
   ```

12. Tap **Use Model** / **Save and Test**.
13. Return to **Home** or **Library**, add a note, and let QuizLoop create the first quiz bank.

The first on-device quiz build can take roughly 30-45 seconds because Gemma is generating questions locally. After that, QuizLoop keeps the engine warm and saves questions, attempts, feedback, and quiz sessions in SQLite.

### Optional Device Install from Terminal

Use this when you want to build and install without pressing Run in Xcode.

Find the Xcode destination id:

```bash
xcrun xctrace list devices
```

Find the CoreDevice id:

```bash
xcrun devicectl list devices
```

Build for the iPhone:

```bash
xcodebuild \
  -workspace QuizLoop.xcworkspace \
  -scheme QuizLoop \
  -configuration Debug \
  -destination 'id=<XCODE_DEVICE_ID>' \
  build
```

Install and launch:

```bash
APP_PATH=$(find ~/Library/Developer/Xcode/DerivedData -path '*/Build/Products/Debug-iphoneos/QuizLoop.app' -print -quit)
xcrun devicectl device install app --device <COREDEVICE_ID> "$APP_PATH"
xcrun devicectl device process launch --device <COREDEVICE_ID> --terminate-existing --activate com.suryapolina.quizloop
```

The current Xcode project links the LiteRT-LM package path used by the app and includes a build phase that re-signs the nested LiteRT runtime library for device builds.

### Primary Runtime Target: LiteRT-LM Gemma 4

The production offline target is the official LiteRT-LM Gemma 4 E2B model:

```text
gemma-4-E2B-it.litertlm
```

This model card describes the artifact as ready for deployment on Android, iOS, desktop, IoT, and web, with support for long text context. QuizLoop keeps this behind the `GemmaService` runtime boundary so the learning framework does not change if the runtime package changes.

The app can download the `.litertlm` model from **Settings -> Model**, or you can package the model with the app target for a judge/demo build so setup is instant and does not depend on a slow first-run download.

On first local quiz creation, the iPhone may take roughly 30-45 seconds to generate starter questions because Gemma is running on-device. After the engine is warm, QuizLoop reuses the text-only LiteRT-LM engine instead of reloading the model for every request.

### Common iOS Setup Issues

Use these checks before changing code:

- If Xcode cannot find Pods or runtime frameworks, close Xcode and reopen `QuizLoop.xcworkspace`, not `QuizLoop.xcodeproj`.
- If Xcode reports missing package dependencies, use **File -> Packages -> Reset Package Caches**, then **File -> Packages -> Resolve Package Versions**.
- If the iPhone app says **Connect model**, open **Settings -> Model**, choose **Use LiteRT-LM Gemma 4**, and tap **Use Model** / **Save and Test**.
- If the iPhone app says the model is missing, download or import `gemma-4-E2B-it.litertlm`.
- If the simulator cannot reach Gemma Server mode, confirm Ollama is running with `curl http://127.0.0.1:11434/api/tags`.
- If a physical iPhone uses Gemma Server mode, do not use `127.0.0.1`; that points to the phone. Use your Mac's LAN IP address instead.
- If the first note appears stuck on **Creating questions**, leave the app open. The first local LiteRT-LM generation is slower because the model is loading and warming.

### Optional Runtime: Local Development Server

For development, the same `GemmaService` boundary can talk to an Ollama-compatible Gemma endpoint:

```bash
ollama pull gemma4:e2b
ollama serve
```

This is useful while building and debugging, but it is not the core submission architecture. On a physical iPhone, `127.0.0.1` points to the phone, not your Mac. Use your Mac's LAN IP address if you are testing this path.

The app supports runtime modes through the same `GemmaService` protocol:

- **LiteRT-LM**: official Gemma 4 E2B mobile artifact target, using `gemma-4-E2B-it.litertlm`. This is the iOS submission direction.
- **Gemma Server**: development-only mode using an Ollama-compatible endpoint.

The repo still includes CocoaPods files from the earlier MediaPipe exploration, but the working iPhone path is LiteRT-LM.

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

The iOS app is designed to make Gemma 4 local to the product rather than a cloud chatbot. The preferred target is LiteRT-LM with `gemma-4-E2B-it.litertlm`.

Current iOS runtime behavior:

- Uses a direct `CLiteRTLM` text-only runner for `.litertlm` models.
- Passes `nil` for vision/audio runtime backends because QuizLoop currently needs text generation for note decomposition, quiz creation, and grading.
- Reuses a single LiteRT-LM engine across requests to avoid reloading the large model.
- Creates short starter quiz banks on-device first, then stores them in SQLite so users can begin learning.
- Avoids large background expansion prompts on iPhone because they can exceed the mobile runtime context window.

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

## Debugging iPhone Builds

Useful commands:

```bash
xcodebuild -workspace QuizLoop.xcworkspace -scheme QuizLoop -configuration Debug -destination 'id=<DEVICE_ID>' build
xcrun devicectl device install app --device <COREDEVICE_ID> ~/Library/Developer/Xcode/DerivedData/QuizLoop-*/Build/Products/Debug-iphoneos/QuizLoop.app
xcrun devicectl device process launch --device <COREDEVICE_ID> --terminate-existing --activate --console com.suryapolina.quizloop
```

Important logs are prefixed with:

```text
[QuizLoop][Gemma]
[QuizLoop][Tutor]
```

## Submission Links

- Kaggle writeup source: [docs/kaggle-report.md](docs/kaggle-report.md)
- iOS edge notes: [docs/ios-google-ai-edge.md](docs/ios-google-ai-edge.md)
- Web deployment notes: [web/DEPLOYMENT.md](web/DEPLOYMENT.md)
