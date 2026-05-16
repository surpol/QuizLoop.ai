# Kaggle Submission Package

## Submission Strategy

Use the **web product for the video** because it is easy to record and share.

Feature the **iOS app in the writeup and repository** because it is the product-ready direction: SwiftUI, SQLite memory, Gemma runtime abstraction, and a Google AI Edge path for bundled on-device inference.

The strongest message is:

> QuizLoop.ai is an iOS-first learning assistant that uses Gemma 4 to turn notes into adaptive quizzes. The web demo shows the same learning loop publicly for the video.

## Track

Primary track:

`Future of Education`

Why:

- The app changes the learning interface from open-ended chat to guided checks.
- Gemma 4 acts as a bounded learning agent, not a generic chatbot.
- SQLite memory lets quizzes adapt to each learner's attempts.
- Educators can understand the evidence trail: notes, questions, attempts, feedback, and quiz history.

Secondary technical angle:

`Google AI Edge / LiteRT direction`

Only describe this as the iOS production path unless the bundled model is fully installed and demonstrated. The repo is honest: the app has a `GemmaService` boundary and Google AI Edge / MediaPipe setup notes, while the public web demo uses a Gemma-compatible endpoint.

## Kaggle Writeup Fields

Title:

`QuizLoop.ai: A Gemma 4 Learning Loop for Evidence-Based Studying`

Subtitle:

`An iOS-first Gemma 4 tutor with SQLite memory, adaptive quizzes, and a public web demo.`

Track:

`Future of Education`

Body:

Paste the contents of:

```text
docs/kaggle-report.md
```

## Required Attachments

- Public video, 3 minutes or less.
- Code repository: `https://github.com/surpol/QuizLoop`
- Live demo: `https://quizloop.ai`
- Cover image.
- Media gallery screenshots.

The overview says project links are provided **if applicable**. A hosted web app is useful, but the submission is judged primarily through the video, writeup, and repository.

## Project Links

- Live demo: `https://quizloop.ai`
- Code repository: `https://github.com/surpol/QuizLoop`
- Demo Gemma endpoint: `https://gemma-quizloop.suryapolina.com`

Important: the Gemma endpoint is protected and meant for the app backend, not raw browser access. A direct browser visit can return `Unauthorized model request`, which is expected.

## Video Structure

0:00-0:25 Problem:
Students use chatbots, but chat makes them decide what to ask and how to test themselves.

0:25-0:50 Product thesis:
QuizLoop turns notes into a guided quiz journey. No prompt engineering.

0:50-1:50 Web demo:
Import or paste a topic, show Gemma building checks, take a quiz, submit answers, show feedback/history.

1:50-2:25 Technical proof:
Gemma 4 creates questions, expands quizzes, and grades answers. SQLite stores notes, questions, attempts, feedback, and history.

2:25-2:50 iOS/product direction:
The iOS app uses the same learning framework with local SQLite and a Gemma runtime boundary for offline/on-device deployment.

2:50-3:00 Close:
The note is the curriculum. Gemma writes and grades the checks. SQLite remembers the learning journey.

## Repo Review Path for Judges

Start here:

```text
README.md
```

Then:

```text
docs/kaggle-report.md
docs/ios-google-ai-edge.md
docs/quiz-lifecycle.md
web/README.md
```

## Do Not Overclaim

Say:

> The public web demo uses a reachable Gemma-compatible endpoint. The iOS app is structured for a bundled on-device Gemma model through Google AI Edge / MediaPipe.

Do not say:

> The public website runs Gemma fully offline in the browser.

Do not say:

> Judges can rely on the public model endpoint if the laptop is off.

That endpoint currently depends on an always-running model host. For the video, this is acceptable if the demo is recorded. For live judging, keep the repo and writeup clear that the web app is a public companion demo.
