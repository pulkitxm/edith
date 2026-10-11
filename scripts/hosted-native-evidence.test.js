import { expect, test } from "bun:test";
import { generateKeyPairSync, sign } from "node:crypto";
import {
  managedNativeBuildSteps,
  managedNativeTestSteps,
} from "./hosted-managed-views/native-ci-contract.mjs";
import { digest } from "./hosted-public-release/contract.mjs";
import {
  admitEvidence,
  durableArtifact,
  nativeLineage,
  stagedEvidence,
  verifiedEvidence,
  verifiedLineage,
} from "./hosted-public-release/evidence.mjs";

const source = "a".repeat(40);
const key = generateKeyPairSync("ed25519");
const publicKey = Buffer.from(
  key.publicKey.export({ format: "jwk" }).x,
  "base64url",
).toString("base64");
function envelope(payload) {
  const bytes = Buffer.from(
    typeof payload === "string" ? payload : JSON.stringify(payload),
  );
  return Buffer.from(
    JSON.stringify({
      payload: bytes.toString("base64"),
      signature: sign(null, bytes, key.privateKey).toString("base64"),
    }),
  );
}
function fixture() {
  const fingerprints = Object.fromEntries(
    Array.from({ length: 39 }, (_, index) => [`owner${index}`, "b".repeat(64)]),
  );
  const plannedIDs = ["owner0"];
  const run = {
    id: 101,
    run_attempt: 1,
    repository: { full_name: "pulkitxm/edith" },
    path: ".github/workflows/extensions.yml",
    head_sha: source,
    head_branch: "main",
    event: "push",
    status: "in_progress",
    conclusion: null,
  };
  const jobs = [
    "plan",
    "frozen-host",
    "tests",
    "build (owner0)",
    "publish",
  ].map((name, index) => ({
    id: 201 + index,
    run_id: run.id,
    name,
    status: name === "publish" ? "in_progress" : "completed",
    conclusion: name === "publish" ? null : "success",
    steps: (name === "tests"
      ? managedNativeTestSteps
      : name.startsWith("build (")
        ? managedNativeBuildSteps
        : name === "publish"
          ? ["Publish immutable extension releases and the signed catalog"]
          : []
    ).map((name_, number) => ({
      name: name_,
      number: number + 1,
      status: name === "publish" ? "in_progress" : "completed",
      conclusion: name === "publish" ? null : "success",
    })),
  }));
  const artifacts = [
    "extension-plan",
    "frozen-extension-host",
    "extension-owner0",
  ].map((name, index) => ({
    name,
    id: 301 + index,
    size_in_bytes: 37,
    digest: `sha256:${"c".repeat(64)}`,
    expired: false,
    workflow_run: { id: run.id, head_sha: source },
  }));
  const environment = {
    GITHUB_ACTIONS: "true",
    RUNNER_ENVIRONMENT: "github-hosted",
    RUNNER_OS: "macOS",
    GITHUB_REF: "refs/heads/main",
    GITHUB_REPOSITORY: "pulkitxm/edith",
    GITHUB_SHA: source,
    GITHUB_RUN_ID: "101",
    GITHUB_RUN_ATTEMPT: "1",
    GITHUB_JOB: "publish",
  };
  return {
    run,
    jobs,
    artifacts,
    source,
    plannedIDs,
    fingerprints,
    environment,
  };
}
function completed(value) {
  return {
    ...value,
    run: { ...value.run, status: "completed", conclusion: "success" },
    jobs: value.jobs.map((job) => ({
      ...job,
      status: "completed",
      conclusion: "success",
      steps: job.steps.map((step) => ({
        ...step,
        status: "completed",
        conclusion: "success",
      })),
    })),
  };
}

test("durable signed evidence preserves exact original archives after CI expiry", () => {
  const value = fixture();
  const payload = stagedEvidence(value);
  const signed = envelope(payload);
  expect(verifiedEvidence(signed, publicKey)).toEqual(payload);
  const success = completed(value);
  for (const artifacts of [
    success.artifacts.map((row) => ({ ...row, expired: true })),
    [],
  ]) {
    expect(admitEvidence(payload, { ...success, artifacts })).toEqual(payload);
    expect(durableArtifact(payload, "extension-owner0").artifactID).toBe(303);
  }
});

test("staging requires real source and attempt identity with all actual native predecessors successful", () => {
  for (const mutation of [
    (value) => {
      value.environment.GITHUB_RUN_ID = "102";
    },
    (value) => {
      value.environment.GITHUB_RUN_ATTEMPT = "2";
    },
    (value) => {
      value.run.head_sha = "d".repeat(40);
    },
    (value) => {
      value.jobs[3].steps[0].conclusion = "failure";
    },
    (value) => {
      value.jobs[2].status = "queued";
    },
    (value) => {
      value.jobs[4].conclusion = "success";
    },
    (value) => {
      value.artifacts.pop();
    },
    (value) => {
      value.artifacts[0].expired = true;
    },
    (value) => {
      value.artifacts.push({ ...value.artifacts[0], name: "private-log" });
    },
  ]) {
    const value = fixture();
    mutation(value);
    expect(() => stagedEvidence(value)).toThrow();
  }
});

test("expired artifacts never excuse corrupt signatures, changed run jobs or original hashes", () => {
  const value = fixture();
  const payload = stagedEvidence(value);
  const signed = envelope(payload);
  const corrupted = JSON.parse(signed);
  corrupted.signature = Buffer.alloc(64).toString("base64");
  expect(() =>
    verifiedEvidence(Buffer.from(JSON.stringify(corrupted)), publicKey),
  ).toThrow();
  expect(() =>
    verifiedEvidence(
      envelope(
        JSON.stringify(payload).replace(
          '"schema":1',
          '"schema":1,"\\u0073chema":1',
        ),
      ),
      publicKey,
    ),
  ).toThrow();
  for (const mutate of [
    (success) => {
      success.run.conclusion = "failure";
    },
    (success) => {
      success.run.id = 102;
    },
    (success) => {
      success.run.run_attempt = 2;
    },
    (success) => {
      success.jobs[3].id++;
    },
    (success) => {
      success.jobs[3].steps[0].number++;
    },
    (success) => {
      success.artifacts[2].digest = `sha256:${"f".repeat(64)}`;
    },
    (success) => {
      success.artifacts[2].workflow_run.head_sha = "f".repeat(40);
    },
    (success) => {
      success.fingerprints.owner0 = "f".repeat(64);
    },
  ]) {
    const success = completed(fixture());
    mutate(success);
    expect(() => admitEvidence(payload, success)).toThrow();
  }
  expect(() =>
    admitEvidence(payload, { ...completed(fixture()), run: null }),
  ).toThrow();
});

test("immutable retry lineage stays bound to old published bytes and original native run", () => {
  const payload = stagedEvidence(fixture());
  const bytes = envelope(payload);
  const record = {
    id: "owner0",
    sourceFingerprint: "b".repeat(64),
    sha256: "e".repeat(64),
    version: "1.0.0",
  };
  const link = nativeLineage(record, payload, {
    bytes: bytes.length,
    sha256: digest(bytes),
  });
  const signed = envelope(link);
  expect(verifiedLineage(signed, publicKey, record).runID).toBe(101);
  expect(() =>
    verifiedLineage(signed, publicKey, { ...record, sha256: "f".repeat(64) }),
  ).toThrow();
  expect(() =>
    verifiedLineage(
      envelope({ ...link, sourceCommit: "f".repeat(40) }),
      publicKey,
      record,
    ),
  ).toThrow();
  expect(() =>
    nativeLineage({ ...record, sourceFingerprint: "f".repeat(64) }, payload, {
      bytes: bytes.length,
      sha256: digest(bytes),
    }),
  ).toThrow();
});
