import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { realpathSync } from "node:fs";
import { tmpdir } from "node:os";
import test from "node:test";
import { functionalCanonicalJSON } from "./contract.mjs";
import {
  admitFunctionalFixtureHost,
  admitFunctionalLiveIssuer,
  functionalFixtureBootstrapTrustSource,
  functionalFixtureRolePolicySource,
} from "./fixture-trust.mjs";
import { functionalActionOwners } from "./owners.mjs";
import { functionalPairBuildPlan } from "./prepare-owner.mjs";

const sourceCommit = "a".repeat(40);
const session = "12345678-1234-4123-8123-123456789abc";
const runnerTemporaryDirectory = realpathSync(tmpdir());
const root = `${runnerTemporaryDirectory}/functional-fixture-${session}`;
const encoded = Buffer.alloc(32, 1).toString("base64");
const pinPaths = [
  "Extensions/fixtureSupport/WorkerFixtureUITrustAnchor.swift",
  "Extensions/fixtureSupport/WorkerFixtureBootstrapTrustAnchor.swift",
  "Extensions/manifest.json",
  "scripts/build-extension-package.mjs",
  "scripts/hosted-managed-views/verify-package.py",
  "scripts/hosted-functional-actions/prepare-owner.mjs",
  "scripts/hosted-functional-actions/fixture-trust.mjs",
  "scripts/hosted-functional-actions/producer-project.mjs",
  "scripts/hosted-functional-actions/functional-build.mjs",
  ".github/workflows/hosted-functional-actions.yml",
  "Extensions/fixtureSupport/WorkerFixtureRolePolicy.swift",
  "Extensions/fixtureSupport/WorkerFixtureUIAdmission.swift",
  "Extensions/fixtureSupport/WorkerFixtureUIContract.swift",
  "Extensions/fixtureSupport/WorkerFixtureUITrust.swift",
  "Extensions/fixtureSupport/WorkerFixtureAdmission.swift",
  "Extensions/fixtureSupport/WorkerFixtureBootstrapAdmission.swift",
  "Extensions/fixtureSupport/WorkerFixtureBootstrapContract.swift",
  "Extensions/fixtureSupport/WorkerFixtureBootstrapTrust.swift",
  "Extensions/fixtureSupport/WorkerFixtureEngineContract.swift",
  "Tests/HostedFunctionalActions/ProducerSources/FunctionalSignatureProbe.swift",
];
function policyFixture(mutate = () => {}) {
  const digest = (bytes) => createHash("sha256").update(bytes).digest("hex");
  const helpers = new Set([
    "keepAwake",
    "focusDim",
    "windowSweaters",
    "micMute",
    "keystrokeHighlight",
    "presenter",
    "colorPicker",
    "systemStats",
    "emoji",
    "notchShelf",
    "clipboard",
  ]);
  const manifestBytes = Buffer.from(
    JSON.stringify(
      functionalActionOwners.map((owner) => ({
        id: owner,
        roles: { [helpers.has(owner) ? "helper" : "app"]: [] },
      })),
    ),
  );
  const cases = functionalActionOwners.map((owner) => {
    const bytes = Buffer.from(
      `struct ${owner}ActionCase { static let owner = "${owner}" }`,
    );
    return {
      owner,
      path: `Tests/HostedFunctionalActions/OwnerCases/${owner}ActionCase.swift`,
      bytes,
      sha256: digest(bytes),
    };
  });
  const policies = functionalActionOwners.map((owner) => ({
    owner,
    primaryRole: helpers.has(owner) ? "helper" : "app",
    operations:
      owner === "notchShelf"
        ? [
            "notch.settings.read",
            "notch.settings.write",
            "notchShelf.cli.catalog",
          ]
        : [`${owner}.probe`],
    presentations: [
      {
        location: ["notchShelf", "systemStats"].includes(owner)
          ? "settings"
          : "main",
        section: ["notchShelf", "systemStats"].includes(owner)
          ? "extension"
          : owner,
      },
    ],
    inputs: [],
    outputs: [],
    fileScopes: [],
    manifestSHA256: digest(manifestBytes),
    caseSHA256: cases.find((entry) => entry.owner === owner).sha256,
  }));
  mutate(policies);
  const bytes = Buffer.from(functionalCanonicalJSON(policies));
  return {
    policies,
    bytes,
    admitted: {
      sourceCommit,
      policySHA256: digest(bytes),
      manifest: { bytes: manifestBytes, sha256: digest(manifestBytes) },
      cases,
    },
  };
}
const sha = (value) => createHash("sha256").update(value).digest("hex");
const canonicalBytes = (value) => Buffer.from(functionalCanonicalJSON(value));

function liveFixture(mutate) {
  const policies = policyFixture(mutate);
  const paths = [
    ...pinPaths.filter((path) => path !== "Extensions/manifest.json"),
    ".github/workflows/hosted-functional-actions.yml",
    "Extensions/fixtureSupport/WorkerFixtureRolePolicy.swift",
    "Tests/HostedFunctionalActions/ProducerSources/FunctionalIssuer.swift",
    "Tests/HostedFunctionalActions/ProducerSources/FunctionalProducer.swift",
    "Tests/HostedFunctionalActions/ProducerSources/FunctionalSignatureProbe.swift",
    "scripts/hosted-functional-actions/fixture-trust.mjs",
    "scripts/hosted-functional-actions/producer-project.mjs",
    "scripts/hosted-functional-actions/controller.mjs",
    "scripts/hosted-functional-actions/prepare-owner.mjs",
  ];
  const sourceBytes = canonicalBytes({
    sourceCommit,
    files: [
      {
        path: "Extensions/manifest.json",
        sha256: policies.admitted.manifest.sha256,
      },
      ...policies.admitted.cases.map(({ path, sha256 }) => ({ path, sha256 })),
      ...[...new Set(paths)].map((path) => ({
        path,
        sha256: sha(Buffer.from(`synthetic source ${path}`)),
      })),
    ],
  });
  const toolchainBytes = canonicalBytes({
    swiftCompilerSHA256: "1".repeat(64),
    sdkSHA256: "2".repeat(64),
    buildSettingsSHA256: "3".repeat(64),
  });
  const producer = {
    path: `${root}/Producer/functional-producer`,
    executableSHA256: "c".repeat(64),
    certificateSHA256: encoded,
    requirement: 'identifier "functional-producer" and anchor trusted',
  };
  const manifest = {
    schema: 2,
    sourceCommit,
    runID: 10,
    jobID: 11,
    session,
    root,
    hostIdentifier: `com.pulkit.edith.tests.worker-${session}`,
    issuerPublicKey: encoded,
    policySHA256: policies.admitted.policySHA256,
    producer: {
      ...producer,
      sourceSHA256: sha(sourceBytes),
      toolchainSHA256: sha(toolchainBytes),
    },
    signing: {
      hostCertificateSHA256: encoded,
      workerCertificateSHA256: encoded,
      roleCertificateSHA256: encoded,
      hostRequirement: 'identifier "com.pulkit.edith.tests" and anchor trusted',
    },
  };
  const launch = {
    pid: 42,
    birthSeconds: 100,
    birthMicroseconds: 101,
    uid: 501,
    executable: producer.path,
    executableSHA256: producer.executableSHA256,
    certificateSHA256: encoded,
    requirement: producer.requirement,
  };
  const { certificateSHA256, requirement, ...birth } = launch;
  const evidence = {
    sourceCommit,
    ...activeJobFixture().value,
    build: {
      sourceCommit,
      policySHA256: policies.admitted.policySHA256,
      source: { bytes: sourceBytes, sha256: sha(sourceBytes) },
      toolchain: { bytes: toolchainBytes, sha256: sha(toolchainBytes) },
      producer,
    },
    launch,
    bootstrap: {
      schema: 1,
      kind: "bootstrap",
      sourceCommit,
      session,
      issuerPublicKey: encoded,
      producer: birth,
    },
  };
  const observed = {
    sourceCommit,
    run: structuredClone(evidence.run),
    job: structuredClone(evidence.job),
    context: structuredClone(evidence.context),
    producer: structuredClone(launch),
  };
  return { manifest, evidence, policies, observed, observe: () => observed };
}

function liveAdmissionFixture(mutate) {
  const live = liveFixture(mutate);
  const manifestBytes = canonicalBytes(live.manifest);
  const admittedIssuer = admitFunctionalLiveIssuer(
    manifestBytes,
    live.evidence,
    live.observe,
  );
  const bootstrap = functionalFixtureBootstrapTrustSource(
    manifestBytes,
    admittedIssuer,
    live.policies.bytes,
    live.policies.admitted,
  );
  const artifact = {
    schema: 2,
    sourceCommit,
    session,
    root,
    hostIdentifier: live.manifest.hostIdentifier,
    issuerPublicKey: encoded,
    issuerManifestSHA256: sha(manifestBytes),
    host: {
      path: `${root}/Fixture.app`,
      executableSHA256: "b".repeat(64),
      certificateSHA256: encoded,
      requirement: live.manifest.signing.hostRequirement,
    },
    producer: {
      path: live.manifest.producer.path,
      executableSHA256: live.manifest.producer.executableSHA256,
    },
    workerCertificateSHA256: encoded,
    roleCertificateSHA256: encoded,
  };
  const hostEvidence = {
    sourceCommit,
    runID: 10,
    jobID: 11,
    source: live.evidence.build.source,
    toolchain: live.evidence.build.toolchain,
    bootstrapSHA256: bootstrap.sourceSHA256,
    host: artifact.host,
    hostProcess: {
      pid: 43,
      birthSeconds: 102,
      birthMicroseconds: 103,
      uid: live.evidence.launch.uid,
      executable: `${artifact.host.path}/Contents/MacOS/Edith`,
      executableSHA256: artifact.host.executableSHA256,
      certificateSHA256: artifact.host.certificateSHA256,
      requirement: artifact.host.requirement,
    },
  };
  const observedHost = {
    value: {
      sourceCommit,
      runID: 10,
      jobID: 11,
      sourceSHA256: hostEvidence.source.sha256,
      toolchainSHA256: hostEvidence.toolchain.sha256,
      bootstrapSHA256: bootstrap.sourceSHA256,
      host: structuredClone(artifact.host),
      hostProcess: structuredClone(hostEvidence.hostProcess),
    },
  };
  const observeHost = () => observedHost.value;
  const bytes = canonicalBytes(artifact);
  const admitted = admitFunctionalFixtureHost(
    bytes,
    admittedIssuer,
    hostEvidence,
    observeHost,
  );
  return {
    ...live,
    artifact,
    bytes,
    admitted,
    admittedIssuer,
    manifestBytes,
    bootstrap,
    hostEvidence,
    observedHost,
    observeHost,
  };
}

export function functionalBuildTestFixture(mutate) {
  const live = liveAdmissionFixture(mutate);
  const files = JSON.parse(
    live.evidence.build.source.bytes.toString("utf8"),
  ).files;
  return {
    ...live,
    owner: "plugins",
    issuerManifestBytes: live.manifestBytes,
    admittedArtifact: live.admitted,
    artifactBytes: live.bytes,
    policyBytes: live.policies.bytes,
    admittedPolicies: live.policies.admitted,
    sourcePins: { sourceCommit, files },
    environment: {
      ...activeJobFixture().environment,
      RUNNER_TEMP: runnerTemporaryDirectory,
    },
  };
}
function fixture(mutate) {
  return functionalBuildTestFixture(mutate);
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
    { GITHUB_SHA: sourceCommit },
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
      f.sourcePins.files = f.sourcePins.files.filter(
        (entry) => entry.path !== pinPaths.at(-1),
      );
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

test("pair preparation binds all compiled policy bytes to independently frozen manifest and case sources", () => {
  const fixturePlan = fixture();
  assert.equal(
    functionalPairBuildPlan(fixturePlan).policySHA256,
    fixturePlan.admittedPolicies.policySHA256,
  );
  for (const mutate of [
    (f) => {
      delete f.policyBytes;
    },
    (f) => {
      delete f.admittedPolicies;
    },
    (f) => {
      f.admittedPolicies.sourceCommit = "e".repeat(40);
    },
    (f) => {
      f.admittedPolicies.policySHA256 = "e".repeat(64);
    },
    (f) => {
      f.admittedPolicies.manifest.sha256 = "e".repeat(64);
    },
    (f) => {
      f.admittedPolicies.cases[0].bytes = Buffer.from("foreign source");
    },
    (f) => {
      f.sourcePins.files.find(
        (entry) => entry.path === f.admittedPolicies.cases[0].path,
      ).sha256 = "e".repeat(64);
    },
    (f) => {
      f.sourcePins.files.find(
        (entry) => entry.path === "Extensions/manifest.json",
      ).sha256 = "e".repeat(64);
    },
    (f) => {
      f.admittedPolicies.cases[0].owner = "foreign";
    },
  ]) {
    const f = fixture();
    mutate(f);
    assert.throws(() => functionalPairBuildPlan(f));
  }
});

test("pair preparation compiles closed file scopes and rejects missing or widened authority", () => {
  const scope = {
    name: "plugins-state",
    kind: "file",
    purpose: "mutable-state",
    root: "owner-data",
    components: [{ literal: "plugins.json" }],
    maximumBytes: 4096,
    maximumEntries: 1,
    initialState: "present",
    allowedStates: ["present"],
    immutableFiles: [],
    mutableFiles: [],
  };
  const sourceFixture = fixture();
  const sourcePolicies = JSON.parse(sourceFixture.policyBytes.toString("utf8"));
  sourcePolicies.find((entry) => entry.owner === "plugins").fileScopes = [
    scope,
  ];
  const scopedBytes = canonicalBytes(sourcePolicies);
  const compiled = functionalFixtureRolePolicySource(scopedBytes, {
    ...sourceFixture.admittedPolicies,
    policySHA256: sha(scopedBytes),
  });
  assert(compiled.swiftExpression.includes('name: "plugins-state"'));
  assert(
    compiled.swiftExpression.includes('components: [.literal("plugins.json")]'),
  );
  assert(compiled.swiftExpression.includes("maximumBytes: 4096"));
  const scopedFixture = (mutate) => {
    const f = fixture();
    const policies = JSON.parse(f.policyBytes.toString("utf8"));
    const policy = policies.find((entry) => entry.owner === "plugins");
    policy.fileScopes = [structuredClone(scope)];
    mutate(policy);
    f.policyBytes = canonicalBytes(policies);
    f.admittedPolicies.policySHA256 = sha(f.policyBytes);
    return f;
  };
  for (const mutate of [
    (policy) => {
      delete policy.fileScopes;
    },
    (policy) => {
      policy.fileScopes[0].components = [
        { literal: ".." },
        { literal: "plugins.json" },
      ];
    },
    (policy) => {
      policy.fileScopes[0].root = "user-home";
    },
    (policy) => {
      policy.fileScopes[0].maximumBytes = 268435457;
    },
    (policy) => {
      policy.fileScopes[0].allowedStates = [];
    },
    (policy) => {
      policy.fileScopes.push(structuredClone(policy.fileScopes[0]));
    },
  ])
    assert.throws(() => functionalPairBuildPlan(scopedFixture(mutate)));
  const f = fixture();
  const policies = JSON.parse(f.policyBytes.toString("utf8"));
  policies.find((entry) => entry.owner === "plugins").fileScopes = [scope];
  f.policyBytes = canonicalBytes(policies);
  assert.throws(() => functionalPairBuildPlan(f));
});

function syntheticFileScope() {
  return {
    name: "synthetic-state",
    kind: "file",
    purpose: "mutable-state",
    root: "owner-outputs",
    components: [{ phase: true }, { literal: "synthetic-state.bin" }],
    maximumBytes: 4096,
    maximumEntries: 1,
    initialState: "present",
    allowedStates: ["present", "absent"],
    immutableFiles: [],
    mutableFiles: [],
  };
}

function replacePolicyBytes(f, policies) {
  f.policyBytes = Buffer.from(functionalCanonicalJSON(policies));
  f.admittedPolicies.policySHA256 = createHash("sha256")
    .update(f.policyBytes)
    .digest("hex");
}

test("pair preparation carries admitted synthetic file scopes into the generated trust anchor", () => {
  const originalDigest = fixture().admittedPolicies.policySHA256;
  const f = fixture((policies) => {
    policies.find((policy) => policy.owner === "plugins").fileScopes = [
      syntheticFileScope(),
    ];
  });
  const plan = functionalPairBuildPlan(f);
  assert.notEqual(plan.policySHA256, originalDigest);
  assert.equal(plan.policySHA256, f.admittedPolicies.policySHA256);
  assert(
    plan.anchor.source.includes(
      'WorkerFixtureFileScope(name: "synthetic-state", kind: .file, purpose: .mutableState, root: .ownerOutputs',
    ),
  );
  assert(
    plan.anchor.source.includes(
      'components: [.phase, .literal("synthetic-state.bin")]',
    ),
  );
});

test("pair preparation rejects omitted and malformed file scopes even with matching policy digests", () => {
  for (const [name, mutate] of [
    [
      "omitted field",
      (policy) => {
        delete policy.fileScopes;
      },
    ],
    [
      "null scopes",
      (policy) => {
        policy.fileScopes = null;
      },
    ],
    [
      "object scopes",
      (policy) => {
        policy.fileScopes = {};
      },
    ],
    [
      "incomplete scope",
      (policy) => {
        policy.fileScopes = [{ name: "synthetic-state" }];
      },
    ],
    [
      "foreign authority",
      (policy) => {
        policy.fileScopes[0].root = "shared-root";
      },
    ],
    [
      "traversal",
      (policy) => {
        policy.fileScopes[0].components = [{ literal: ".." }];
      },
    ],
    [
      "unbounded bytes",
      (policy) => {
        policy.fileScopes[0].maximumBytes = 268435457;
      },
    ],
    [
      "invalid entries",
      (policy) => {
        policy.fileScopes[0].maximumEntries = 2;
      },
    ],
    [
      "widened states",
      (policy) => {
        policy.fileScopes[0].allowedStates.push("foreign");
      },
    ],
    [
      "duplicate scopes",
      (policy) => {
        policy.fileScopes.push(structuredClone(policy.fileScopes[0]));
      },
    ],
    [
      "extra authority",
      (policy) => {
        policy.fileScopes[0].unrestricted = true;
      },
    ],
  ]) {
    const f = fixture();
    const policies = JSON.parse(f.policyBytes.toString("utf8"));
    const policy = policies.find((entry) => entry.owner !== f.owner);
    policy.fileScopes = [syntheticFileScope()];
    mutate(policy);
    replacePolicyBytes(f, policies);
    assert.throws(
      () => functionalPairBuildPlan(f),
      { code: "ERR_ASSERTION" },
      name,
    );
  }
});

test("pair preparation requires every admitted policy source pin and matching source bytes", () => {
  for (const mutate of [
    (f) => {
      f.admittedPolicies.manifest.bytes = Buffer.from("[]");
    },
    (f) => {
      f.admittedPolicies.cases.pop();
    },
    (f) => {
      f.admittedPolicies.cases[0].path = "Tests/foreign.swift";
    },
    ...[
      "scripts/hosted-functional-actions/fixture-trust.mjs",
      "Extensions/fixtureSupport/WorkerFixtureRolePolicy.swift",
      "Extensions/manifest.json",
    ].map((path) => (f) => {
      f.sourcePins.files = f.sourcePins.files.filter(
        (entry) => entry.path !== path,
      );
    }),
    (f) => {
      f.sourcePins.files = f.sourcePins.files.filter(
        (entry) => entry.path !== f.admittedPolicies.cases.at(-1).path,
      );
    },
  ]) {
    const f = fixture();
    mutate(f);
    assert.throws(() => functionalPairBuildPlan(f), { code: "ERR_ASSERTION" });
  }
});

function activeJobFixture() {
  const sourceCommit = "a".repeat(40);
  const repository = { id: 1289153439, full_name: "pulkitxm/edith" };
  const pull = {
    number: 1014,
    state: "open",
    merged: false,
    merge_commit_sha: "c".repeat(40),
    head: {
      sha: sourceCommit,
      ref: "feat/extension-marketplace",
      repo: { ...repository },
    },
    base: { sha: "b".repeat(40), ref: "main", repo: { ...repository } },
  };
  const value = {
    sourceCommit,
    run: {
      id: 10,
      run_attempt: 1,
      head_sha: sourceCommit,
      head_branch: "feat/extension-marketplace",
      repository: { ...repository },
      head_repository: { ...repository },
      actor: { id: 65671483 },
      triggering_actor: { id: 65671483, login: "pulkitxm" },
      event: "pull_request",
      path: ".github/workflows/hosted-functional-actions.yml",
      workflow_id: 20,
      status: "in_progress",
      conclusion: null,
      pull_requests: [
        {
          number: 1014,
          head: structuredClone(pull.head),
          base: structuredClone(pull.base),
        },
      ],
    },
    job: {
      id: 11,
      run_id: 10,
      run_attempt: 1,
      head_sha: sourceCommit,
      name: "functional-build",
      runner_name: "synthetic-hosted-runner",
      status: "in_progress",
      conclusion: null,
      labels: ["macos-26", "ARM64"],
    },
    context: {
      event: {
        action: "synchronize",
        number: 1014,
        repository: { ...repository },
        pull_request: structuredClone(pull),
      },
      pullRequest: structuredClone(pull),
      mergeCommit: {
        sha: "c".repeat(40),
        parents: [{ sha: "b".repeat(40) }, { sha: sourceCommit }],
      },
      workflow: {
        id: 20,
        path: ".github/workflows/hosted-functional-actions.yml",
        state: "active",
      },
      runAttempt: 1,
    },
  };
  const environment = {
    GITHUB_ACTIONS: "true",
    RUNNER_ENVIRONMENT: "github-hosted",
    RUNNER_OS: "macOS",
    GITHUB_REPOSITORY: "pulkitxm/edith",
    GITHUB_REPOSITORY_ID: "1289153439",
    GITHUB_EVENT_NAME: "pull_request",
    GITHUB_REF: "refs/pull/1014/merge",
    GITHUB_JOB: "functional-build",
    GITHUB_SHA: value.context.mergeCommit.sha,
    EXPECTED_SOURCE_SHA: sourceCommit,
    GITHUB_ACTOR_ID: "65671483",
    GITHUB_TRIGGERING_ACTOR: "pulkitxm",
    GITHUB_RUN_ID: "10",
    GITHUB_RUN_ATTEMPT: "1",
    FUNCTIONAL_JOB_ID: "11",
    RUNNER_NAME: "synthetic-hosted-runner",
    GITHUB_EVENT_PATH: "/private/synthetic/event.json",
    EDITH_HOSTED_FUNCTIONAL_ACTIONS: "1",
    EXTENSION_SWIFT_JOBS: "1",
    EXTENSION_SIGN_IDENTITY: "synthetic reviewed signer",
    DEVELOPER_DIR: "/Applications/Xcode.app/Contents/Developer",
    RUNNER_TEMP: "/private/synthetic",
  };
  return { value, environment };
}
