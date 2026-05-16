# Browser Simulator Demo

QuizLoop is a native SwiftUI iOS app. To make it runnable from a public browser link for Kaggle judges, use Appetize to stream the simulator build.

## Build the Upload Artifact

Run:

```sh
./scripts/package-appetize.sh
```

This creates:

```text
build/appetize/QuizLoop-Appetize.zip
```

That zip contains the iOS Simulator `QuizLoop.app` bundle required by Appetize.

## Upload to Appetize

1. Open `https://appetize.io/upload`.
2. Upload `build/appetize/QuizLoop-Appetize.zip`.
3. Choose platform `iOS`.
4. Make the build runnable by public link.
5. Copy the Appetize app URL or embed URL.

## Embed on a Public Web Page

After upload, replace `YOUR_BUILD_ID` with the Appetize build id:

```html
<iframe
  src="https://appetize.io/embed/YOUR_BUILD_ID?device=iphone13pro&scale=auto&autoplay=false"
  width="390"
  height="844"
  frameborder="0"
  scrolling="no"></iframe>
```

Use the Appetize URL in the Kaggle writeup and video description so judges can run the native app without Xcode.

## Notes for Demo Quality

- The streamed app is the native SwiftUI app, not a web rewrite.
- Local Gemma/Ollama on the Mac will not be available inside Appetize unless we add a hosted model endpoint or on-device model runtime.
- For a reliable public demo, include preloaded sample notes and quizzes in the app, or configure a reachable inference endpoint before uploading.
