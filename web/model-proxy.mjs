import http from "node:http";

const PORT = Number(process.env.PORT || 11435);
const TOKEN = process.env.ACCORDIAN_MODEL_TOKEN || "";
const OLLAMA_BASE_URL = (process.env.OLLAMA_BASE_URL || "http://127.0.0.1:11434").replace(/\/$/, "");

const server = http.createServer(async (request, response) => {
  try {
    if (TOKEN && request.headers["x-accordian-model-token"] !== TOKEN) {
      response.writeHead(401, { "content-type": "application/json" });
      response.end(JSON.stringify({ error: "Unauthorized model request." }));
      return;
    }

    const url = new URL(request.url || "/", `http://${request.headers.host || "localhost"}`);
    if (!url.pathname.startsWith("/api/")) {
      response.writeHead(404, { "content-type": "application/json" });
      response.end(JSON.stringify({ error: "Not found." }));
      return;
    }

    const body = request.method === "GET" || request.method === "HEAD"
      ? undefined
      : Buffer.concat(await Array.fromAsync(request));
    const upstream = await fetch(`${OLLAMA_BASE_URL}${url.pathname}${url.search}`, {
      method: request.method,
      headers: { "content-type": request.headers["content-type"] || "application/json" },
      body
    });

    response.writeHead(upstream.status, {
      "content-type": upstream.headers.get("content-type") || "application/json"
    });
    response.end(Buffer.from(await upstream.arrayBuffer()));
  } catch (error) {
    response.writeHead(502, { "content-type": "application/json" });
    response.end(JSON.stringify({ error: error.message || "Model proxy failed." }));
  }
});

server.listen(PORT, "127.0.0.1", () => {
  console.log(`Accordian model proxy listening on http://127.0.0.1:${PORT}`);
});
