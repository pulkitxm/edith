import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import test from "node:test";
import { functionalCanonicalJSON } from "./contract.mjs";
import { functionalPairBuildPlan } from "./prepare-owner.mjs";

const sourceCommit = "a".repeat(40);
const session = "12345678-1234-4123-8123-123456789abc";
const root = `/private/synthetic/functional-fixture-${session}`;
const encoded = Buffer.alloc(32, 1).toString("base64");
const pinPaths = [
  "Extensions/fixtureSupport/WorkerFixtureUITrustAnchor.swift",
  "Extensions/manifest.json",
  "scripts/build-extension-package.mjs",
  "scripts/hosted-managed-views/verify-package.py",
  "scripts/hosted-functional-actions/prepare-owner.mjs",
  "Extensions/fixtureSupport/WorkerFixtureUIAdmission.swift",
  "Extensions/fixtureSupport/WorkerFixtureUIContract.swift",
  "Extensions/fixtureSupport/WorkerFixtureUITrust.swift",
  "Tests/HostedFunctionalActions/ProducerSources/FunctionalSignatureProbe.swift",
];
function fixture() {
  const artifactBytes = Buffer.from(
    functionalCanonicalJSON({
      schema: 1,
      sourceCommit,
      session,
      root,
      hostIdentifier: `com.pulkit.edith.tests.worker-${session}`,
      issuerPublicKey: encoded,
      host: {
        path: `${root}/Fixture.app`,
        executableSHA256: "b".repeat(64),
        certificateSHA256: encoded,
        requirement: "anchor trusted",
      },
      producer: {
        path: `${root}/Producer/functional-producer`,
        executableSHA256: "c".repeat(64),
      },
      workerCertificateSHA256: encoded,
      roleCertificateSHA256: encoded,
    }),
  );
  return {
    owner: "plugins",
    artifactBytes,
    admittedArtifact: {
      sourceCommit,
      runID: 1,
      jobID: 2,
      artifactID: 3,
      artifactSHA256: createHash("sha256").update(artifactBytes).digest("hex"),
    },
    sourcePins: {
      sourceCommit,
      files: pinPaths.map((path) => ({ path, sha256: "d".repeat(64) })),
    },
    environment: {
      GITHUB_ACTIONS: "true",
      RUNNER_ENVIRONMENT: "github-hosted",
      RUNNER_OS: "macOS",
      GITHUB_REPOSITORY: "pulkitxm/edith",
      GITHUB_EVENT_NAME: "workflow_dispatch",
      EDITH_HOSTED_FUNCTIONAL_ACTIONS: "1",
      GITHUB_SHA: sourceCommit,
      EXPECTED_SOURCE_SHA: sourceCommit,
      GITHUB_ACTOR_ID: "65671483",
      GITHUB_REF: "refs/heads/feat/extension-marketplace",
      EXTENSION_SWIFT_JOBS: "1",
      EXTENSION_SIGN_IDENTITY: "Synthetic fixture signer",
      RUNNER_TEMP: "/private/synthetic",
      DEVELOPER_DIR: "/Applications/Xcode.app/Contents/Developer",
    },
  };
}

test("pair preparation plans independent source builds with version selected before compilation and signing", () => {
  const plan = functionalPairBuildPlan(fixture());
  assert.equal(plan.pairScope, "synthetic-development");
  assert.deepEqual(
    plan.steps.map((step) => step.environment.EXTENSION_VERSION),
    ["1.0.0", "1.1.0"],
  );
  assert.notEqual(plan.steps[0].sourceRoot, plan.steps[1].sourceRoot);
  assert.notEqual(plan.steps[0].output, plan.steps[1].output);
  assert.equal(plan.host.path, `${root}/Fixture.app`);
  assert(Object.isFrozen(plan.steps[0].environment));
  assert(Object.isFrozen(plan.sourcePins[0]));
  assert(!Object.hasOwn(plan, "functionalActionsValidated"));
  assert(!Object.hasOwn(plan, "publicUpdateValidated"));
});

test("pair preparation rejects local execution, source drift, ad hoc signing and missing independent inputs", () => {
  for (const patch of [
    { GITHUB_ACTIONS: "false" },
    { RUNNER_ENVIRONMENT: "self-hosted" },
    { GITHUB_EVENT_NAME: "push" },
    { GITHUB_SHA: "b".repeat(40) },
    { EXPECTED_SOURCE_SHA: "b".repeat(40) },
    { GITHUB_ACTOR_ID: "foreign" },
    { GITHUB_REF: "refs/heads/unreviewed" },
    { EXTENSION_SIGN_IDENTITY: "-" },
    { EXTENSION_SWIFT_JOBS: "4" },
    { DEVELOPER_DIR: "/tmp/Xcode" },
    { RUNNER_TEMP: "/private/foreign" },
    { EDITH_HOSTED_FUNCTIONAL_ACTIONS: "0" },
  ]) {
    const f = fixture();
    Object.assign(f.environment, patch);
    assert.throws(() => functionalPairBuildPlan(f));
  }
  for (const mutate of [
    (f) => {
      f.owner = "foreign";
    },
    (f) => {
      f.sourcePins.sourceCommit = "e".repeat(40);
    },
    (f) => {
      f.sourcePins.files.pop();
    },
    (f) => {
      f.sourcePins.files.push(f.sourcePins.files[0]);
    },
    (f) => {
      f.sourcePins.files[0].path = "../outside";
    },
    (f) => {
      f.sourcePins.files[0].sha256 = "foreign";
    },
    (f) => {
      f.sourcePins.admitted = true;
    },
  ]) {
    const f = fixture();
    mutate(f);
    assert.throws(() => functionalPairBuildPlan(f));
  }
});
