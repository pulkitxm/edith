import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { createHash } from "node:crypto";
import {
  link,
  lstat,
  mkdir,
  open,
  readFile,
  realpath,
  rm,
  writeFile,
} from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import { selectManagedArtifactRows } from "./chunks.mjs";
import { validateNonpublishingNativeJobs } from "./native-ci-contract.mjs";

const execute = promisify(execFile);
const sha256 = (data) => createHash("sha256").update(data).digest("hex");
const hash = /^[a-f0-9]{64}$/;
const commit = /^[a-f0-9]{40}$/;
const identifier = /^[A-Za-z][A-Za-z0-9_-]{0,63}$/;
async function abortable(promise, signal) {
  signal?.throwIfAborted();
  if (!signal) return promise;
  let abort;
  try {
    return await Promise.race([
      promise,
      new Promise((_, reject) => {
        abort = () => reject(signal.reason ?? new Error("Operation canceled"));
        signal.addEventListener("abort", abort, { once: true });
      }),
    ]);
  } finally {
    signal.removeEventListener("abort", abort);
  }
}

async function boundedJSON(response, signal) {
  assert(response.body);
  const reader = response.body.getReader();
  const chunks = [];
  let bytes = 0;
  try {
    while (true) {
      const { done, value } = await abortable(reader.read(), signal);
      if (done) break;
      bytes += value.length;
      assert(bytes <= 8 * 1024 ** 2, "CI metadata exceeds its byte bound");
      chunks.push(value);
    }
    return JSON.parse(Buffer.concat(chunks).toString("utf8"));
  } finally {
    await reader.cancel().catch(() => {});
  }
}

const maximumArtifactBytes = 2 * 1024 ** 3;

function integer(value, maximum = Number.MAX_SAFE_INTEGER) {
  assert(Number.isSafeInteger(value) && value > 0 && value <= maximum);
}

export function validateCIArtifactSet({
  repository,
  run,
  jobs,
  artifacts,
  sourceCommit,
  definitions,
  fingerprints,
}) {
  assert.equal(repository, "pulkitxm/edith");
  assert.match(sourceCommit, commit);
  integer(run.id);
  assert.equal(run.head_sha, sourceCommit);
  assert.equal(run.path, ".github/workflows/extensions.yml");
  assert.equal(run.status, "completed", "The requested CI run is not complete");
  assert.equal(
    run.conclusion,
    "success",
    "The requested CI run did not succeed",
  );
  const ids = definitions.map(({ id }) => id).sort();
  assert.equal(ids.length, 39);
  assert.equal(new Set(ids).size, 39);
  assert.deepEqual(Object.keys(fingerprints).sort(), ids);
  assert(jobs.length <= 1000 && artifacts.length <= 1000);
  validateNonpublishingNativeJobs(jobs, definitions, run.id);
  const rows = [];
  for (const id of ids) {
    assert.match(id, identifier);
    assert.match(fingerprints[id], hash);
    const matchingJobs = jobs.filter((job) => job.name === `build (${id})`);
    assert.equal(
      matchingJobs.length,
      1,
      `Expected one current ${id} build job`,
    );
    const job = matchingJobs[0];
    integer(job.id);
    assert.equal(job.status, "completed");
    assert.equal(job.conclusion, "success");
    assert.equal(job.run_id, run.id);
    const matches = artifacts.filter(
      (artifact) => artifact.name === `extension-${id}`,
    );
    assert.equal(matches.length, 1, `Expected one current ${id} artifact`);
    const artifact = matches[0];
    integer(artifact.id);
    integer(artifact.size_in_bytes, maximumArtifactBytes);
    assert.equal(artifact.expired, false);
    assert.equal(artifact.workflow_run?.id, run.id);
    assert.equal(artifact.workflow_run?.head_sha, sourceCommit);
    assert.match(artifact.digest, /^sha256:[a-f0-9]{64}$/);
    rows.push({
      extensionID: id,
      sourceFingerprint: fingerprints[id],
      artifactID: artifact.id,
      artifactBytes: artifact.size_in_bytes,
      artifactSHA256: artifact.digest.slice(7),
      jobID: job.id,
    });
  }
  return {
    schema: 1,
    repository,
    runID: run.id,
    sourceCommit,
    originals: rows,
  };
}

export async function readCIArtifactSet({
  repository,
  runID,
  sourceCommit,
  definitions,
  fingerprints,
  fetch: fetch_ = fetch,
  signal,
}) {
  assert.equal(repository, "pulkitxm/edith");
  integer(runID);
  signal = signal
    ? AbortSignal.any([signal, AbortSignal.timeout(60000)])
    : AbortSignal.timeout(60000);
  const base = `https://api.github.com/repos/${repository}/actions/runs/${runID}`;
  async function document(url) {
    const response = await abortable(
      fetch_(url, {
        signal,
        headers: { Accept: "application/vnd.github+json" },
      }),
      signal,
    );
    assert.equal(response.status, 200, "CI metadata could not be read");
    return boundedJSON(response, signal);
  }
  async function pages(kind, key) {
    const values = [];
    for (let page = 1; page <= 10; page++) {
      const result = await document(
        `${base}/${kind}?per_page=100&page=${page}`,
      );
      assert(Array.isArray(result[key]));
      assert(
        Number.isSafeInteger(result.total_count) &&
          result.total_count >= 0 &&
          result.total_count <= 1000,
      );
      assert(result[key].length <= 100);
      values.push(...result[key]);
      if (values.length >= result.total_count) {
        assert.equal(values.length, result.total_count);
        return values;
      }
      assert.equal(
        result[key].length,
        100,
        "CI pagination ended before the declared inventory",
      );
    }
    throw new Error("CI metadata exceeds its pagination bound");
  }
  const run = await document(base);
  const [jobs, artifacts] = await Promise.all([
    pages("jobs", "jobs"),
    pages("artifacts", "artifacts"),
  ]);
  return validateCIArtifactSet({
    repository,
    run,
    jobs,
    artifacts,
    sourceCommit,
    definitions,
    fingerprints,
  });
}

export async function downloadCIArtifact({
  repository,
  row,
  destination,
  fetch: fetch_ = fetch,
  signal,
  totalMilliseconds = 15 * 60 * 1000,
  inactivityMilliseconds = 60 * 1000,
}) {
  assert.equal(repository, "pulkitxm/edith");
  integer(row.artifactID);
  integer(row.artifactBytes, maximumArtifactBytes);
  assert.match(row.artifactSHA256, hash);
  integer(totalMilliseconds, 60 * 60 * 1000);
  integer(inactivityMilliseconds, totalMilliseconds);
  const controller = new AbortController();
  const abort = () => controller.abort(signal.reason);
  signal?.throwIfAborted();
  signal?.addEventListener("abort", abort, { once: true });
  const total = setTimeout(
    () =>
      controller.abort(
        new Error("CI artifact download exceeded its total deadline"),
      ),
    totalMilliseconds,
  );
  let inactivity;
  const reset = () => {
    clearTimeout(inactivity);
    inactivity = setTimeout(
      () =>
        controller.abort(
          new Error("CI artifact download stopped making progress"),
        ),
      inactivityMilliseconds,
    );
  };
  let file;
  let reader;
  const partial = `${destination}.partial`;
  try {
    reset();
    const response = await abortable(
      fetch_(
        `https://api.github.com/repos/${repository}/actions/artifacts/${row.artifactID}/zip`,
        {
          signal: controller.signal,
          headers: { Accept: "application/vnd.github+json" },
        },
      ),
      controller.signal,
    );
    assert.equal(response.status, 200, "CI artifact download failed");
    assert(response.body);
    file = await open(partial, "wx", 0o600);
    reader = response.body.getReader();
    let bytes = 0;
    const digest = createHash("sha256");
    while (true) {
      controller.signal.throwIfAborted();
      const { done, value } = await abortable(reader.read(), controller.signal);
      if (done) break;
      bytes += value.length;
      assert(
        bytes <= row.artifactBytes,
        "CI artifact exceeds its reviewed size",
      );
      digest.update(value);
      await file.writeFile(value);
      reset();
    }
    controller.signal.throwIfAborted();
    assert.equal(bytes, row.artifactBytes, "CI artifact size differs");
    assert.equal(
      digest.digest("hex"),
      row.artifactSHA256,
      "CI artifact checksum differs",
    );
    await file.sync();
    await file.close();
    file = undefined;
    await link(partial, destination);
    await rm(partial);
    return { bytes, sha256: row.artifactSHA256 };
  } catch (error) {
    await reader?.cancel(error).catch(() => {});
    await file?.close().catch(() => {});
    await rm(partial, { force: true });
    throw error;
  } finally {
    clearTimeout(total);
    clearTimeout(inactivity);
    signal?.removeEventListener("abort", abort);
  }
}

export function validatePackageReceipt(
  receipt,
  row,
  definition,
  sourceCommit,
  hostSHA256,
) {
  assert.equal(receipt.schema, 1);
  assert.equal(receipt.extensionID, row.extensionID);
  assert.equal(receipt.sourceCommit, sourceCommit);
  assert.equal(receipt.sourceFingerprint, row.sourceFingerprint);
  assert.equal(receipt.sourceHostExecutableSHA256, hostSHA256);
  assert.equal(receipt.packageCodeExecuted, false);
  assert.match(receipt.zipSHA256, hash);
  integer(receipt.downloadBytes, maximumArtifactBytes);
  integer(receipt.installedBytes, 8 * 1024 ** 3);
  for (const key of [
    "zipCRCVerified",
    "sealedHostProvenanceVerified",
    "signaturesVerified",
  ])
    assert.equal(receipt[key], true, key);
  assert.deepEqual(
    Object.keys(receipt.roles).sort(),
    Object.keys(definition.roles)
      .filter((role) => !["cameraCarrier", "cameraProvider"].includes(role))
      .sort(),
  );
  for (const inventory of Object.values(receipt.roles))
    validateInventory(inventory);
  return receipt;
}

function validateInventory(inventory) {
  assert.equal(inventory.schema, 1);
  assert.equal(inventory.signatureVerified, true);
  assert(Object.keys(inventory.code).length > 0);
  for (const [path, record] of [
    ...Object.entries(inventory.code),
    ...Object.entries(inventory.resources),
  ]) {
    assert(
      !path.startsWith("/") && !path.includes("\\") && !path.includes("\0"),
    );
    assert(
      path.split("/").every((part) => part && part !== "." && part !== ".."),
    );
    assert(
      Number.isInteger(record.mode) && record.mode >= 0 && record.mode <= 0o777,
    );
  }
  for (const record of Object.values(inventory.code)) {
    assert([2, 6].includes(record.filetype));
    for (const key of [
      "signedSHA256",
      "rawUnsignedSHA256",
      "normalizedUnsignedSHA256",
    ])
      assert.match(record[key], hash);
  }
  assert(inventory.signatures && typeof inventory.signatures === "object");
  for (const record of [
    ...Object.values(inventory.resources),
    ...Object.values(inventory.signatures),
  ]) {
    assert.match(record.sha256, hash);
    assert(Number.isSafeInteger(record.bytes) && record.bytes >= 0);
  }
}

export async function verifyFactoryOverlaySources(
  overlay,
  { originalRoot, fixtureRoot },
) {
  assert(["plugins", "studio"].includes(overlay.extensionID));
  assert.match(overlay.reviewedSource, commit);
  assert(overlay.sources.length > 0 && overlay.sources.length <= 8);
  const sourceFiles = [];
  for (const source of overlay.sources) {
    assert(source.path.startsWith(`Extensions/${overlay.extensionID}/`));
    assert(
      source.path
        .split("/")
        .every((part) => part && part !== "." && part !== ".."),
    );
    assert.match(source.originalSHA256, hash);
    assert.match(source.fixtureSHA256, hash);
    for (const [root, expected] of [
      [originalRoot, source.originalSHA256],
      [fixtureRoot, source.fixtureSHA256],
    ]) {
      const canonicalRoot = await realpath(root);
      const path = join(canonicalRoot, source.path);
      assert.equal(await realpath(path), path);
      const status = await lstat(path);
      assert(status.isFile() && !status.isSymbolicLink());
      assert.equal(
        sha256(await readFile(path)),
        expected,
        "Factory overlay source differs from its review",
      );
    }
    sourceFiles.push(source);
  }
  return { ...overlay, sourceFilesVerified: true, sources: sourceFiles };
}

export function proveFixturePayload(
  original,
  fixture,
  { extensionID, overlay },
) {
  assert.equal(original.extensionID, extensionID);
  assert.equal(fixture.extensionID, extensionID);
  assert.deepEqual(
    Object.keys(fixture.roles).sort(),
    Object.keys(original.roles).sort(),
  );
  assert.equal(Boolean(overlay), ["plugins", "studio"].includes(extensionID));
  const approved = new Map();
  if (overlay) {
    assert.equal(overlay.extensionID, extensionID);
    assert.match(overlay.reviewedSource, commit);
    assert.equal(overlay.reviewedSource, original.sourceCommit);
    assert.equal(overlay.sourceFilesVerified, true);
    assert.equal(overlay.functionalActionsValidated, false);
    assert(overlay.sources.length > 0 && overlay.sources.length <= 8);
    for (const source of overlay.sources) {
      assert(source.path.startsWith(`Extensions/${extensionID}/`));
      assert(
        source.path
          .split("/")
          .every((part) => part && part !== "." && part !== ".."),
      );
      assert.match(source.originalSHA256, hash);
      assert.match(source.fixtureSHA256, hash);
    }
    assert(overlay.codeChanges.length > 0 && overlay.codeChanges.length <= 8);
    for (const change of overlay.codeChanges) {
      assert.match(change.originalNormalizedSHA256, hash);
      assert.match(change.fixtureNormalizedSHA256, hash);
      const key = `${change.role}/${change.path}`;
      assert(!approved.has(key));
      approved.set(key, change);
    }
  }
  const code = [];
  let rawSignedPayloadUnchanged = true;
  for (const [role, before] of Object.entries(original.roles)) {
    const after = fixture.roles[role];
    validateInventory(before);
    validateInventory(after);
    rawSignedPayloadUnchanged &&=
      JSON.stringify(after.signatures) === JSON.stringify(before.signatures);
    assert.deepEqual(
      after.resources,
      before.resources,
      `${role} resources changed`,
    );
    assert.deepEqual(
      Object.keys(after.code).sort(),
      Object.keys(before.code).sort(),
    );
    for (const [path, originalCode] of Object.entries(before.code)) {
      const fixtureCode = after.code[path];
      assert.equal(fixtureCode.mode, originalCode.mode);
      assert.equal(fixtureCode.filetype, originalCode.filetype);
      const exception = approved.get(`${role}/${path}`);
      if (exception) {
        assert.equal(
          originalCode.normalizedUnsignedSHA256,
          exception.originalNormalizedSHA256,
        );
        assert.equal(
          fixtureCode.normalizedUnsignedSHA256,
          exception.fixtureNormalizedSHA256,
        );
        approved.delete(`${role}/${path}`);
      } else
        assert.equal(
          fixtureCode.normalizedUnsignedSHA256,
          originalCode.normalizedUnsignedSHA256,
          `${role}/${path} code changed`,
        );
      code.push({
        role,
        path,
        original: originalCode,
        fixture: fixtureCode,
        factoryOverlay: Boolean(exception),
      });
    }
  }
  assert.equal(approved.size, 0, "Overlay review contains absent code");
  return {
    schema: 1,
    extensionID,
    originalZipSHA256: original.zipSHA256,
    sourceCommit: original.sourceCommit,
    sourceFingerprint: original.sourceFingerprint,
    factoryOverlay: Boolean(overlay),
    featureCodeAndResourcesUnchanged: !overlay,
    overlayReview: overlay ?? null,
    rawSignedPayloadUnchanged:
      rawSignedPayloadUnchanged &&
      code.every(
        ({ original: before, fixture: after }) =>
          before.signedSHA256 === after.signedSHA256,
      ),
    functionalActionsValidated: false,
    code,
  };
}

export async function prepareCIArtifacts({
  repository,
  runID,
  sourceCommit,
  definitions,
  fingerprints,
  hostApp,
  hostSHA256,
  output,
  hostBuildMetadata,
  fetch: fetch_ = fetch,
  verifyPackage,
  signal,
  chunk,
}) {
  assert.equal(hostBuildMetadata.sourceCommit, sourceCommit);
  assert.equal(hostBuildMetadata.sourceTreeDirty, false);
  assert.equal(hostBuildMetadata.hostExecutableSHA256, hostSHA256);
  assert.match(hostSHA256, hash);
  const resolved = resolve(output);
  await mkdir(resolved, { mode: 0o700 });
  const status = await lstat(resolved);
  assert(
    status.isDirectory() &&
      !status.isSymbolicLink() &&
      status.uid === process.getuid() &&
      (status.mode & 0o077) === 0,
  );
  assert.equal(await realpath(resolved), resolved);
  assert.equal(
    sha256(await readFile(join(hostApp, "Contents/MacOS/Edith"))),
    hostSHA256,
  );
  const intake = await readCIArtifactSet({
    repository,
    runID,
    sourceCommit,
    definitions,
    fingerprints,
    fetch: fetch_,
    signal,
  });
  const originals = [];
  const helper = join(
    dirname(fileURLToPath(import.meta.url)),
    "verify-package.py",
  );
  const selected =
    chunk === undefined
      ? intake.originals
      : selectManagedArtifactRows(intake, definitions, chunk);
  for (const row of selected) {
    signal?.throwIfAborted();
    const directory = join(resolved, row.extensionID);
    await mkdir(directory, { mode: 0o700 });
    const artifactPath = join(directory, "ci-artifact.zip");
    await downloadCIArtifact({
      repository,
      row,
      destination: artifactPath,
      fetch: fetch_,
      signal,
    });
    const definition = definitions.find(({ id }) => id === row.extensionID);
    await writeFile(
      join(directory, "definition.json"),
      JSON.stringify(definition),
      { mode: 0o600 },
    );
    const arguments_ = [
      helper,
      artifactPath,
      directory,
      hostApp,
      sourceCommit,
      row.sourceFingerprint,
      hostSHA256,
    ];
    const receipt = verifyPackage
      ? await verifyPackage({ row, definition, arguments: arguments_, signal })
      : JSON.parse(
          (
            await execute("python3", arguments_, {
              timeout: 10 * 60 * 1000,
              maxBuffer: 32 * 1024 ** 2,
              signal,
            })
          ).stdout,
        );
    validatePackageReceipt(receipt, row, definition, sourceCommit, hostSHA256);
    const original = {
      ...row,
      archivePath: join(directory, "package", `${row.extensionID}.zip`),
      expandedDirectory: join(directory, "expanded", row.extensionID),
      zipSHA256: receipt.zipSHA256,
      receipt,
    };
    await writeFile(
      join(directory, "receipt.json"),
      `${JSON.stringify(original)}\n`,
      { mode: 0o600 },
    );
    originals.push(original);
  }
  assert.equal(
    sha256(await readFile(join(hostApp, "Contents/MacOS/Edith"))),
    hostSHA256,
  );
  const result = {
    ...intake,
    allOriginalArtifacts: intake.originals,
    sourceHostExecutableSHA256: hostSHA256,
    sourceHostBuildMetadata: hostBuildMetadata,
    originals,
    packageCodeExecuted: false,
  };
  await writeFile(
    join(resolved, "receipt.json"),
    `${JSON.stringify(result)}\n`,
    { mode: 0o600 },
  );
  return result;
}
