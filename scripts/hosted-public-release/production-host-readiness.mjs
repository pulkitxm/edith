import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { setTimeout as delay } from "node:timers/promises";
import {
  parseCatalogPointer,
  validateCatalogPointer,
  verifyCatalogPointerData,
} from "../extension-catalog-pointer.mjs";
import { missingPackages } from "../extension-release-ready.mjs";
import {
  validateCatalog,
  verifiedCatalogPayload,
} from "../verify-extension-catalog.mjs";
import { artifact, closedJSON, digest } from "./contract.mjs";
import {
  closedAssetInventory,
  evidenceTag,
  publicationStep,
  validateEvidence,
  verifiedComposition,
  verifiedEnvelope,
  verifiedEvidence,
  verifiedLineage,
} from "./evidence.mjs";
import { verifiedHostBootstrapIntent } from "./production-bootstrap.mjs";
import { matchingProductionCatalogRecord } from "./production-inputs.mjs";

const keys = (value, expected) => {
  assert(value && typeof value === "object" && !Array.isArray(value));
  assert.deepEqual(Object.keys(value).sort(), expected.toSorted());
};
const positive = (value, maximum = Number.MAX_SAFE_INTEGER) =>
  assert(Number.isSafeInteger(value) && value > 0 && value <= maximum);
const hash = (value) => assert.match(value, /^[a-f0-9]{64}$/);
export const hostReadinessAssetName = (host) => {
  positive(host.run);
  positive(host.runAttempt);
  return `host-readiness-${host.run}-${host.runAttempt}.json`;
};
export function verifyHostReadinessEnvelope(
  bytes,
  publicKey,
  capability,
  expected,
) {
  const intent = verifiedHostBootstrapIntent(capability);
  assert.equal(intent.role, "host");
  const payload = verifiedEnvelope(bytes, publicKey, 16384);
  keys(payload, [
    "schema",
    "purpose",
    "source",
    "host",
    "extensions",
    "previousCatalog",
    "candidateCatalog",
    "package",
    "nativeEvidence",
    "catalogReleaseID",
    "previousAssetID",
    "candidateAssetID",
  ]);
  assert.equal(payload.schema, 1);
  assert.equal(payload.purpose, "cohort-host-readiness");
  assert.equal(payload.source, intent.source);
  assert.deepEqual(payload.host, intent.host);
  keys(payload.extensions, ["run", "runAttempt"]);
  positive(payload.extensions.run);
  positive(payload.extensions.runAttempt);
  assert.notEqual(payload.extensions.run, intent.host.run);
  validateCatalogPointer(payload.previousCatalog);
  validateCatalogPointer(payload.candidateCatalog);
  assert.deepEqual(payload.previousCatalog, intent.previousCatalog);
  assert(payload.candidateCatalog.revision > payload.previousCatalog.revision);
  assert.notEqual(
    payload.candidateCatalog.sha256,
    payload.previousCatalog.sha256,
  );
  for (const key of ["catalogReleaseID", "previousAssetID", "candidateAssetID"])
    positive(payload[key]);
  assert.notEqual(payload.previousAssetID, payload.candidateAssetID);
  assert.equal(payload.package.id, "keepAwake");
  assert.equal(payload.package.version, "1.0.1");
  assert.deepEqual(payload.package.dependencies, []);
  validateCatalog({
    schemaVersion: 1,
    revision: 1,
    packages: [payload.package],
  });
  assert.equal(expected.length, 1);
  assert.equal(expected[0].id, "keepAwake");
  assert.deepEqual(
    missingPackages(expected, { packages: [payload.package] }),
    [],
  );
  const native = payload.nativeEvidence;
  keys(native, [
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
  ]);
  assert.equal(native.sourceCommit, intent.source);
  assert.equal(native.runID, payload.extensions.run);
  assert.equal(native.runAttempt, payload.extensions.runAttempt);
  assert.equal(
    native.tag,
    evidenceTag(intent.source, native.runID, native.runAttempt),
  );
  for (const key of ["envelopeSHA256", "compositionSHA256"]) hash(native[key]);
  for (const key of ["envelopeBytes", "compositionBytes"])
    positive(native[key], 1024 ** 2);
  for (const key of ["releaseID", "envelopeAssetID", "compositionAssetID"])
    positive(native[key]);
  assert.notEqual(native.envelopeAssetID, native.compositionAssetID);
  return payload;
}
export function verifyHostReadinessNativeFacts(
  payload,
  { run, jobs, artifacts },
) {
  validateEvidence(payload);
  assert.equal(run.repository?.full_name, "pulkitxm/edith");
  assert.equal(run.repository?.id, 1289153439);
  assert.equal(run.id, payload.runID);
  assert.equal(run.run_attempt, payload.runAttempt);
  assert.equal(run.head_sha, payload.sourceCommit);
  assert.equal(run.head_branch, "main");
  assert.equal(run.path, ".github/workflows/extensions.yml");
  assert.equal(run.event, "workflow_dispatch");
  assert.equal(payload.event, run.event);
  assert([65671483, 320458784].includes(run.actor?.id));
  if (run.triggering_actor)
    assert([65671483, 320458784].includes(run.triggering_actor.id));
  assert.equal(run.status, "in_progress");
  assert.equal(run.conclusion, null);
  assert.deepEqual(payload.plannedIDs, ["keepAwake"]);
  assert.equal(jobs.total_count, payload.jobs.length);
  assert.equal(jobs.jobs.length, jobs.total_count);
  assert.equal(new Set(jobs.jobs.map((job) => job.id)).size, jobs.jobs.length);
  for (const expected of payload.jobs) {
    const rows = jobs.jobs.filter(
      (row) => row.id === expected.id && row.name === expected.name,
    );
    assert.equal(rows.length, 1);
    const job = rows[0];
    assert.equal(job.run_id, run.id);
    assert.equal(
      job.status,
      job.name === "publish" ? "in_progress" : "completed",
    );
    assert.equal(job.conclusion, job.name === "publish" ? null : "success");
    for (const step of expected.steps) {
      const matching = job.steps.filter(
        (row) => row.name === step.name && row.number === step.number,
      );
      assert.equal(matching.length, 1);
      assert.equal(matching[0].status, "completed");
      assert.equal(matching[0].conclusion, "success");
    }
    if (job.name === "publish") {
      const active = job.steps.filter((step) => step.name === publicationStep);
      assert.equal(active.length, 1);
      assert.equal(active[0].status, "in_progress");
      assert.equal(active[0].conclusion, null);
    }
  }
  assert.equal(artifacts.total_count, payload.artifacts.length);
  assert.equal(artifacts.artifacts.length, artifacts.total_count);
  for (const row of payload.artifacts) {
    const observed = artifact(
      artifacts.artifacts,
      row.name,
      run,
      payload.sourceCommit,
    );
    assert.deepEqual(observed, {
      artifactID: row.artifactID,
      artifactBytes: row.artifactBytes,
      artifactSHA256: row.artifactSHA256,
    });
  }
}
function releaseAsset(release, name, expected = {}) {
  positive(release.id);
  assert.equal(release.draft, false);
  const matches = release.assets.filter((asset) => asset.name === name);
  assert.equal(matches.length, 1);
  const asset = matches[0];
  positive(asset.id);
  positive(asset.size, 512 * 1024 ** 2);
  assert.equal(asset.state, "uploaded");
  assert.match(asset.digest, /^sha256:[a-f0-9]{64}$/);
  assert.equal(
    asset.browser_download_url,
    `https://github.com/pulkitxm/edith/releases/download/${encodeURIComponent(release.tag_name)}/${name}`,
  );
  for (const [key, value] of Object.entries(expected))
    assert.equal(asset[key], value);
  return asset;
}
const assetIdentity = (asset) => [
  asset.id,
  asset.name,
  asset.size,
  asset.digest,
  asset.state,
  asset.browser_download_url,
];
const releaseIdentity = (release) => [
  release.id,
  release.tag_name,
  release.target_commitish,
  release.draft,
  release.prerelease,
  release.assets.map(assetIdentity).sort((a, b) => a[1].localeCompare(b[1])),
];
export async function readHostReadinessBytes(
  asset,
  environment,
  remaining,
  { collect = true, fetch_ = fetch } = {},
) {
  positive(asset.id);
  positive(asset.size, collect ? 3 * 1024 ** 2 : 512 * 1024 ** 2);
  const response = await fetch_(
    `https://api.github.com/repos/pulkitxm/edith/releases/assets/${asset.id}`,
    {
      headers: {
        Accept: "application/octet-stream",
        Authorization: `Bearer ${environment.GITHUB_TOKEN ?? environment.GH_TOKEN}`,
      },
      signal: AbortSignal.timeout(Math.min(15000, remaining())),
    },
  );
  if (response.status !== 200) {
    await response.body?.cancel();
    assert.equal(response.status, 200);
  }
  const reader = response.body.getReader();
  const checksum = createHash("sha256");
  const chunks = [];
  let used = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      remaining();
      used += value.length;
      assert(used <= asset.size);
      checksum.update(value);
      if (collect) chunks.push(value);
    }
  } finally {
    await reader.cancel();
  }
  remaining();
  assert.equal(used, asset.size);
  assert.equal(`sha256:${checksum.digest("hex")}`, asset.digest);
  return collect ? Buffer.concat(chunks, used) : undefined;
}
export async function waitForStagedHostReadiness(
  capability,
  expected,
  publicKey,
  environment,
  {
    timeout = 120 * 60_000,
    interval = 15000,
    now = Date.now,
    sleep = delay,
    fetch_ = fetch,
  } = {},
) {
  assert(
    Number.isSafeInteger(timeout) && timeout >= 0 && timeout <= 120 * 60_000,
  );
  assert(Number.isSafeInteger(interval) && interval > 0 && interval <= 60000);
  const intent = verifiedHostBootstrapIntent(capability);
  assert.equal(intent.role, "host");
  const deadline = now() + timeout;
  const remaining = () => {
    const value = Math.floor(deadline - now());
    assert(value > 0, "Staged host readiness deadline expired");
    return value;
  };
  const api = async (path) => {
    assert(
      /^\/(?:releases\/tags\/[^?#]+|git\/ref\/tags\/[^?#]+|actions\/runs\/[0-9]+(?:\/attempts\/[0-9]+\/jobs\?per_page=100|\/artifacts\?per_page=100)?)$/.test(
        path,
      ),
    );
    const response = await fetch_(
      `https://api.github.com/repos/pulkitxm/edith${path}`,
      {
        headers: {
          Accept: "application/vnd.github+json",
          "Cache-Control": "no-cache",
          Authorization: `Bearer ${environment.GITHUB_TOKEN ?? environment.GH_TOKEN}`,
        },
        signal: AbortSignal.timeout(Math.min(15000, remaining())),
      },
    );
    if (response.status !== 200) {
      await response.body?.cancel();
      assert.equal(response.status, 200);
    }
    const reader = response.body.getReader();
    const chunks = [];
    let used = 0;
    try {
      while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        remaining();
        used += value.length;
        assert(used <= 1024 ** 2);
        chunks.push(value);
      }
    } finally {
      await reader.cancel();
    }
    remaining();
    return closedJSON(Buffer.concat(chunks).toString(), 1024 ** 2);
  };
  const bytes = (asset, collect = true) =>
    readHostReadinessBytes(asset, environment, remaining, { collect, fetch_ });
  const live = async () => {
    const release = await api("/releases/tags/extension-catalog-v1");
    assert.equal(release.tag_name, "extension-catalog-v1");
    assert.equal(release.draft, false);
    assert.deepEqual(parseCatalogPointer(release.body), intent.previousCatalog);
    const asset = releaseAsset(release, intent.previousCatalog.assetName, {
      size: intent.previousCatalog.bytes,
      digest: `sha256:${intent.previousCatalog.sha256}`,
    });
    const data = verifyCatalogPointerData(
      await bytes(asset),
      intent.previousCatalog,
    );
    const catalog = closedJSON(
      verifiedCatalogPayload(data, publicKey).toString(),
      3 * 1024 ** 2,
    );
    const old = intent.template.packages.previous;
    const matching = catalog.packages.filter(
      (row) =>
        row.id === old.id &&
        row.hostABI === old.hostABI &&
        row.architecture === old.architecture &&
        row.version === old.version,
    );
    assert.equal(matching.length, 1);
    matchingProductionCatalogRecord(catalog.packages, matching[0]);
    for (const [key, value] of Object.entries({
      sourceFingerprint: old.sourceFingerprint,
      sha256: old.archiveSHA256,
      downloadURL: old.archiveURL,
      downloadBytes: old.downloadBytes,
      installedBytes: old.installedBytes,
    }))
      assert.deepEqual(matching[0][key], value);
    return { release, asset };
  };
  while (true) {
    remaining();
    await intent.revalidate();
    const old = await live();
    const matches = old.release.assets.filter(
      (asset) => asset.name === hostReadinessAssetName(intent.host),
    );
    assert(matches.length <= 1);
    if (matches.length === 0) {
      await sleep(Math.min(interval, remaining()));
      continue;
    }
    const descriptor = releaseAsset(
      old.release,
      hostReadinessAssetName(intent.host),
    );
    assert(descriptor.size <= 16384);
    const payload = verifyHostReadinessEnvelope(
      await bytes(descriptor),
      publicKey,
      capability,
      expected,
    );
    assert.equal(payload.catalogReleaseID, old.release.id);
    assert.equal(payload.previousAssetID, old.asset.id);
    const candidate = releaseAsset(
      old.release,
      payload.candidateCatalog.assetName,
      {
        id: payload.candidateAssetID,
        size: payload.candidateCatalog.bytes,
        digest: `sha256:${payload.candidateCatalog.sha256}`,
      },
    );
    const catalog = closedJSON(
      verifiedCatalogPayload(
        verifyCatalogPointerData(
          await bytes(candidate),
          payload.candidateCatalog,
        ),
        publicKey,
      ).toString(),
      3 * 1024 ** 2,
    );
    assert.equal(catalog.revision, payload.candidateCatalog.revision);
    assert.deepEqual(missingPackages(expected, catalog), []);
    matchingProductionCatalogRecord(catalog.packages, payload.package);
    const record = payload.package;
    const tag = `extensions/keepAwake/1.0.1-${record.sourceFingerprint.slice(0, 20)}`;
    const ref = await api(`/git/ref/tags/${encodeURIComponent(tag)}`);
    assert.equal(ref.ref, `refs/tags/${tag}`);
    assert.equal(ref.object?.type, "commit");
    assert.equal(ref.object.sha, intent.source);
    const published = await api(`/releases/tags/${encodeURIComponent(tag)}`);
    assert.equal(published.tag_name, tag);
    assert.equal(published.target_commitish, intent.source);
    const recordBytes = await bytes(releaseAsset(published, "keepAwake.json"));
    assert.deepEqual(closedJSON(recordBytes.toString(), 65536), record);
    await bytes(
      releaseAsset(published, "keepAwake.zip", {
        size: record.downloadBytes,
        digest: `sha256:${record.sha256}`,
      }),
      false,
    );
    const lineageBytes = await bytes(
      releaseAsset(published, "keepAwake.native-evidence.json"),
    );
    const lineage = verifiedLineage(lineageBytes, publicKey, record);
    const native = payload.nativeEvidence;
    assert.equal(lineage.sourceCommit, intent.source);
    assert.equal(lineage.runID, native.runID);
    assert.equal(lineage.runAttempt, native.runAttempt);
    assert.equal(lineage.evidenceTag, native.tag);
    assert.equal(lineage.evidenceSHA256, native.envelopeSHA256);
    assert.equal(lineage.evidenceBytes, native.envelopeBytes);
    const evidence = await api(
      `/releases/tags/${encodeURIComponent(native.tag)}`,
    );
    const evidenceRef = await api(
      `/git/ref/tags/${encodeURIComponent(native.tag)}`,
    );
    assert.equal(evidenceRef.ref, `refs/tags/${native.tag}`);
    assert.equal(evidenceRef.object?.type, "commit");
    assert.equal(evidenceRef.object.sha, intent.source);
    assert.equal(evidence.id, native.releaseID);
    assert.equal(evidence.tag_name, native.tag);
    assert.equal(evidence.target_commitish, intent.source);
    const envelope = await bytes(
      releaseAsset(evidence, "native-evidence.json", {
        id: native.envelopeAssetID,
        size: native.envelopeBytes,
        digest: `sha256:${native.envelopeSHA256}`,
      }),
    );
    const compositionBytes = await bytes(
      releaseAsset(evidence, "publication-composition.json", {
        id: native.compositionAssetID,
        size: native.compositionBytes,
        digest: `sha256:${native.compositionSHA256}`,
      }),
    );
    const nativePayload = verifiedEvidence(envelope, publicKey);
    const composition = verifiedComposition(compositionBytes, publicKey, {
      source: intent.source,
      runID: native.runID,
      attempt: native.runAttempt,
      records: [record],
      fingerprints: { keepAwake: record.sourceFingerprint },
    });
    assert.equal(composition.packages[0].lineageSHA256, digest(lineageBytes));
    assert.equal(composition.packages[0].lineageBytes, lineageBytes.length);
    closedAssetInventory(
      nativePayload,
      { bytes: native.envelopeBytes, sha256: native.envelopeSHA256 },
      evidence.assets,
      { bytes: native.compositionBytes, sha256: native.compositionSHA256 },
    );
    verifyHostReadinessNativeFacts(nativePayload, {
      run: await api(`/actions/runs/${native.runID}`),
      jobs: await api(
        `/actions/runs/${native.runID}/attempts/${native.runAttempt}/jobs?per_page=100`,
      ),
      artifacts: await api(
        `/actions/runs/${native.runID}/artifacts?per_page=100`,
      ),
    });
    const fresh = await live();
    assert.equal(fresh.release.id, old.release.id);
    assert.equal(fresh.asset.id, old.asset.id);
    for (const captured of [descriptor, candidate])
      assert.deepEqual(
        assetIdentity(releaseAsset(fresh.release, captured.name)),
        assetIdentity(captured),
      );
    assert.deepEqual(
      releaseIdentity(await api(`/releases/tags/${encodeURIComponent(tag)}`)),
      releaseIdentity(published),
    );
    assert.deepEqual(
      releaseIdentity(
        await api(`/releases/tags/${encodeURIComponent(native.tag)}`),
      ),
      releaseIdentity(evidence),
    );
    const finalRun = await api(`/actions/runs/${native.runID}`);
    assert.equal(finalRun.id, native.runID);
    assert.equal(finalRun.run_attempt, native.runAttempt);
    assert.equal(finalRun.head_sha, intent.source);
    assert.equal(finalRun.status, "in_progress");
    assert.equal(finalRun.conclusion, null);
    await intent.revalidate();
    remaining();
    return payload;
  }
}
