# Deploy QuizLoop Web

QuizLoop Web is a Node service with a static PWA frontend, SQLite storage, and a Gemma-compatible chat endpoint.

## Production Requirements

- Node 22 or Docker.
- `sqlite3` command-line binary.
- Writable disk for SQLite.
- A public HTTPS Gemma/Ollama-compatible endpoint.

The app cannot use your Mac's `http://127.0.0.1:11434` Ollama endpoint after it is deployed. In production, set:

```sh
GEMMA_BASE_URL=https://your-gemma-host.example
GEMMA_MODEL=gemma4:e2b
GEMINI_API_KEY=your-gemini-api-key
GEMINI_MODEL=gemini-2.5-flash
```

## Environment Variables

```text
HOST=0.0.0.0
PORT=4173
QUIZLOOP_DB_PATH=/data/quizloop.sqlite
GEMMA_BASE_URL=https://your-gemma-host.example
GEMMA_MODEL=gemma4:e2b
```

## Docker

From `web/`:

```sh
docker build -t quizloop-web .
docker run --rm -p 4173:4173 \
  -v quizloop-data:/data \
  -e GEMMA_BASE_URL=https://your-gemma-host.example \
  -e GEMMA_MODEL=gemma4:e2b \
  quizloop-web
```

Open:

```text
http://localhost:4173
```

## Render Blueprint

This repo includes `render.yaml` at the repo root. On Render:

1. Open the one-click deploy link:

   ```text
   https://render.com/deploy?repo=https://github.com/surpol/QuizLoop.ai
   ```

2. Choose the `QuizLoop.ai` repo and confirm the blueprint.
3. Set `GEMMA_BASE_URL` to your public Gemma/Ollama-compatible endpoint.
4. Deploy.

Render will use `web/Dockerfile` and health-check `/api/health`.

The deployed app receives a stable Render URL such as:

```text
https://quizloop-web.onrender.com
```

This URL remains stable while the Render service exists. This is the correct replacement for an ngrok URL when the demo link must not change.

### Free vs Durable

Render Free web services can provide a stable URL, but they spin down when idle and their local filesystem is ephemeral. That means SQLite data is not durable on the Free service type. Durable SQLite requires a paid web service with a persistent disk, or a database migration to hosted Postgres.

The current blueprint is configured for free hosting. It intentionally does not attach a persistent disk, so the hosted demo can reset its SQLite memory when Render restarts or redeploys.

### Important Gemma Note

`http://127.0.0.1:11434` only works on your Mac. A public deployment cannot reach that address.

For the Kaggle demo, use one of these:

- A public VM running Ollama/Gemma behind HTTPS.
- A hosted Gemma-compatible inference endpoint.
- A temporary tunnel to a machine running Ollama for demo purposes.

The web app stores learner memory in SQLite on the Render disk. The model endpoint provides intelligence; SQLite provides durable memory.

## XPRIZE Evidence Endpoints

The deployed business surface should expose proof that the product is operating with AI:

```text
GET  /api/evidence
POST /api/notes/:noteId/learner-report
```

`/api/evidence` returns saved product activity: notes, quizzes, attempts, model runs, and user actions. `/api/notes/:noteId/learner-report` uses the Gemini API to generate a learner-facing report from SQLite quiz history and records the run in `model_runs`.

## Cloudflare Free Hosting

Cloudflare is the best free stable-URL path if we accept a Cloudflare-native backend:

- Cloudflare Pages hosts the PWA at a stable `*.pages.dev` URL.
- Cloudflare Functions handle `/api/*`.
- Cloudflare D1 stores notes, questions, attempts, and quiz history.
- `GEMMA_BASE_URL` must still point to a public Gemma/Ollama-compatible endpoint.

This repo includes:

```text
web/functions/api/[[path]].js
web/cloudflare/schema.sql
web/wrangler.toml
```

### Deploy From Dashboard

1. Open Cloudflare Dashboard.
2. Go to **Workers & Pages**.
3. Create a **Pages** project connected to `surpol/QuizLoop.ai`.
4. Set root directory to:

   ```text
   web
   ```

5. Set build command to blank or:

   ```text
   :
   ```

6. Set output directory to:

   ```text
   public
   ```

7. Add a D1 database named:

   ```text
   quizloop-ai
   ```

8. Bind it to the Pages project as:

   ```text
   DB
   ```

   Use the Cloudflare dashboard binding. The included `wrangler.toml` intentionally does not include a placeholder D1 database ID, because Cloudflare requires a real database ID when bindings are configured in Wrangler.

9. Run the schema in D1:

   ```text
   web/cloudflare/schema.sql
   ```

10. Add environment variables:

   ```text
   GEMMA_BASE_URL=https://your-public-gemma-host.example
   GEMMA_MODEL=gemma4:e2b
   ```

11. Deploy.

The hosted app URL will look like:

```text
https://quizloop-ai.pages.dev
```

### Cloudflare Limitation

Cloudflare cannot run Ollama locally inside Pages or Workers. The deployed app needs an external Gemma-compatible model endpoint. If `GEMMA_BASE_URL` is missing, the Cloudflare function keeps the interface testable with a tiny emergency quiz builder, but the competition demo should use Gemma.

## Health Check

```text
/api/health
```

returns the app status, configured model, and database path.
