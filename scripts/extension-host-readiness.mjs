import assert from "node:assert/strict";
import { constants } from "node:fs";
import { lstat, open, realpath } from "node:fs/promises";
import { basename, dirname, join, resolve } from "node:path";
import { validateCatalogPointer } from "./extension-catalog-pointer.mjs";
import { evidenceTag } from "./hosted-public-release/evidence.mjs";
import { validateCatalog } from "./verify-extension-catalog.mjs";

const positive = (value) => assert(Number.isSafeInteger(value) && value > 0);
const hash = (value) => assert.match(value, /^[a-f0-9]{64}$/);

export async function boundedReadinessFile(
  file,
  maximum,
  {
    readChunk = (input, buffer, offset) =>
      input.read(buffer, offset, buffer.length - offset, null),
  } = {},
) {
  assert(Number.isSafeInteger(maximum) && maximum > 0 && maximum <= 1024 ** 2);
  const path = join(await realpath(dirname(resolve(file))), basename(file));
  const input = await open(
    path,
    constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK,
  );
  const identity = (info) => [
    info.dev,
    info.ino,
    info.uid,
    info.mode,
    info.nlink,
    info.size,
    info.mtimeNs,
    info.ctimeNs,
  ];
  try {
    const before = await input.stat({ bigint: true });
    assert(
      before.isFile() &&
        before.uid === BigInt(process.getuid()) &&
        before.nlink === 1n &&
        (before.mode & 0o022n) === 0n,
    );
    assert(before.size > 0n && before.size <= BigInt(maximum));
    assert.deepEqual(
      identity(await lstat(path, { bigint: true })),
      identity(before),
    );
    const buffer = Buffer.alloc(Number(before.size) + 1);
    let used = 0;
    while (true) {
      const { bytesRead } = await readChunk(input, buffer, used);
      assert(
        Number.isSafeInteger(bytesRead) &&
          bytesRead >= 0 &&
          bytesRead <= buffer.length - used,
      );
      if (bytesRead === 0) break;
      used += bytesRead;
      assert(used <= Number(before.size));
    }
    assert.equal(used, Number(before.size));
    assert.deepEqual(
      identity(await input.stat({ bigint: true })),
      identity(before),
    );
    assert.deepEqual(
      identity(await lstat(path, { bigint: true })),
      identity(before),
    );
    return buffer.subarray(0, used);
  } finally {
    await input.close();
  }
}

export function hostReadinessDescriptor({
  source,
  intent,
  previous,
  candidate,
  record,
  native,
  catalogReleaseID,
  previousAssetID,
  candidateAssetID,
}) {
  assert.match(source, /^[a-f0-9]{40}$/);
  assert.equal(intent.role, "extensions");
  assert.equal(intent.source, source);
  assert.deepEqual(
    Object.keys(intent.host).sort(),
    ["kind", "source", "run", "runAttempt", "tag", "version", "build"].sort(),
  );
  assert.equal(intent.host.kind, "pending-public-host");
  assert.equal(intent.host.source, source);
  positive(intent.host.run);
  positive(intent.host.runAttempt);
  positive(intent.host.build);
  assert.match(intent.host.version, /^\d+\.\d+\.\d+$/);
  assert.equal(intent.host.tag, `v${intent.host.version}`);
  assert.deepEqual(Object.keys(intent.extensions).sort(), [
    "run",
    "runAttempt",
  ]);
  positive(intent.extensions.run);
  positive(intent.extensions.runAttempt);
  assert.notEqual(intent.extensions.run, intent.host.run);
  validateCatalogPointer(previous);
  validateCatalogPointer(candidate);
  assert.deepEqual(intent.previousCatalog, previous);
  assert(candidate.revision > previous.revision);
  assert.notEqual(candidate.sha256, previous.sha256);
  for (const value of [catalogReleaseID, previousAssetID, candidateAssetID])
    positive(value);
  assert.notEqual(previousAssetID, candidateAssetID);
  assert.equal(record.id, "keepAwake");
  assert.equal(record.version, "1.0.1");
  assert.deepEqual(record.dependencies, []);
  validateCatalog({
    schemaVersion: 1,
    revision: candidate.revision,
    packages: [record],
  });
  assert.deepEqual(
    Object.keys(native).sort(),
    [
      "tag",
      "sourceCommit",
      "runID",
      "runAttempt",
      "envelopeSHA256",
      "envelopeBytes",
      "compositionSHA256",
      "compositionBytes",
      "releaseID",
      "envelopeAssetID",
      "compositionAssetID",
    ].sort(),
  );
  assert.equal(native.sourceCommit, source);
  assert.equal(native.runID, intent.extensions.run);
  assert.equal(native.runAttempt, intent.extensions.runAttempt);
  assert.equal(
    native.tag,
    evidenceTag(source, native.runID, native.runAttempt),
  );
  for (const name of ["envelopeSHA256", "compositionSHA256"])
    hash(native[name]);
  for (const name of ["envelopeBytes", "compositionBytes"]) {
    positive(native[name]);
    assert(native[name] <= 1024 ** 2);
  }
  for (const name of ["releaseID", "envelopeAssetID", "compositionAssetID"])
    positive(native[name]);
  assert.notEqual(native.envelopeAssetID, native.compositionAssetID);
  const value = {
    schema: 1,
    purpose: "cohort-host-readiness",
    source,
    host: intent.host,
    extensions: intent.extensions,
    previousCatalog: previous,
    candidateCatalog: candidate,
    package: record,
    nativeEvidence: native,
    catalogReleaseID,
    previousAssetID,
    candidateAssetID,
  };
  const text = JSON.stringify(value);
  assert(Buffer.byteLength(text) <= 8192);
  const copy = JSON.parse(text);
  const freeze = (value) => {
    if (value && typeof value === "object") {
      for (const child of Object.values(value)) freeze(child);
      Object.freeze(value);
    }
    return value;
  };
  return freeze(copy);
}
