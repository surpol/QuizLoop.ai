# iOS Production Runtime: Google AI Edge

QuizLoop's production iOS path is an offline Gemma app:

```text
SwiftUI interface
-> SQLite learning memory
-> Google AI Edge / MediaPipe LLM Inference
-> bundled Gemma model file
```

The web demo can keep using a reachable Gemma endpoint for the video, but the iOS app should not depend on Ollama or a laptop in production.

## Runtime Choice

The Settings screen exposes two runtimes:

- **Gemma Server**: development/demo mode that talks to an Ollama-compatible endpoint.
- **Google AI Edge**: production offline mode that runs a bundled Gemma model on device.

Both modes implement the same `GemmaService` protocol, so the learning framework does not change. Notes, questions, attempts, scores, and feedback stay in SQLite either way.

## Google AI Edge Setup

Google's iOS LLM Inference API currently uses CocoaPods:

```bash
cd QuizLoop.ai
pod install
open QuizLoop.xcworkspace
```

The `Podfile` includes:

```ruby
pod 'MediaPipeTasksGenAI'
pod 'MediaPipeTasksGenAIC'
```

Then add a compatible Gemma model file to the Xcode app target. The Settings screen's **Google AI Edge** mode expects the bundled model filename, for example:

```text
gemma-2-2b-it-8bit.bin
```

Google's docs describe `.bin` support for Gemma 2B / Gemma-2 2B on iOS through MediaPipe LLM Inference, and newer LiteRT / LiteRT-LM paths for edge deployment.

## Implementation Shape

`GoogleAIEdgeGemmaService` lives behind the same `GemmaService` interface as Ollama:

- `reply(to:timeout:)` builds a grounded QuizLoop prompt.
- MediaPipe executes inference on a background task so the UI stays responsive.
- `isModelInstalled()` checks whether the configured model file exists in the app bundle.
- If the MediaPipe pods are not linked, the app reports `AI Edge not linked` instead of pretending the model is ready.

This lets the GitHub repo honestly show the production plan without breaking normal Xcode builds before CocoaPods/model files are installed.

## Why This Matters

QuizLoop is meant to be a private learning assistant. Google AI Edge makes the iOS version match that premise:

- notes stay local
- quiz history stays local
- Gemma inference runs locally
- no laptop or cloud endpoint is required after the app and model are installed

The desktop/web build remains useful for the Kaggle demo because judges can open it immediately, but the iOS implementation is the product-ready offline direction.
