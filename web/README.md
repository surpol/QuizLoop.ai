# Accordian Web

Browser version of Accordian for the Kaggle demo.

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

For a domain, deploy this folder to a server that can run Node and write SQLite data. The public server also needs a reachable Gemma-compatible endpoint; judges cannot access your Mac's local Ollama server.

See [DEPLOYMENT.md](./DEPLOYMENT.md) for Docker and Render deployment.

## Deploy

The repository includes a Render blueprint at the repo root:

```text
render.yaml
```

After pushing to GitHub, create a Render Blueprint from the repo and set `GEMMA_BASE_URL` to a public Gemma/Ollama-compatible endpoint.
