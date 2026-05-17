# iOS Production Runtime: LiteRT-LM Gemma 4

QuizLoop's production iOS path is an offline Gemma app:

```text
SwiftUI interface
-> SQLite learning memory
-> Google AI Edge / LiteRT-LM
-> bundled or imported gemma-4-E2B-it.litertlm
```

The web demo can keep using a reachable Gemma endpoint for the video, but the iOS app should not depend on Ollama or a laptop in production.

## Runtime Choice

The Settings screen exposes three runtimes behind the same `GemmaService` protocol:

- **On-device Gemma**: production path that runs a local GGUF model through `llama.cpp` / `llama.swift`.
- **Gemma Server**: development/demo mode that talks to an Ollama-compatible endpoint.
- **Google AI Edge / LiteRT-LM**: official Gemma 4 E2B mobile model target using `gemma-4-E2B-it.litertlm`.

The learning framework does not change between runtimes. Notes, questions, attempts, scores, and feedback stay in SQLite either way.

## LiteRT-LM Setup

The target model file is:

```text
gemma-4-E2B-it.litertlm
```

The model card describes it as ready for Android, iOS, desktop, IoT, and web deployment, with long-context text support. QuizLoop now exposes this as a separate setup path in Settings.

The remaining risk is runtime availability: the public LiteRT-LM repository currently lists Swift as in development, while Kotlin, Python, and C++ are stable. QuizLoop keeps this path behind `GemmaService` so the app can adopt the public Swift runtime when it lands, or a vendored native runtime if we decide to build from source.

## Packaged GGUF Fallback

Until the public Swift LiteRT-LM runtime is ready for the app, the current native fallback is a packaged GGUF model through `llama.cpp` / `llama.swift`. For the most reliable judge/demo build, package the model with the app instead of asking the user to download a large file on first launch.

1. Add this file to the Xcode app target:

```text
gemma-4-e2b-Q4_K_S.gguf
```

2. Build and run the app.
3. Open Settings -> Model.
4. QuizLoop detects the packaged model and validates it before marking Gemma ready.

If the model is not bundled, Settings can import a `.gguf` file from Files or use the web download fallback. The fallback is useful for development, but packaged model delivery is the lower-friction production path.

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

Google's docs describe `.bin` support for Gemma 2B / Gemma-2 2B on iOS through MediaPipe LLM Inference, and newer LiteRT / LiteRT-LM paths for edge deployment. QuizLoop keeps this runtime behind the same service boundary so it can be used when the public iOS runtime supports the required Gemma 4 mobile format.

## Implementation Shape

`GoogleAIEdgeGemmaService` lives behind the same `GemmaService` interface as Ollama:

- `reply(to:timeout:)` builds a grounded QuizLoop prompt.
- MediaPipe executes inference on a background task so the UI stays responsive.
- `isModelInstalled()` checks whether the configured model file exists in the app bundle.
- If the MediaPipe pods are not linked, the app reports `AI Edge not linked` instead of pretending the model is ready.

This lets the GitHub repo honestly show the production plan without breaking normal Xcode builds before CocoaPods/model files are installed.

## Why This Matters

QuizLoop is meant to be a private learning assistant. On-device Gemma makes the iOS version match that premise:

- notes stay local
- quiz history stays local
- Gemma inference runs locally
- no laptop or cloud endpoint is required after the app and model are installed

The desktop/web build remains useful for the Kaggle demo because judges can open it immediately, but the iOS implementation is the product-ready offline direction.
