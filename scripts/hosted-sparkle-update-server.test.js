import { expect, test } from "bun:test";
import { createHash, generateKeyPairSync, sign } from "node:crypto";
import { createServer, request } from "node:http";
import { startSparkleServer } from "./hosted-sparkle-update/server.mjs";

async function setup() {
  const reservation = createServer();
  await new Promise((resolve) => reservation.listen(0, "127.0.0.1", resolve));
  const port = reservation.address().port;
  await new Promise((resolve) => reservation.close(resolve));
  const archive = Buffer.from("Synthetic app archive served only on loopback");
  const { privateKey, publicKey } = generateKeyPairSync("ed25519");
  const fixture = {
    session: "00000000-0000-4000-8000-000000000001",
    port,
    archiveBytes: archive.length,
    archiveSHA256: createHash("sha256").update(archive).digest("hex"),
    publicKey: publicKey
      .export({ type: "spki", format: "der" })
      .subarray(-32)
      .toString("base64"),
  };
  const signature = sign(null, archive, privateKey).toString("base64");
  const server = await startSparkleServer({ fixture, archive, signature });
  const fetchOwned = (path, method = "GET", headers = {}) =>
    new Promise((resolve, reject) => {
      const child = request(
        { hostname: "127.0.0.1", port, path, method, headers },
        (response) => {
          const chunks = [];
          response.on("data", (data) => chunks.push(data));
          response.once("end", () =>
            resolve({
              status: response.statusCode,
              data: Buffer.concat(chunks),
            }),
          );
        },
      );
      child.once("error", reject);
      child.end();
    });
  return { fixture, server, archive, fetchOwned };
}

test("the actual loopback server serves only the fixed signed appcast and complete archive", async () => {
  const { fixture, server, archive, fetchOwned } = await setup();
  try {
    const xml = await fetchOwned(`/${fixture.session}/appcast.xml`);
    expect(xml.status).toBe(200);
    expect(xml.data.toString()).toContain("sparkle:edSignature=");
    const zip = await fetchOwned(`/${fixture.session}/Edith.zip`);
    expect(zip.status).toBe(200);
    expect(zip.data).toEqual(archive);
    expect(server.observations()).toEqual([
      { category: "appcast", complete: true, bytes: xml.data.length },
      { category: "archive", complete: true, bytes: archive.length },
    ]);
  } finally {
    await server.close();
    await server.close();
  }
});

test("foreign routes methods ranges request bodies and host headers cannot serve archive bytes", async () => {
  const { fixture, server, fetchOwned } = await setup();
  try {
    for (const [path, method, headers] of [
      ["/foreign/Edith.zip", "GET", {}],
      [`/${fixture.session}/Edith.zip?alternate=1`, "GET", {}],
      [`/${fixture.session}/Edith.zip`, "POST", {}],
      [`/${fixture.session}/Edith.zip`, "GET", { Range: "bytes=0-5" }],
      [`/${fixture.session}/Edith.zip`, "GET", { Host: "foreign.invalid" }],
      [`/${fixture.session}/Edith.zip`, "GET", { "Content-Length": "1" }],
    ]) {
      const response = await fetchOwned(path, method, headers);
      expect(response.status).toBe(403);
      expect(response.data.length).toBe(0);
    }
    expect(server.observations()).toEqual([]);
  } finally {
    await server.close();
  }
});

test("negative recipes serve predetermined altered bytes to the actual client without calling parser rejection update proof", async () => {
  const { reserveSparkleServer } = await import(
    "./hosted-sparkle-update/server.mjs"
  );
  const { verifySparkleArchive } = await import(
    "./hosted-sparkle-update/contract.mjs"
  );
  for (const recipe of ["wrong-signature", "tampered-archive"]) {
    const server = await reserveSparkleServer();
    const archive = Buffer.from("Fresh synthetic immutable archive");
    const { privateKey, publicKey } = generateKeyPairSync("ed25519");
    const fixture = {
      session: "00000000-0000-4000-8000-000000000001",
      port: server.port,
      archiveBytes: archive.length,
      archiveSHA256: createHash("sha256").update(archive).digest("hex"),
      publicKey: publicKey
        .export({ type: "spki", format: "der" })
        .subarray(-32)
        .toString("base64"),
    };
    const signature = sign(null, archive, privateKey).toString("base64");
    try {
      const base = `http://127.0.0.1:${server.port}/${fixture.session}`;
      expect((await fetch(`${base}/Edith.zip`)).status).toBe(403);
      server.configure({ fixture, archive, signature, recipe });
      const xml = await (await fetch(`${base}/appcast.xml`)).text();
      const received = Buffer.from(
        await (await fetch(`${base}/Edith.zip`)).arrayBuffer(),
      );
      const signed = xml.match(/sparkle:edSignature="([^"]+)"/)[1];
      expect(() => verifySparkleArchive(fixture, received, signed)).toThrow();
      expect(server.recipe().recipe).toBe(recipe);
      expect(server.recipe().actualSparkleRejectionValidated).toBe(false);
      expect(server.recipe().baselineArchiveSHA256).toBe(fixture.archiveSHA256);
      expect(() => server.configure({ fixture, archive, signature })).toThrow();
      expect(server.observations().every((row) => row.complete)).toBe(true);
      if (recipe === "wrong-signature") expect(received).toEqual(archive);
      else expect(received).not.toEqual(archive);
    } finally {
      await server.close();
    }
  }
});
