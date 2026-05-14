# Deploy Accordian Web

Accordian Web is a Node service with a static PWA frontend, SQLite storage, and a Gemma-compatible chat endpoint.

## Production Requirements

- Node 22 or Docker.
- `sqlite3` command-line binary.
- Writable disk for SQLite.
- A public HTTPS Gemma/Ollama-compatible endpoint.

The app cannot use your Mac's `http://127.0.0.1:11434` Ollama endpoint after it is deployed. In production, set:

```sh
GEMMA_BASE_URL=https://your-gemma-host.example
GEMMA_MODEL=gemma4:e2b
```

## Environment Variables

```text
HOST=0.0.0.0
PORT=4173
ACCORDIAN_DB_PATH=/data/accordian.sqlite
GEMMA_BASE_URL=https://your-gemma-host.example
GEMMA_MODEL=gemma4:e2b
```

## Docker

From `web/`:

```sh
docker build -t accordian-web .
docker run --rm -p 4173:4173 \
  -v accordian-data:/data \
  -e GEMMA_BASE_URL=https://your-gemma-host.example \
  -e GEMMA_MODEL=gemma4:e2b \
  accordian-web
```

Open:

```text
http://localhost:4173
```

## Render Blueprint

This repo includes `render.yaml` at the repo root. On Render:

1. Create a Blueprint from the GitHub repo.
2. Choose the `Accordian` repo and confirm the blueprint.
3. Set `GEMMA_BASE_URL` to your public Gemma/Ollama-compatible endpoint.
4. Deploy.

Render will use `web/Dockerfile`, mount SQLite at `/data`, and health-check `/api/health`.

### Important Gemma Note

`http://127.0.0.1:11434` only works on your Mac. A public deployment cannot reach that address.

For the Kaggle demo, use one of these:

- A public VM running Ollama/Gemma behind HTTPS.
- A hosted Gemma-compatible inference endpoint.
- A temporary tunnel to a machine running Ollama for demo purposes.

The web app stores learner memory in SQLite on the Render disk. The model endpoint provides intelligence; SQLite provides durable memory.

## Health Check

```text
/api/health
```

returns the app status, configured model, and database path.
