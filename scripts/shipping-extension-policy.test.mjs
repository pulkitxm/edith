import assert from "node:assert/strict";
import { generateKeyPairSync, sign } from "node:crypto";
import { readFile } from "node:fs/promises";
import { test } from "node:test";
import {
  publicationComposition,
  verifiedComposition,
} from "./hosted-public-release/evidence.mjs";
import {
  assertShippingExtensions,
  shippingDefinitions,
  shippingExtensionIDs,
} from "./shipping-extension-policy.mjs";

test("the first release selects Keep Awake without modifying the full manifest", async () => {
  const definitions = JSON.parse(
    await readFile(
      new URL("../Extensions/manifest.json", import.meta.url),
      "utf8",
    ),
  );
  const before = JSON.stringify(definitions);
  const selected = shippingDefinitions(definitions);
  assert.deepEqual(
    selected.map((entry) => entry.id),
    ["keepAwake"],
  );
  assert.deepEqual(selected[0].dependencies, []);
  assert.equal(
    selected[0],
    definitions.find((entry) => entry.id === "keepAwake"),
  );
  assert.equal(JSON.stringify(definitions), before);
  assert.equal(definitions.length, 39);
  assert(Object.isFrozen(shippingExtensionIDs));
});

test("missing, duplicate and unreleased dependencies reject publication scope", () => {
  const keepAwake = { id: "keepAwake", dependencies: [] };
  assert.throws(() => shippingDefinitions([]), /exactly one/);
  assert.throws(
    () => shippingDefinitions([keepAwake, keepAwake]),
    /exactly one/,
  );
  assert.throws(
    () => shippingDefinitions([{ ...keepAwake, dependencies: ["music"] }]),
    /Unreleased/,
  );
  assert.throws(() => shippingDefinitions([{ id: "keepAwake" }]), /Unreleased/);
});

test("unreleased and duplicate planned packages reject before publication", () => {
  assert.doesNotThrow(() => assertShippingExtensions([]));
  assert.doesNotThrow(() => assertShippingExtensions([{ id: "keepAwake" }]));
  assert.throws(() => assertShippingExtensions([{ id: "music" }]), /shipping/);
  assert.throws(
    () => assertShippingExtensions([{ id: "keepAwake" }, { id: "music" }]),
    /shipping/,
  );
  assert.throws(
    () => assertShippingExtensions([{ id: "keepAwake" }, { id: "keepAwake" }]),
    /shipping/,
  );
});

test("a signed single-extension publication binds its exact package and source", () => {
  const source = "a".repeat(40);
  const fingerprints = { keepAwake: "b".repeat(64) };
  const rows = [
    {
      package: {
        id: "keepAwake",
        sourceFingerprint: fingerprints.keepAwake,
        sha256: "c".repeat(64),
        version: "1.0.0",
      },
      lineageSHA256: "d".repeat(64),
      lineageBytes: 200,
      sourceCommit: source,
      runID: 100,
      runAttempt: 1,
      evidenceSHA256: "e".repeat(64),
      evidenceBytes: 300,
    },
  ];
  const payload = publicationComposition(source, 101, 1, rows, fingerprints);
  const keys = generateKeyPairSync("ed25519");
  const bytes = Buffer.from(JSON.stringify(payload));
  const envelope = Buffer.from(
    JSON.stringify({
      payload: bytes.toString("base64"),
      signature: sign(null, bytes, keys.privateKey).toString("base64"),
    }),
  );
  const publicKey = keys.publicKey
    .export({ format: "der", type: "spki" })
    .subarray(-32)
    .toString("base64");
  const admission = {
    source,
    runID: 101,
    attempt: 1,
    records: rows.map((row) => row.package),
    fingerprints,
  };
  assert.deepEqual(
    verifiedComposition(envelope, publicKey, admission),
    payload,
  );
  assert.throws(() =>
    verifiedComposition(envelope, publicKey, {
      ...admission,
      records: [{ ...rows[0].package, sha256: "f".repeat(64) }],
    }),
  );
  assert.throws(() =>
    publicationComposition(source, 101, 1, rows, {
      ...fingerprints,
      music: "f".repeat(64),
    }),
  );
  assert.throws(() =>
    publicationComposition(source, 101, 1, [rows[0], rows[0]], fingerprints),
  );
  assert.throws(() => publicationComposition(source, 101, 1, [], {}));
});
