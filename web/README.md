# QuizLoop Web

Browser version of QuizLoop for the Kaggle video demo.

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

## SQLite

The database is created here:

```text
web/data/accordian.sqlite
```

Tables:

- `notes`
- `questions`
- `attempts`
- `quiz_sessions`

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
