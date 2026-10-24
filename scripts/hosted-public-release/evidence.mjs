import assert from "node:assert/strict";
import { createPublicKey, verify } from "node:crypto";
import {
  managedNativeBuildSteps,
  shippingNativeTestSteps,
} from "../hosted-managed-views/native-ci-contract.mjs";
import {
  artifact,
  closedJSON,
  ownedDraftResume,
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
export const preservationStep =
  "Preserve immutable native evidence before publication";
export const publicationStep =
  "Publish immutable extension releases and the signed catalog";
export function publisherStepNames(workflow) {
  const steps = workflow.jobs.publish.steps;
  return [
    "Set up job",
    "Complete job",
    ...steps.map(
      (step) =>
        step.name ??
        (step.uses ? `Run ${step.uses}` : `Run ${step.run.split("\n")[0]}`),
    ),
    ...steps
      .filter((step) => step.uses)
      .map((step) => `Post ${step.name ?? `Run ${step.uses}`}`),
  ];
}
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
    ? shippingNativeTestSteps
    : name.startsWith("build (")
      ? managedNativeBuildSteps
      : name === "publish"
        ? [preservationStep]
        : [];
}

function jobsIdentity(
  jobs,
  plannedIDs,
  runID,
  staging,
  publisherPhase = "preservation",
) {
  const expected = [
    "plan",
    "frozen-host",
    "tests",
    "publish",
    ...(plannedIDs.length
      ? plannedIDs.map((id) => `build (${id})`)
      : ["build"]),
  ];
  assert.equal(jobs.length, expected.length);
  assert.equal(new Set(jobs.map(({ id }) => id)).size, expected.length);
  assert.deepEqual(jobs.map(({ name }) => name).sort(), expected.sort());
  return jobs
    .map((job) => {
      integer(job.id);
      assert.equal(job.run_id, runID);
      if (!plannedIDs.length && job.name === "build")
        assert.deepEqual(job.steps, []);
      const active = staging && job.name === "publish";
      assert.equal(job.status, active ? "in_progress" : "completed");
      assert.equal(
        job.conclusion,
        active
          ? null
          : !plannedIDs.length && job.name === "build"
            ? "skipped"
            : "success",
      );
      const steps = requiredSteps(job.name).map((name) => {
        const found = job.steps.filter((step) => step.name === name);
        assert.equal(found.length, 1);
        const step = found[0];
        integer(step.number);
        const preserving = active && publisherPhase === "preservation";
        if (preserving)
          assert(["pending", "in_progress"].includes(step.status));
        else assert.equal(step.status, "completed");
        assert.equal(step.conclusion, preserving ? null : "success");
        return { name, number: step.number };
      });
      if (active && publisherPhase === "publication") {
        const publication = job.steps.filter(
          ({ name }) => name === publicationStep,
        );
        assert.equal(publication.length, 1);
        assert(["pending", "in_progress"].includes(publication[0].status));
        assert.equal(publication[0].conclusion, null);
      }
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
  assert(Array.isArray(payload.plannedIDs) && payload.plannedIDs.length <= 40);
  assert.equal(new Set(payload.plannedIDs).size, payload.plannedIDs.length);
  assert.equal(Object.keys(payload.fingerprints).length, 40);
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
      conclusion:
        !payload.plannedIDs.length && job.name === "build"
          ? "skipped"
          : "success",
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
  resume,
  publisherPhase = "preservation",
}) {
  assert(["preservation", "publication"].includes(publisherPhase));
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
  if (!plannedIDs.length) {
    ownedDraftResume(resume);
    assert.deepEqual(resume.fingerprints, fingerprints);
  }
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
    jobs: jobsIdentity(jobs, plannedIDs, run.id, true, publisherPhase),
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

export function closedAssetInventory(payload, envelope, actual, composition) {
  validateEvidence(payload);
  integer(envelope.bytes, maximumEvidenceBytes);
  assert.match(envelope.sha256, hash);
  const assets = [
    ...payload.artifacts.map(
      ({ assetName, artifactBytes, artifactSHA256 }) => ({
        name: assetName,
        bytes: artifactBytes,
        sha256: artifactSHA256,
      }),
    ),
    {
      name: "native-evidence.json",
      bytes: envelope.bytes,
      sha256: envelope.sha256,
    },
  ];
  if (composition) {
    integer(composition.bytes, maximumEvidenceBytes);
    assert.match(composition.sha256, hash);
    assets.push({ name: "publication-composition.json", ...composition });
  }
  if (actual) {
    assert.deepEqual(
      actual.map(({ name }) => name).sort(),
      assets.map(({ name }) => name).sort(),
    );
    for (const expected of assets) {
      const matches = actual.filter(({ name }) => name === expected.name);
      assert.equal(matches.length, 1);
      assert.equal(matches[0].size, expected.bytes);
      assert.equal(matches[0].digest, `sha256:${expected.sha256}`);
    }
  }
  const originalArchiveBytes = payload.artifacts.reduce(
    (sum, row) => sum + row.artifactBytes,
    0,
  );
  return {
    assets,
    envelopeBytes: envelope.bytes,
    envelopeSHA256: envelope.sha256,
    originalArchiveBytes,
    compositionBytes: composition?.bytes ?? 0,
    totalEvidenceBytes:
      originalArchiveBytes + envelope.bytes + (composition?.bytes ?? 0),
  };
}

export function publicationComposition(
  source,
  runID,
  attempt,
  packages,
  fingerprints,
) {
  evidenceTag(source, runID, attempt);
  assert(packages.length > 0 && packages.length <= 40);
  assert.equal(packages.length, Object.keys(fingerprints).length);
  assert.equal(
    new Set(packages.map(({ package: record }) => record.id)).size,
    packages.length,
  );
  assert.deepEqual(
    packages.map(({ package: record }) => record.id).sort(),
    Object.keys(fingerprints).sort(),
  );
  for (const row of packages) {
    keys(row, [
      "package",
      "lineageSHA256",
      "lineageBytes",
      "sourceCommit",
      "runID",
      "runAttempt",
      "evidenceSHA256",
      "evidenceBytes",
    ]);
    assert.equal(row.package.sourceFingerprint, fingerprints[row.package.id]);
    assert.match(row.lineageSHA256, hash);
    integer(row.lineageBytes, 16 * 1024);
    evidenceTag(row.sourceCommit, row.runID, row.runAttempt);
    assert.match(row.evidenceSHA256, hash);
    integer(row.evidenceBytes, maximumEvidenceBytes);
  }
  return {
    schema: 1,
    kind: "extension-publication-composition",
    repository,
    sourceCommit: source,
    publicationRunID: runID,
    publicationAttempt: attempt,
    packages,
  };
}

export function verifiedComposition(
  bytes,
  publicKey,
  { source, runID, attempt, records, fingerprints },
) {
  const payload = verifiedEnvelope(bytes, publicKey);
  keys(payload, [
    "schema",
    "kind",
    "repository",
    "sourceCommit",
    "publicationRunID",
    "publicationAttempt",
    "packages",
  ]);
  assert.deepEqual(
    payload,
    publicationComposition(
      source,
      runID,
      attempt,
      payload.packages,
      fingerprints,
    ),
  );
  assert.equal(records.length, payload.packages.length);
  for (const row of payload.packages) {
    const matches = records.filter(({ id }) => id === row.package.id);
    assert.equal(matches.length, 1);
    assert.deepEqual(row.package, matches[0]);
  }
  return payload;
}

export function admitOriginalEvidence(payload, value, publisherNames) {
  assert(
    payload.plannedIDs.length > 0,
    "Empty resume evidence cannot qualify a package origin",
  );
  if (value.run?.conclusion === "success")
    return {
      payload: admitEvidence(payload, value),
      originalWholeRunSucceeded: true,
      originalPublicationOnlyFailure: false,
    };
  const { run, jobs, artifacts, source, plannedIDs, fingerprints } = value;
  assert(run);
  assert.equal(run.repository?.full_name, repository);
  assert.equal(run.path, ".github/workflows/extensions.yml");
  assert.equal(run.head_sha, source);
  assert.equal(run.head_branch, "main");
  assert.equal(run.event, payload.event);
  assert.equal(run.id, payload.runID);
  assert.equal(run.run_attempt, payload.runAttempt);
  assert.equal(run.status, "completed");
  assert.equal(run.conclusion, "failure");
  validateEvidence(payload);
  assert.equal(payload.sourceCommit, source);
  assert.deepEqual(payload.plannedIDs, plannedIDs);
  assert.deepEqual(payload.fingerprints, fingerprints);
  const publisher = jobs.filter(({ name }) => name === "publish");
  assert.equal(publisher.length, 1);
  assert.equal(publisher[0].run_id, run.id);
  assert.equal(publisher[0].status, "completed");
  assert.equal(publisher[0].conclusion, "failure");
  const publication = publisher[0].steps.filter(
    ({ name }) => name === publicationStep,
  );
  assert.equal(publication.length, 1);
  assert.equal(publication[0].status, "completed");
  assert.equal(publication[0].conclusion, "failure");
  assert(
    Array.isArray(publisherNames) &&
      publisherNames.includes(preservationStep) &&
      publisherNames.includes(publicationStep),
  );
  assert.equal(
    new Set(publisher[0].steps.map(({ name }) => name)).size,
    publisher[0].steps.length,
  );
  for (const step of publisher[0].steps) {
    assert(
      publisherNames.includes(step.name),
      `Unknown publisher step ${step.name}`,
    );
    assert.equal(step.status, "completed");
    if (step.name === publicationStep) assert.equal(step.conclusion, "failure");
    else if (step.name === preservationStep)
      assert.equal(step.conclusion, "success");
    else assert(["success", "skipped"].includes(step.conclusion));
  }
  for (const name of publisherNames.filter(
    (name) =>
      name !== "Set up job" &&
      name !== "Complete job" &&
      !name.startsWith("Post "),
  ))
    assert(publisher[0].steps.some((step) => step.name === name));
  const native = jobs.filter(({ name }) => name !== "publish");
  const required = [
    "plan",
    "frozen-host",
    "tests",
    ...plannedIDs.map((id) => `build (${id})`),
  ];
  assert.equal(native.length, required.length);
  assert.deepEqual(native.map(({ name }) => name).sort(), required.sort());
  const identities = native.map((job) => {
    integer(job.id);
    assert.equal(job.run_id, run.id);
    assert.equal(job.status, "completed");
    assert.equal(job.conclusion, "success");
    const steps = requiredSteps(job.name).map((name) => {
      const matches = job.steps.filter((step) => step.name === name);
      assert.equal(matches.length, 1);
      assert.equal(matches[0].status, "completed");
      assert.equal(matches[0].conclusion, "success");
      return { name, number: matches[0].number };
    });
    return { id: job.id, name: job.name, steps };
  });
  const preserve = publisher[0].steps.find(
    ({ name }) => name === preservationStep,
  );
  assert(
    preserve &&
      preserve.status === "completed" &&
      preserve.conclusion === "success",
  );
  identities.push({
    id: publisher[0].id,
    name: "publish",
    steps: [{ name: preservationStep, number: preserve.number }],
  });
  assert.deepEqual(
    identities.sort((left, right) => left.name.localeCompare(right.name)),
    payload.jobs,
  );
  for (const row of payload.artifacts) {
    const actual = artifacts.filter(({ id }) => id === row.artifactID);
    assert(actual.length <= 1);
    if (actual.length) {
      assert.equal(actual[0].name, row.name);
      assert.equal(actual[0].size_in_bytes, row.artifactBytes);
      assert.equal(actual[0].digest, `sha256:${row.artifactSHA256}`);
      assert.equal(actual[0].workflow_run?.id, run.id);
      assert.equal(actual[0].workflow_run?.head_sha, source);
    }
  }
  return {
    payload,
    originalWholeRunSucceeded: false,
    originalPublicationOnlyFailure: true,
  };
}

export function admitEvidence(
  payload,
  { run, jobs, artifacts, source, plannedIDs, fingerprints, resume },
) {
  if (!plannedIDs.length) {
    ownedDraftResume(resume);
    assert.deepEqual(resume.fingerprints, fingerprints);
  }
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
  const published = jobs
    .find(({ name }) => name === "publish")
    .steps.filter(({ name }) => name === publicationStep);
  assert.equal(published.length, 1);
  assert.equal(published[0].status, "completed");
  assert.equal(published[0].conclusion, "success");
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
