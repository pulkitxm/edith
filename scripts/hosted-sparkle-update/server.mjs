import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { createServer } from "node:http";
import { createSignedAppcast, verifySparkleArchive } from "./contract.mjs";

export async function reserveSparkleServer(port = 0) {
  assert(
    Number.isInteger(port) && (port === 0 || (port >= 1024 && port <= 65535)),
  );
  let configured;
  let recipeReceipt;
  const sockets = new Set();
  const requests = [];
  let closed = false;
  const server = createServer((request, response) => {
    const address = request.socket.remoteAddress;
    const expectedHost = `127.0.0.1:${server.address().port}`;
    const { fixture, archive, appcast } = configured ?? {};
    const resources = new Map([
      [
        `/${fixture?.session}/appcast.xml`,
        [appcast, "application/rss+xml", "appcast"],
      ],
      [
        `/${fixture?.session}/Edith.zip`,
        [archive, "application/zip", "archive"],
      ],
    ]);
    const resource = resources.get(request.url);
    if (
      closed ||
      !configured ||
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
    server.listen(port, "127.0.0.1", resolve);
  });
  return {
    port: server.address().port,
    configure: ({ fixture, archive, signature, recipe = "valid" }) => {
      assert(!configured && !closed);
      assert.equal(fixture.port, server.address().port);
      assert(["valid", "wrong-signature", "tampered-archive"].includes(recipe));
      verifySparkleArchive(fixture, archive, signature);
      const bytes = Buffer.from(archive);
      let signed = signature;
      if (recipe === "wrong-signature") {
        const altered = Buffer.from(signature, "base64");
        altered[0] ^= 1;
        signed = altered.toString("base64");
      }
      if (recipe === "tampered-archive") {
        bytes[bytes.length - 1] ^= 1;
      }
      const appcast = createSignedAppcast(fixture, signed);
      assert(appcast.length <= 16384);
      configured = { fixture: { ...fixture }, archive: bytes, appcast };
      recipeReceipt = {
        recipe,
        baselineArchiveSHA256: fixture.archiveSHA256,
        servedArchiveSHA256: createHash("sha256").update(bytes).digest("hex"),
        servedSignatureSHA256: createHash("sha256")
          .update(Buffer.from(signed, "base64"))
          .digest("hex"),
        actualSparkleRejectionValidated: false,
      };
    },
    recipe: () => (recipeReceipt ? { ...recipeReceipt } : null),
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

export async function startSparkleServer({ fixture, archive, signature }) {
  const server = await reserveSparkleServer(fixture.port);
  try {
    server.configure({ fixture, archive, signature });
    return server;
  } catch (error) {
    await server.close();
    throw error;
  }
}

export function validateSparkleRecipe(
  receipt,
  { fixture, archive, signature },
  recipe,
) {
  assert.deepEqual(
    Object.keys(receipt).sort(),
    [
      "recipe",
      "baselineArchiveSHA256",
      "servedArchiveSHA256",
      "servedSignatureSHA256",
      "actualSparkleRejectionValidated",
    ].sort(),
  );
  assert(["valid", "wrong-signature", "tampered-archive"].includes(recipe));
  assert.equal(receipt.recipe, recipe);
  assert.equal(receipt.baselineArchiveSHA256, fixture.archiveSHA256);
  assert.equal(receipt.actualSparkleRejectionValidated, false);
  const bytes = Buffer.from(archive);
  const signed = Buffer.from(signature, "base64");
  assert.equal(bytes.length, fixture.archiveBytes);
  assert.equal(signed.length, 64);
  assert.equal(
    createHash("sha256").update(bytes).digest("hex"),
    fixture.archiveSHA256,
  );
  if (recipe === "tampered-archive") bytes[bytes.length - 1] ^= 1;
  if (recipe === "wrong-signature") signed[0] ^= 1;
  assert.equal(
    receipt.servedArchiveSHA256,
    createHash("sha256").update(bytes).digest("hex"),
  );
  assert.equal(
    receipt.servedSignatureSHA256,
    createHash("sha256").update(signed).digest("hex"),
  );
  return Object.freeze({ ...receipt });
}
