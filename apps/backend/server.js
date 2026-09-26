// Tiny dependency-free HTTP backend for the ROK lab.
// - GET /healthz  -> 200 "ok"  (used by ALB/Traefik health checks)
// - GET /api/hello -> JSON { message, host, secretPresent }
// SECRET_MESSAGE is injected later via External Secrets Operator (Phase 8);
// it has a safe default so the image runs standalone in Phase 7.
const http = require("http");
const os = require("os");

const PORT = process.env.PORT || 8080;
const SECRET_MESSAGE = process.env.SECRET_MESSAGE || "(no secret injected yet)";

const server = http.createServer((req, res) => {
  if (req.url === "/healthz") {
    res.writeHead(200, { "content-type": "text/plain" });
    return res.end("ok");
  }
  if (req.url === "/api/hello") {
    res.writeHead(200, { "content-type": "application/json" });
    return res.end(
      JSON.stringify({
        message: "hello from the ROK-lab backend",
        host: os.hostname(),
        secret: SECRET_MESSAGE,
        time: new Date().toISOString(),
      })
    );
  }
  res.writeHead(404, { "content-type": "text/plain" });
  res.end("not found");
});

server.listen(PORT, () => console.log(`backend listening on :${PORT}`));
