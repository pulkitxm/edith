import assert from "node:assert/strict";
import { createServer } from "node:http";
import { createSignedAppcast, verifySparkleArchive } from "./contract.mjs";

export async function startSparkleServer({ fixture, archive, signature }) {
  verifySparkleArchive(fixture, archive, signature);
  const appcast = createSignedAppcast(fixture, signature);
  assert(appcast.length <= 16384);
  const sockets = new Set();
  const requests = [];
  let closed = false;
  const server = createServer((request, response) => {
    const address = request.socket.remoteAddress;
    const expectedHost = `127.0.0.1:${fixture.port}`;
    const resources = new Map([
      [
        `/${fixture.session}/appcast.xml`,
        [appcast, "application/rss+xml", "appcast"],
      ],
      [
        `/${fixture.session}/Edith.zip`,
        [archive, "application/zip", "archive"],
      ],
    ]);
    const resource = resources.get(request.url);
    if (
      closed ||
      address !== "127.0.0.1" ||
      request.method !== "GET" ||
      request.headers.host !== expectedHost ||
      request.headers.range ||
      request.headers["transfer-encoding"] ||
      request.headers["content-length"] ||
      !resource ||
      requests.length >= 8
    ) {
      response.writeHead(403, { "Content-Length": "0", Connection: "close" });
      response.end();
      return;
    }
    const [data, type, category] = resource;
    const observation = { category, complete: false, bytes: 0 };
    requests.push(observation);
    response.once("finish", () => {
      observation.complete = true;
      observation.bytes = data.length;
    });
    response.writeHead(200, {
      "Content-Type": type,
      "Content-Length": String(data.length),
      "Cache-Control": "no-store",
      Connection: "close",
    });
    response.end(data);
  });
  server.maxHeadersCount = 32;
  server.headersTimeout = 5000;
  server.requestTimeout = 5000;
  server.on("connection", (socket) => {
    sockets.add(socket);
    socket.once("close", () => sockets.delete(socket));
  });
  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(fixture.port, "127.0.0.1", resolve);
  });
  return {
    observations: () => requests.map((row) => ({ ...row })),
    close: async () => {
      if (closed) return;
      closed = true;
      await new Promise((resolve) => {
        server.close(resolve);
        for (const socket of sockets) socket.destroy();
      });
      assert.equal(sockets.size, 0);
    },
  };
}
