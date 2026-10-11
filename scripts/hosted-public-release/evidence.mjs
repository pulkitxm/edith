import assert from "node:assert/strict";
import { createPublicKey, verify } from "node:crypto";
import {
  managedNativeBuildSteps,
  managedNativeTestSteps,
} from "../hosted-managed-views/native-ci-contract.mjs";
import {
  artifact,
  closedJSON,
  repository,
  successfulRun,
} from "./contract.mjs";

export const maximumEvidenceBytes = 1024 ** 2;
const commit = /^[a-f0-9]{40}$/;
const hash = /^[a-f0-9]{64}$/;
const integer = (value, maximum = Number.MAX_SAFE_INTEGER) =>
  assert(Number.isSafeInteger(value) && value > 0 && value <= maximum);
const keys = (value, expected) => {
  assert(value && typeof value === "object" && !Array.isArray(value));
  assert.deepEqual(Object.keys(value).sort(), expected.sort());
};
export const evidenceTag = (source, runID, attempt) => {
  assert.match(source, commit);
  integer(runID);
  integer(attempt);
  return `extension-evidence/${source}/${runID}-${attempt}`;
};
export const evidenceURL = (payload, name) =>
  `https://github.com/${repository}/releases/download/${encodeURIComponent(evidenceTag(payload.sourceCommit, payload.runID, payload.runAttempt))}/${name}`;

function requiredSteps(name) {
  return name === "tests"
    ? managedNativeTestSteps
    : name.startsWith("build (")
      ? managedNativeBuildSteps
      : name === "publish"
        ? ["Publish immutable extension releases and the signed catalog"]
        : [];
}

function jobsIdentity(jobs, plannedIDs, runID, staging) {
  const expected = [
    "plan",
    "frozen-host",
    "tests",
    "publish",
    ...plannedIDs.map((id) => `build (${id})`),
  ];
  assert.equal(jobs.length, expected.length);
  assert.equal(new Set(jobs.map(({ id }) => id)).size, expected.length);
  assert.deepEqual(jobs.map(({ name }) => name).sort(), expected.sort());
  return jobs
    .map((job) => {
      integer(job.id);
      assert.equal(job.run_id, runID);
      const active = staging && job.name === "publish";
      assert.equal(job.status, active ? "in_progress" : "completed");
      assert.equal(job.conclusion, active ? null : "success");
      const steps = requiredSteps(job.name).map((name) => {
        const found = job.steps.filter((step) => step.name === name);
        assert.equal(found.length, 1);
        const step = found[0];
        integer(step.number);
        assert.equal(step.status, active ? "in_progress" : "completed");
        assert.equal(step.conclusion, active ? null : "success");
        return { name, number: step.number };
      });
      return { id: job.id, name: job.name, steps };
    })
    .sort((left, right) => left.name.localeCompare(right.name));
}

export function validateEvidence(payload) {
  keys(payload, [
    "schema",
    "kind",
    "repository",
    "workflowPath",
    "event",
    "sourceCommit",
    "runID",
    "runAttempt",
    "plannedIDs",
    "fingerprints",
    "jobs",
    "artifacts",
  ]);
  assert.equal(payload.schema, 1);
  assert.equal(payload.kind, "extension-native-evidence");
  assert.equal(payload.repository, repository);
  assert.equal(payload.workflowPath, ".github/workflows/extensions.yml");
  assert(["push", "workflow_dispatch"].includes(payload.event));
  evidenceTag(payload.sourceCommit, payload.runID, payload.runAttempt);
  assert(
    Array.isArray(payload.plannedIDs) &&
      payload.plannedIDs.length > 0 &&
      payload.plannedIDs.length <= 39,
  );
  assert.equal(new Set(payload.plannedIDs).size, payload.plannedIDs.length);
  assert.equal(Object.keys(payload.fingerprints).length, 39);
  for (const [id, value] of Object.entries(payload.fingerprints)) {
    assert.match(id, /^[A-Za-z][A-Za-z0-9_-]{0,63}$/);
    assert.match(value, hash);
  }
  assert(
    payload.plannedIDs.every((id) => Object.hasOwn(payload.fingerprints, id)),
  );
  const names = [
    "extension-plan",
    "frozen-extension-host",
    ...payload.plannedIDs.map((id) => `extension-${id}`),
  ];
  assert(Array.isArray(payload.artifacts));
  assert.deepEqual(
    payload.artifacts.map(({ name }) => name).sort(),
    names.sort(),
  );
  assert.equal(
    new Set(payload.artifacts.map(({ artifactID }) => artifactID)).size,
    names.length,
  );
  for (const row of payload.artifacts) {
    keys(row, [
      "name",
      "artifactID",
      "artifactBytes",
      "artifactSHA256",
      "assetName",
    ]);
    integer(row.artifactID);
    integer(row.artifactBytes, 1024 ** 3);
    assert.match(row.artifactSHA256, hash);
    assert.equal(row.assetName, `${row.name}-${row.artifactID}.zip`);
  }
  assert(Array.isArray(payload.jobs));
  const jobs = payload.jobs.map((job) => {
    keys(job, ["id", "name", "steps"]);
    assert(Array.isArray(job.steps));
    for (const step of job.steps) keys(step, ["name", "number"]);
    return {
      ...job,
      run_id: payload.runID,
      status: "completed",
      conclusion: "success",
      steps: job.steps.map((step) => ({
        ...step,
        status: "completed",
        conclusion: "success",
      })),
    };
  });
  assert.deepEqual(
    jobsIdentity(jobs, payload.plannedIDs, payload.runID, false),
    payload.jobs,
  );
  assert(
    Buffer.byteLength(JSON.stringify(payload)) <= maximumEvidenceBytes / 2,
  );
  return payload;
}

export function stagedEvidence({
  run,
  jobs,
  artifacts,
  source,
  plannedIDs,
  fingerprints,
  environment,
}) {
  assert.equal(environment.GITHUB_ACTIONS, "true");
  assert.equal(environment.RUNNER_ENVIRONMENT, "github-hosted");
  assert.equal(environment.RUNNER_OS, "macOS");
  assert.equal(environment.GITHUB_REF, "refs/heads/main");
  assert.equal(environment.GITHUB_REPOSITORY, repository);
  assert.equal(environment.GITHUB_SHA, source);
  assert.equal(String(run.id), environment.GITHUB_RUN_ID);
  assert.equal(String(run.run_attempt), environment.GITHUB_RUN_ATTEMPT);
  assert.equal(environment.GITHUB_JOB, "publish");
  assert.equal(run.repository?.full_name, repository);
  assert.equal(run.path, ".github/workflows/extensions.yml");
  assert.equal(run.head_sha, source);
  assert.equal(run.head_branch, "main");
  assert.equal(run.status, "in_progress");
  assert.equal(run.conclusion, null);
  const names = [
    "extension-plan",
    "frozen-extension-host",
    ...plannedIDs.map((id) => `extension-${id}`),
  ];
  assert.deepEqual(artifacts.map(({ name }) => name).sort(), names.sort());
  return validateEvidence({
    schema: 1,
    kind: "extension-native-evidence",
    repository,
    workflowPath: run.path,
    event: run.event,
    sourceCommit: source,
    runID: run.id,
    runAttempt: run.run_attempt,
    plannedIDs,
    fingerprints,
    jobs: jobsIdentity(jobs, plannedIDs, run.id, true),
    artifacts: names.map((name) => {
      const row = artifact(artifacts, name, run, source);
      return { name, ...row, assetName: `${name}-${row.artifactID}.zip` };
    }),
  });
}

export function verifiedEnvelope(
  bytes,
  publicKey,
  maximum = maximumEvidenceBytes,
) {
  assert(bytes instanceof Uint8Array && bytes.length <= maximum);
  const envelope = closedJSON(
    new TextDecoder("utf-8", { fatal: true }).decode(bytes),
    maximum,
  );
  keys(envelope, ["payload", "signature"]);
  function base64(value, maximum, length) {
    assert(
      typeof value === "string" && value.length <= Math.ceil(maximum / 3) * 4,
    );
    const data = Buffer.from(value, "base64");
    assert(
      data.length > 0 &&
        data.length <= maximum &&
        data.toString("base64") === value,
    );
    if (length) assert.equal(data.length, length);
    return data;
  }
  const data = base64(envelope.payload, maximum / 2);
  const signature = base64(envelope.signature, 64, 64);
  const key = createPublicKey({
    key: {
      kty: "OKP",
      crv: "Ed25519",
      x: base64(publicKey, 32, 32).toString("base64url"),
    },
    format: "jwk",
  });
  assert(verify(null, data, key, signature));
  return closedJSON(
    new TextDecoder("utf-8", { fatal: true }).decode(data),
    maximum / 2,
  );
}

export const verifiedEvidence = (bytes, publicKey) =>
  validateEvidence(verifiedEnvelope(bytes, publicKey));

export function nativeLineage(record, payload, envelopeBytes) {
  validateEvidence(payload);
  assert(payload.plannedIDs.includes(record.id));
  assert.equal(record.sourceFingerprint, payload.fingerprints[record.id]);
  assert.match(record.sha256, hash);
  return {
    schema: 1,
    kind: "extension-native-lineage",
    repository,
    package: record,
    sourceCommit: payload.sourceCommit,
    runID: payload.runID,
    runAttempt: payload.runAttempt,
    evidenceTag: evidenceTag(
      payload.sourceCommit,
      payload.runID,
      payload.runAttempt,
    ),
    evidenceSHA256: envelopeBytes.sha256,
    evidenceBytes: envelopeBytes.bytes,
  };
}

export function verifiedLineage(bytes, publicKey, record) {
  const payload = verifiedEnvelope(bytes, publicKey, 16 * 1024);
  keys(payload, [
    "schema",
    "kind",
    "repository",
    "package",
    "sourceCommit",
    "runID",
    "runAttempt",
    "evidenceTag",
    "evidenceSHA256",
    "evidenceBytes",
  ]);
  assert.equal(payload.schema, 1);
  assert.equal(payload.kind, "extension-native-lineage");
  assert.equal(payload.repository, repository);
  assert.deepEqual(payload.package, record);
  assert.equal(
    payload.evidenceTag,
    evidenceTag(payload.sourceCommit, payload.runID, payload.runAttempt),
  );
  assert.match(payload.evidenceSHA256, hash);
  integer(payload.evidenceBytes, maximumEvidenceBytes);
  return payload;
}

export function admitEvidence(
  payload,
  { run, jobs, artifacts, source, plannedIDs, fingerprints },
) {
  validateEvidence(payload);
  successfulRun(run, source, ".github/workflows/extensions.yml");
  assert.equal(run.head_branch, "main");
  assert.equal(run.event, payload.event);
  assert.equal(payload.sourceCommit, source);
  assert.equal(payload.runID, run.id);
  assert.equal(payload.runAttempt, run.run_attempt);
  assert.deepEqual(payload.plannedIDs, plannedIDs);
  assert.deepEqual(payload.fingerprints, fingerprints);
  assert.deepEqual(payload.jobs, jobsIdentity(jobs, plannedIDs, run.id, false));
  for (const row of payload.artifacts) {
    const matches = artifacts.filter(({ id }) => id === row.artifactID);
    assert(matches.length <= 1);
    if (matches.length) {
      const actual = matches[0];
      assert.equal(actual.id, row.artifactID);
      assert.equal(actual.name, row.name);
      assert.equal(actual.size_in_bytes, row.artifactBytes);
      assert.equal(actual.digest, `sha256:${row.artifactSHA256}`);
      assert.equal(actual.workflow_run?.id, run.id);
      assert.equal(actual.workflow_run?.head_sha, source);
      assert.equal(typeof actual.expired, "boolean");
    }
  }
  return payload;
}

export function durableArtifact(payload, name) {
  const matches = payload.artifacts.filter((row) => row.name === name);
  assert.equal(matches.length, 1);
  const { artifactID, artifactBytes, artifactSHA256, assetName } = matches[0];
  return {
    artifactID,
    artifactBytes,
    artifactSHA256,
    durableURL: evidenceURL(payload, assetName),
    archiveQualification: "signed-release-preserved-original-ci-bytes",
  };
}
