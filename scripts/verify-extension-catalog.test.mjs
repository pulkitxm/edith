import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { generateKeyPairSync, sign } from "node:crypto";
import { mkdtemp, readdir, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import test from "node:test";
import {
  extensionFingerprint,
  planUnpublishedExtensions,
} from "./extension-release-plan.mjs";
import {
  maximumEnvelopeBytes,
  maximumPayloadBytes,
  verifiedCatalogPayload,
  verifyCatalogFile,
} from "./verify-extension-catalog.mjs";

const keys = generateKeyPairSync("ed25519");
const rawKey = Buffer.from(
  keys.publicKey.export({ format: "jwk" }).x,
  "base64url",
);
const publicKey = rawKey.toString("base64");
const packageRecord = {
  id: "synthetic",
  version: "1.0.0",
  hostABI: "edith-host-1",
  architecture: "arm64",
  minimumSystemVersion: 14,
  downloadURL:
    "https://github.com/pulkitxm/edith/releases/download/extensions%2Fsynthetic%2Ffixture/synthetic.zip",
  sha256: "a".repeat(64),
  sourceFingerprint: "b".repeat(64),
  downloadBytes: 100,
  installedBytes: 200,
  dependencies: [],
};
const catalog = (packages = [packageRecord]) => ({
  schemaVersion: 1,
  revision: 1,
  packages,
});
const envelope = (payload, privateKey = keys.privateKey) =>
  Buffer.from(
    JSON.stringify({
      payload: payload.toString("base64"),
      signature: sign(null, payload, privateKey).toString("base64"),
    }),
  );
const signed = (value) => envelope(Buffer.from(JSON.stringify(value)));

test("raw Ed25519 verification preserves the exact signed payload bytes", () => {
  const payload = Buffer.from(`${JSON.stringify(catalog(), null, 2)}\n`);
  assert.deepEqual(
    verifiedCatalogPayload(envelope(payload), publicKey),
    payload,
  );
  assert.deepEqual(
    JSON.parse(verifiedCatalogPayload(signed(catalog([])), publicKey)),
    catalog([]),
  );
});

test("wrong keys, tampered payloads and signatures fail verification", () => {
  const other = generateKeyPairSync("ed25519");
  const otherPublic = Buffer.from(
    other.publicKey.export({ format: "jwk" }).x,
    "base64url",
  ).toString("base64");
  assert.throws(
    () => verifiedCatalogPayload(signed(catalog()), otherPublic),
    /signature/,
  );
  const altered = JSON.parse(signed(catalog()));
  altered.payload = Buffer.from(
    JSON.stringify({ ...catalog(), revision: 2 }),
  ).toString("base64");
  assert.throws(
    () =>
      verifiedCatalogPayload(Buffer.from(JSON.stringify(altered)), publicKey),
    /signature/,
  );
  altered.signature = Buffer.alloc(64).toString("base64");
  assert.throws(
    () =>
      verifiedCatalogPayload(Buffer.from(JSON.stringify(altered)), publicKey),
    /signature/,
  );
});

test("public key and signature must have canonical base64 and exact raw lengths", () => {
  for (const invalid of [
    "",
    `${publicKey.trimEnd()}\n`,
    publicKey.replace("=", ""),
    "_".repeat(44),
    Buffer.alloc(31).toString("base64"),
    Buffer.alloc(33).toString("base64"),
  ])
    assert.throws(() => verifiedCatalogPayload(signed(catalog()), invalid));
  const zeroKey = Buffer.alloc(32).toString("base64");
  assert.throws(() =>
    verifiedCatalogPayload(signed(catalog()), `${zeroKey.slice(0, -2)}B=`),
  );
  for (const value of [
    "",
    "AA==",
    "_".repeat(88),
    Buffer.alloc(63).toString("base64"),
    Buffer.alloc(65).toString("base64"),
  ]) {
    const encoded = JSON.parse(signed(catalog()));
    encoded.signature = value;
    assert.throws(() =>
      verifiedCatalogPayload(Buffer.from(JSON.stringify(encoded)), publicKey),
    );
  }
});

test("malformed envelopes, payload base64 and UTF-8 are rejected", () => {
  for (const value of [
    null,
    [],
    {},
    { payload: 1, signature: "AA==" },
    { ...JSON.parse(signed(catalog())), unexpected: true },
  ])
    assert.throws(() =>
      verifiedCatalogPayload(Buffer.from(JSON.stringify(value)), publicKey),
    );
  for (const value of ["{", "\ufffd", ""])
    assert.throws(() => verifiedCatalogPayload(Buffer.from(value), publicKey));
  for (const value of ["", "e30", "e30=\n", "e31=", "e30_", "===="]) {
    const encoded = JSON.parse(signed(catalog()));
    encoded.payload = value;
    assert.throws(() =>
      verifiedCatalogPayload(Buffer.from(JSON.stringify(encoded)), publicKey),
    );
  }
  assert.throws(() =>
    verifiedCatalogPayload(envelope(Buffer.from([0xff])), publicKey),
  );
});

test("catalog and package schemas fail closed even with a valid signature", () => {
  for (const value of [
    null,
    [],
    {},
    { ...catalog(), schemaVersion: 2 },
    { ...catalog(), revision: -1 },
    { ...catalog(), revision: 1.5 },
    { ...catalog(), revision: Number.MAX_SAFE_INTEGER + 1 },
    { ...catalog(), packages: {} },
    catalog(Array(1001).fill(packageRecord)),
  ])
    assert.throws(() => verifiedCatalogPayload(signed(value), publicKey));
  const invalidFields = {
    id: ["../fixture", ".hidden", "x".repeat(97), 12],
    version: ["1.0", "-1.0.0", "1.0.9007199254740992"],
    hostABI: ["", "../host"],
    architecture: ["riscv"],
    minimumSystemVersion: [13, "14"],
    sha256: ["A".repeat(64), "abc"],
    sourceFingerprint: [null, "abc"],
    downloadBytes: [0, 512 * 1024 ** 2 + 1],
    installedBytes: [0, 1024 ** 3 + 1],
    dependencies: [
      null,
      ["synthetic"],
      ["missing"],
      ["dependency", "dependency"],
    ],
    downloadURL: [
      "file:///fixture.zip",
      "https://github.com/foreign/repo/releases/download/tag/synthetic.zip",
      "https://user@github.com/pulkitxm/edith/releases/download/tag/synthetic.zip",
      "https://github.com:443/pulkitxm/edith/releases/download/tag/synthetic.zip",
      `${packageRecord.downloadURL}?token=synthetic`,
      `${packageRecord.downloadURL}#fragment`,
    ],
  };
  for (const [field, values] of Object.entries(invalidFields))
    for (const value of values)
      assert.throws(
        () =>
          verifiedCatalogPayload(
            signed(catalog([{ ...packageRecord, [field]: value }])),
            publicKey,
          ),
        field,
      );
  assert.throws(
    () =>
      verifiedCatalogPayload(
        signed(catalog([packageRecord, packageRecord])),
        publicKey,
      ),
    /Duplicate/,
  );
});

test("bounded signed catalogs retain compatible package dependencies", () => {
  const dependency = {
    ...packageRecord,
    id: "dependency",
    downloadURL: packageRecord.downloadURL.replace(
      "synthetic.zip",
      "dependency.zip",
    ),
  };
  const value = catalog([
    { ...packageRecord, dependencies: ["dependency"] },
    dependency,
  ]);
  assert.deepEqual(
    JSON.parse(verifiedCatalogPayload(signed(value), publicKey)),
    value,
  );
  assert.throws(
    () =>
      verifiedCatalogPayload(
        signed(
          catalog([
            { ...packageRecord, dependencies: ["dependency"] },
            { ...dependency, hostABI: "different-host" },
          ]),
        ),
        publicKey,
      ),
    /dependency/,
  );
});

test("envelope and decoded payload byte limits are enforced", () => {
  assert.throws(
    () =>
      verifiedCatalogPayload(Buffer.alloc(maximumEnvelopeBytes + 1), publicKey),
    /limit/,
  );
  const payload = Buffer.alloc(maximumPayloadBytes + 1, 32);
  assert.throws(() => verifiedCatalogPayload(envelope(payload), publicKey));
  const prefix = JSON.stringify(catalog([]));
  const exact = Buffer.from(
    prefix + " ".repeat(maximumPayloadBytes - Buffer.byteLength(prefix)),
  );
  assert.deepEqual(verifiedCatalogPayload(envelope(exact), publicKey), exact);
});

test("atomic output replaces only a verified catalog and cleans temporary files", async () => {
  const directory = await mkdtemp(join(tmpdir(), "extension-catalog-atomic-"));
  try {
    const input = join(directory, "envelope.json");
    const output = join(directory, "payload.json");
    await writeFile(output, "previous verified bytes");
    await writeFile(input, Buffer.alloc(maximumEnvelopeBytes + 1));
    await assert.rejects(verifyCatalogFile(input, output, publicKey));
    assert.equal(await readFile(output, "utf8"), "previous verified bytes");
    await writeFile(input, signed({ schemaVersion: 2 }));
    await assert.rejects(verifyCatalogFile(input, output, publicKey));
    assert.equal(await readFile(output, "utf8"), "previous verified bytes");
    await writeFile(input, signed(catalog()));
    await verifyCatalogFile(input, output, publicKey);
    assert.deepEqual(JSON.parse(await readFile(output, "utf8")), catalog());
    await assert.rejects(verifyCatalogFile(input, directory, publicKey));
    assert.deepEqual((await readdir(directory)).sort(), [
      "envelope.json",
      "payload.json",
    ]);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test("the Node command verifies files and rejects invalid invocation without stdout", async () => {
  const directory = await mkdtemp(join(tmpdir(), "extension-catalog-cli-"));
  try {
    const input = join(directory, "envelope.json");
    const output = join(directory, "payload.json");
    await writeFile(input, signed(catalog()));
    const command = resolve("scripts/verify-extension-catalog.mjs");
    const good = spawnSync("node", [command, input, output, publicKey], {
      encoding: "utf8",
    });
    assert.equal(good.status, 0, good.stderr);
    assert.equal(good.stdout, "");
    for (const args of [
      [],
      [input, output, publicKey, "extra"],
      [input, output, "invalid"],
    ]) {
      const bad = spawnSync("node", [command, ...args], { encoding: "utf8" });
      assert.equal(bad.status, 1);
      assert.equal(bad.stdout, "");
      assert.match(bad.stderr, /Catalog verification failed/);
    }
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test("verified fingerprints reuse unchanged packages and rebuild changed source", async () => {
  const directory = await mkdtemp(join(tmpdir(), "extension-verified-plan-"));
  const definition = {
    id: "synthetic",
    version: "1.0.0",
    hostABI: "edith-host-1",
    inputs: ["source.txt"],
    sharedInputs: [],
    dependencies: [],
  };
  try {
    await writeFile(join(directory, "source.txt"), "synthetic source");
    const fingerprint = await extensionFingerprint(directory, definition, [
      definition,
    ]);
    const previous = JSON.parse(
      verifiedCatalogPayload(
        signed(catalog([{ ...packageRecord, sourceFingerprint: fingerprint }])),
        publicKey,
      ),
    );
    assert.deepEqual(
      await planUnpublishedExtensions(
        directory,
        [definition],
        previous.packages,
      ),
      [],
    );
    await writeFile(join(directory, "source.txt"), "changed synthetic source");
    const planned = await planUnpublishedExtensions(
      directory,
      [definition],
      previous.packages,
    );
    assert.equal(planned.length, 1);
    assert.equal(planned[0].version, "1.0.1");
    assert.notEqual(planned[0].fingerprint, fingerprint);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test("Swift CryptoKit signatures interoperate with Node verification in both directions", {
  skip: process.platform !== "darwin",
  timeout: 60000,
}, async () => {
  const directory = await mkdtemp(join(tmpdir(), "extension-catalog-swift-"));
  try {
    const signer = resolve("scripts/extension-catalog-sign.swift");
    const keyPath = join(directory, "synthetic-key");
    const swiftPublic = execFileSync(
      "swift",
      [signer, "generate-key", keyPath],
      { encoding: "utf8", timeout: 30000 },
    ).trim();
    const syntheticSeed = (await readFile(keyPath, "utf8")).trim();
    const payloadPath = join(directory, "payload.json");
    const signedPath = join(directory, "envelope.json");
    const payload = Buffer.from(`${JSON.stringify(catalog(), null, 2)}\n`);
    await writeFile(payloadPath, payload);
    execFileSync("swift", [signer, "sign", payloadPath, signedPath], {
      env: { ...process.env, EXTENSION_CATALOG_PRIVATE_KEY: syntheticSeed },
      timeout: 30000,
    });
    assert.deepEqual(
      verifiedCatalogPayload(await readFile(signedPath), swiftPublic),
      payload,
    );
    const { createPrivateKey } = await import("node:crypto");
    const privateKey = createPrivateKey({
      format: "jwk",
      key: {
        kty: "OKP",
        crv: "Ed25519",
        d: Buffer.from(syntheticSeed, "base64").toString("base64url"),
        x: Buffer.from(swiftPublic, "base64").toString("base64url"),
      },
    });
    await writeFile(signedPath, envelope(payload, privateKey));
    const verifiedPath = join(directory, "swift-verified.json");
    execFileSync(
      "swift",
      [signer, "verify", signedPath, verifiedPath, swiftPublic],
      { timeout: 30000 },
    );
    assert.deepEqual(await readFile(verifiedPath), payload);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});
