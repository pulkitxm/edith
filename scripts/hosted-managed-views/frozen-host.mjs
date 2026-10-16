import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { lstat, mkdir, readFile, realpath, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { downloadCIArtifact } from "./package-preparation.mjs";

export function validateFrozenHostArtifact({
  run,
  jobs,
  artifacts,
  runID,
  sourceCommit,
}) {
  assert(Number.isSafeInteger(runID) && runID > 0);
  assert.match(sourceCommit, /^[a-f0-9]{40}$/);
  assert.equal(run.id, runID);
  assert.equal(run.head_sha, sourceCommit);
  assert.equal(run.path, ".github/workflows/extensions.yml");
  assert.equal(run.status, "completed");
  assert.equal(run.conclusion, "success");
  assert(jobs.length <= 1000 && artifacts.length <= 1000);
  const matchingJobs = jobs.filter(({ name }) => name === "frozen-host");
  assert.equal(matchingJobs.length, 1);
  const job = matchingJobs[0];
  assert.equal(job.run_id, runID);
  assert.equal(job.status, "completed");
  assert.equal(job.conclusion, "success");
  assert(Number.isSafeInteger(job.id) && job.id > 0);
  const matchingAssets = artifacts.filter(
    ({ name }) => name === "frozen-extension-host",
  );
  assert.equal(matchingAssets.length, 1);
  const asset = matchingAssets[0];
  assert(Number.isSafeInteger(asset.id) && asset.id > 0);
  assert(
    Number.isSafeInteger(asset.size_in_bytes) &&
      asset.size_in_bytes > 0 &&
      asset.size_in_bytes <= 2 * 1024 ** 3,
  );
  assert.equal(asset.expired, false);
  assert.equal(asset.workflow_run?.id, runID);
  assert.equal(asset.workflow_run?.head_sha, sourceCommit);
  assert.match(asset.digest, /^sha256:[a-f0-9]{64}$/);
  return {
    schema: 1,
    sourceCommit,
    runID,
    jobID: job.id,
    artifactID: asset.id,
    artifactBytes: asset.size_in_bytes,
    artifactSHA256: asset.digest.slice(7),
  };
}

export function validateFrozenHostMetadata(
  metadata,
  sourceCommit,
  executableSHA256,
) {
  assert.equal(metadata.sourceCommit, sourceCommit);
  assert.equal(metadata.sourceTreeDirty, false);
  assert.equal(metadata.hostExecutableSHA256, executableSHA256);
  assert.match(executableSHA256, /^[a-f0-9]{64}$/);
  assert.equal(metadata.architecture, "arm64");
  assert.equal(metadata.configuration, "Release");
  assert.equal(metadata.optimization, "Osize");
  assert.equal(metadata.linkTimeOptimization, "full");
  assert.equal(metadata.signature, "ad-hoc");
  assert(typeof metadata.xcode === "string" && metadata.xcode.length < 256);
  assert(typeof metadata.sdk === "string" && metadata.sdk.length < 32);
  return metadata;
}

export async function readFrozenHostArtifact({
  fetch: fetch_,
  runID,
  sourceCommit,
  signal,
}) {
  const base = `https://api.github.com/repos/pulkitxm/edith/actions/runs/${runID}`;
  const boundedSignal = signal
    ? AbortSignal.any([signal, AbortSignal.timeout(60000)])
    : AbortSignal.timeout(60000);
  async function document(url) {
    const response = await fetch_(url, {
      signal: boundedSignal,
      headers: { Accept: "application/vnd.github+json" },
    });
    assert.equal(response.status, 200);
    assert(response.body);
    const chunks = [];
    let bytes = 0;
    const reader = response.body.getReader();
    try {
      while (true) {
        boundedSignal.throwIfAborted();
        const { done, value } = await reader.read();
        if (done) break;
        bytes += value.length;
        assert(bytes <= 8 * 1024 ** 2);
        chunks.push(value);
      }
    } finally {
      await reader.cancel().catch(() => {});
    }
    return JSON.parse(Buffer.concat(chunks).toString("utf8"));
  }
  async function inventory(kind) {
    const rows = [];
    for (let page = 1; page <= 10; page++) {
      const value = await document(`${base}/${kind}?per_page=100&page=${page}`);
      assert(
        Number.isSafeInteger(value.total_count) &&
          value.total_count >= 0 &&
          value.total_count <= 1000,
      );
      assert(Array.isArray(value[kind]) && value[kind].length <= 100);
      rows.push(...value[kind]);
      if (rows.length === value.total_count) return rows;
      assert(rows.length < value.total_count && value[kind].length === 100);
    }
    throw new Error("Frozen host CI inventory exceeds its bound");
  }
  const run = await document(base);
  const [jobs, artifacts] = await Promise.all([
    inventory("jobs"),
    inventory("artifacts"),
  ]);
  return validateFrozenHostArtifact({
    run,
    jobs,
    artifacts,
    runID,
    sourceCommit,
  });
}

export async function prepareFrozenHost({
  runID,
  sourceCommit,
  output,
  fetch: fetch_,
  signal,
  execute = execFileSync,
}) {
  const row = await readFrozenHostArtifact({
    fetch: fetch_,
    runID,
    sourceCommit,
    signal,
  });
  assert.equal(await realpath(output), output);
  const status = await lstat(output);
  assert(
    status.isDirectory() &&
      !status.isSymbolicLink() &&
      status.uid === process.getuid() &&
      (status.mode & 0o7777) === 0o700,
  );
  const archive = join(output, "frozen-host.zip");
  await downloadCIArtifact({
    repository: "pulkitxm/edith",
    row,
    destination: archive,
    fetch: fetch_,
    signal,
  });
  const directory = join(output, "original-host");
  await mkdir(directory, { mode: 0o700 });
  const helper = join(
    dirname(fileURLToPath(import.meta.url)),
    "frozen-host-artifact.py",
  );
  const extraction = JSON.parse(
    execute("python3", [helper, archive, directory], {
      timeout: 120000,
      maxBuffer: 65536,
    }).toString(),
  );
  assert.equal(extraction.artifactSHA256, row.artifactSHA256);
  assert.equal(extraction.codeExecuted, false);
  assert.equal(extraction.hostApp, join(directory, "Edith.app"));
  assert.equal(
    extraction.hostBuildMetadata,
    join(directory, "build-metadata.json"),
  );
  const bytes = await readFile(extraction.hostBuildMetadata);
  assert(bytes.length <= 1024 ** 2);
  const hostSHA256 = createHash("sha256")
    .update(await readFile(join(extraction.hostApp, "Contents/MacOS/Edith")))
    .digest("hex");
  const metadata = validateFrozenHostMetadata(
    JSON.parse(bytes),
    sourceCommit,
    hostSHA256,
  );
  execute("codesign", ["--verify", "--deep", "--strict", extraction.hostApp], {
    timeout: 60000,
    maxBuffer: 65536,
  });
  const receipt = {
    ...row,
    hostApp: extraction.hostApp,
    hostSHA256,
    hostBuildMetadata: metadata,
    signaturesVerified: true,
    codeExecuted: false,
  };
  await writeFile(
    join(output, "original-host-receipt.json"),
    JSON.stringify(receipt, null, 2),
    { mode: 0o600, flag: "wx" },
  );
  return receipt;
}
