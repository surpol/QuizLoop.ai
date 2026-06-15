# QuizLoop Web

Browser version of QuizLoop for public demos and the Build with Gemini XPRIZE business surface.

It keeps the same core architecture as the iOS app:

- Gemma creates the quiz bank from pasted notes.
- SQLite stores notes, questions, attempts, and quiz sessions.
- The learner takes quizzes against saved questions.
- Quiz history becomes the evidence of understanding.

## Run Locally

```sh
npm run dev
```

Open:

```text
http://localhost:4173
```

## Model

By default the server calls:

```text
http://127.0.0.1:11434/api/chat
```

with model:

```text
gemma4:e2b
```

Override with:

```sh
GEMMA_BASE_URL=https://your-model-host.example GEMMA_MODEL=gemma4:e2b npm run dev
```

## Gemini Business Layer

The XPRIZE path requires Gemini in the deployed product. The web backend includes Gemini-powered learner reports and evidence export routes:

```text
GET  /api/evidence
POST /api/notes/:noteId/learner-report
```

Configure Gemini with:

```sh
GEMINI_API_KEY=your_key GEMINI_MODEL=gemini-2.5-flash npm run dev
```

`/api/evidence` summarizes notes, quizzes, attempts, model runs, and user actions. `/api/notes/:noteId/learner-report` asks Gemini to turn saved quiz history into a plain-language learner report, then logs that model run for competition evidence.

## SQLite

The database is created here:

```text
web/data/quizloop.sqlite
```

Tables:

- `notes`
- `questions`
- `attempts`
- `quiz_sessions`
- `model_runs`
- `user_actions`

## Certification Question Sources

For certification prep, avoid exam dump sites. QuizLoop should use legitimate sources:

- Official exam guides define the domains, scope, question types, and weighting.
- Licensed practice banks can provide concrete practice questions.
- Gemma/Gemini can explain, personalize, grade, and generate learner reports, but certification quizzes are now source-bank first. If enough licensed or QuizLoop-curated questions exist, the next quiz is queued from SQLite instead of asking AI to invent more questions.
- Every imported or curated certification question is stored with provenance fields: provider, URL, license, license URL, and provenance kind.

The Cloud Practitioner starter bank can be imported from CloudCertPrep, an MIT-licensed CLF-C02 practice bank:

```sh
npm run import:clf-c02
```

The Solutions Architect starter bank can be imported the same way:

```sh
npm run import:saa-c03
```

These scripts import single-answer multiple-choice questions into the local SQLite database and record third-party attribution in [THIRD_PARTY_NOTICES.md](./THIRD_PARTY_NOTICES.md). Multi-answer questions are skipped until the UI supports multi-select exams.

To verify the certification experience after changing quiz logic, run the app and then audit back-to-back Cloud Practitioner and Solutions Architect quizzes:

```sh
npm run audit:certs
```

The audit fails if a certification quiz is shorter than 10 questions, repeats prompts or question IDs across consecutive quizzes, serves AI-supplemental certification questions while source-bank questions are available, scores an all-correct submission incorrectly, or fails to prepare the next quiz.

## Public Demo Path

For a domain, deploy this folder to a server that can run Node and write SQLite data. The public server also needs a reachable Gemma-compatible endpoint; judges cannot access your Mac's local development server.

See [DEPLOYMENT.md](./DEPLOYMENT.md) for Docker and Render deployment.

For free stable hosting, this repo also includes a Cloudflare Pages/Functions/D1 path:

```text
functions/api/[[path]].js
cloudflare/schema.sql
wrangler.toml
```

Cloudflare gives a stable `pages.dev` URL, while D1 can replace the local SQLite file for the hosted version.

## Deploy

The repository includes a Render blueprint at the repo root:

```text
render.yaml
```

Fast path:

```text
https://github.com/surpol/QuizLoop.ai
```

After pushing to GitHub, create a Render Blueprint from the repo and set `GEMMA_BASE_URL` to a public Gemma-compatible endpoint.

Render gives the app a stable `onrender.com` URL for as long as the service exists. Unlike ngrok's random free tunnel URLs, this URL will not change every time you restart your laptop.
