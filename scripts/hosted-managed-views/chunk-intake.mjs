import assert from "node:assert/strict";

export function validateManagedChunkArtifacts({
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
  assert.equal(run.path, ".github/workflows/ci.yml");
  assert.equal(run.event, "workflow_dispatch");
  assert(["in_progress", "completed"].includes(run.status));
  if (run.status === "completed") assert.equal(run.conclusion, "success");
  assert(jobs.length <= 1000 && artifacts.length <= 1000);
  assert.equal(new Set(jobs.map(({ id }) => id)).size, jobs.length);
  assert.equal(new Set(artifacts.map(({ id }) => id)).size, artifacts.length);
  assert.deepEqual(
    artifacts
      .filter(({ name }) =>
        name.startsWith("hosted-managed-original-view-chunk-"),
      )
      .map(({ name }) => name)
      .sort(),
    [0, 1, 2].map((chunk) => `hosted-managed-original-view-chunk-${chunk}`),
  );
  return [0, 1, 2].map((chunk) => {
    const matchingJobs = jobs.filter(
      ({ name }) => name === `hosted-managed-views / managed views (${chunk})`,
    );
    assert.equal(matchingJobs.length, 1);
    const job = matchingJobs[0];
    assert.equal(job.run_id, runID);
    assert.equal(job.status, "completed");
    assert.equal(job.conclusion, "success");
    assert(Number.isSafeInteger(job.id) && job.id > 0);
    const matchingAssets = artifacts.filter(
      ({ name }) => name === `hosted-managed-original-view-chunk-${chunk}`,
    );
    assert.equal(matchingAssets.length, 1);
    const asset = matchingAssets[0];
    assert(Number.isSafeInteger(asset.id) && asset.id > 0);
    assert(
      Number.isSafeInteger(asset.size_in_bytes) &&
        asset.size_in_bytes > 0 &&
        asset.size_in_bytes <= 4 * 1024 ** 2,
    );
    assert.equal(asset.expired, false);
    assert.equal(asset.workflow_run?.id, runID);
    assert.equal(asset.workflow_run?.head_sha, sourceCommit);
    assert.match(asset.digest, /^sha256:[a-f0-9]{64}$/);
    return {
      chunk,
      jobID: job.id,
      artifactID: asset.id,
      artifactBytes: asset.size_in_bytes,
      artifactSHA256: asset.digest.slice(7),
    };
  });
}

async function abortable(promise, signal) {
  signal.throwIfAborted();
  let abort;
  try {
    return await Promise.race([
      promise,
      new Promise((_, reject) => {
        abort = () => reject(signal.reason);
        signal.addEventListener("abort", abort, { once: true });
      }),
    ]);
  } finally {
    signal.removeEventListener("abort", abort);
  }
}

export async function readManagedChunkArtifacts({
  fetch: fetch_,
  runID,
  sourceCommit,
  signal = AbortSignal.timeout(60000),
}) {
  const base = `https://api.github.com/repos/pulkitxm/edith/actions/runs/${runID}`;
  async function document(url) {
    const response = await abortable(
      fetch_(url, {
        signal,
        headers: { Accept: "application/vnd.github+json" },
      }),
      signal,
    );
    assert.equal(response.status, 200);
    const reader = response.body.getReader();
    let bytes = 0;
    const chunks = [];
    try {
      while (true) {
        const { done, value } = await abortable(reader.read(), signal);
        if (done) break;
        bytes += value.length;
        assert(bytes <= 4 * 1024 ** 2);
        chunks.push(value);
      }
    } finally {
      reader.cancel().catch(() => {});
    }
    return JSON.parse(Buffer.concat(chunks).toString("utf8"));
  }
  async function inventory(kind) {
    const result = [];
    for (let page = 1; page <= 10; page++) {
      const value = await document(`${base}/${kind}?per_page=100&page=${page}`);
      assert(
        Number.isSafeInteger(value.total_count) &&
          value.total_count >= 0 &&
          value.total_count <= 1000,
      );
      assert(Array.isArray(value[kind]) && value[kind].length <= 100);
      result.push(...value[kind]);
      if (result.length >= value.total_count) {
        assert.equal(result.length, value.total_count);
        return result;
      }
      assert.equal(value[kind].length, 100);
    }
    throw new Error("Chunk metadata exceeds its inventory bound");
  }
  const run = await document(base);
  const [jobs, artifacts] = await Promise.all([
    inventory("jobs"),
    inventory("artifacts"),
  ]);
  return validateManagedChunkArtifacts({
    run,
    jobs,
    artifacts,
    runID,
    sourceCommit,
  });
}
