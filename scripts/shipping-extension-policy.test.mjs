import assert from "node:assert/strict";
import { generateKeyPairSync, sign } from "node:crypto";
import { readFile } from "node:fs/promises";
import { test } from "node:test";
import { ownedDraftResume } from "./hosted-public-release/contract.mjs";
import {
  publicationComposition,
  verifiedComposition,
} from "./hosted-public-release/evidence.mjs";
import {
  assertShippingExtensions,
  shippingDefinitions,
  shippingExtensionIDs,
} from "./shipping-extension-policy.mjs";

const manifestDefinitions = async () =>
  JSON.parse(
    await readFile(
      new URL("../Extensions/manifest.json", import.meta.url),
      "utf8",
    ),
  );

test("the release selects every manifest extension without modifying the manifest", async () => {
  const definitions = await manifestDefinitions();
  const before = JSON.stringify(definitions);
  const selected = shippingDefinitions(definitions);
  assert.equal(definitions.length, 39);
  assert.deepEqual(
    selected.map((entry) => entry.id),
    definitions.map((entry) => entry.id),
  );
  assert.deepEqual(
    shippingExtensionIDs(),
    selected.map((entry) => entry.id),
  );
  assert(selected.every((entry, index) => entry === definitions[index]));
  for (const entry of selected)
    assert(
      entry.dependencies.every((id) => shippingExtensionIDs().includes(id)),
    );
  assert.equal(JSON.stringify(definitions), before);
  assert(Object.isFrozen(shippingExtensionIDs()));
  assert.equal(shippingExtensionIDs(), shippingExtensionIDs());
});

test("missing, duplicate, unknown and unreleased dependencies reject publication scope", async () => {
  const definitions = await manifestDefinitions();
  const keepAwake = definitions.find((entry) => entry.id === "keepAwake");
  const others = definitions.filter((entry) => entry.id !== "keepAwake");
  assert.throws(() => shippingDefinitions([]), /exactly one/);
  assert.throws(
    () => shippingDefinitions(others),
    /exactly one shipping extension definition: keepAwake/,
  );
  assert.throws(
    () => shippingDefinitions([...definitions, keepAwake]),
    /exactly one/,
  );
  assert.throws(
    () =>
      shippingDefinitions([
        ...definitions,
        { id: "unknownExtension", dependencies: [] },
      ]),
    /outside the shipping release scope/,
  );
  assert.throws(
    () =>
      shippingDefinitions([
        { ...keepAwake, dependencies: ["unknownExtension"] },
        ...others,
      ]),
    /Unreleased/,
  );
  assert.throws(
    () => shippingDefinitions([{ id: "keepAwake" }, ...others]),
    /Unreleased/,
  );
  assert.throws(() => shippingDefinitions({}), /Invalid/);
});

test("unknown and duplicate planned packages reject before publication", () => {
  assert.doesNotThrow(() => assertShippingExtensions([]));
  assert.doesNotThrow(() => assertShippingExtensions([{ id: "keepAwake" }]));
  assert.doesNotThrow(() =>
    assertShippingExtensions([{ id: "keepAwake" }, { id: "music" }]),
  );
  assert.doesNotThrow(() =>
    assertShippingExtensions(shippingExtensionIDs().map((id) => ({ id }))),
  );
  assert.throws(
    () => assertShippingExtensions([{ id: "unknownExtension" }]),
    /shipping/,
  );
  assert.throws(
    () =>
      assertShippingExtensions([
        { id: "keepAwake" },
        { id: "unknownExtension" },
      ]),
    /shipping/,
  );
  assert.throws(
    () => assertShippingExtensions([{ id: "keepAwake" }, { id: "keepAwake" }]),
    /shipping/,
  );
  assert.throws(() => assertShippingExtensions({}), /shipping/);
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

test("an owned draft resumes every shipping package against the full source inventory", async () => {
  const definitions = await manifestDefinitions();
  const fingerprints = Object.fromEntries(
    definitions.map(({ id }) => [id, "b".repeat(64)]),
  );
  const records = shippingDefinitions(definitions).map((entry) => ({
    id: entry.id,
    version: "1.0.0",
    hostABI: entry.hostABI,
    architecture: "arm64",
    minimumSystemVersion: entry.minimumSystemVersion,
    downloadBytes: 100,
    installedBytes: 200,
    sha256: "c".repeat(64),
    sourceFingerprint: fingerprints[entry.id],
    dependencies: [],
    downloadURL: `https://github.com/pulkitxm/edith/releases/download/${encodeURIComponent(`extensions/${entry.id}/1.0.0-${fingerprints[entry.id].slice(0, 20)}`)}/${entry.id}.zip`,
  }));
  const resume = {
    plan: { include: [] },
    state: { draft: true },
    previous: { schemaVersion: 1, revision: 1, packages: records },
    definitions,
    fingerprints,
    shippingIDs: shippingExtensionIDs(),
  };
  assert.deepEqual(ownedDraftResume(resume), records);
  assert.throws(() =>
    ownedDraftResume({
      ...resume,
      previous: { ...resume.previous, packages: [] },
    }),
  );
  assert.throws(() =>
    ownedDraftResume({
      ...resume,
      previous: { ...resume.previous, packages: records.slice(1) },
    }),
  );
  assert.throws(() =>
    ownedDraftResume({ ...resume, shippingIDs: ["unknownExtension"] }),
  );
  assert.throws(() =>
    ownedDraftResume({ ...resume, shippingIDs: ["keepAwake", "keepAwake"] }),
  );
  assert.throws(() => ownedDraftResume({ ...resume, state: { draft: false } }));
  assert.throws(() =>
    ownedDraftResume({
      ...resume,
      fingerprints: { ...fingerprints, keepAwake: "d".repeat(64) },
    }),
  );
});
