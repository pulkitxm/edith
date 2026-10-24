import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import test from "node:test";
import { functionalCanonicalJSON } from "./contract.mjs";
import {
  admitFunctionalFixtureHost,
  admitFunctionalLiveIssuer,
  functionalFixtureBootstrapTrustSource,
  functionalFixtureRolePolicySource,
  functionalFixtureTrustSource,
} from "./fixture-trust.mjs";
import { functionalActionOwners } from "./owners.mjs";

const sourceCommit = "a".repeat(40);
const session = "12345678-1234-4123-8123-123456789abc";
const root = `/private/synthetic/functional-fixture-${session}`;
const encoded = Buffer.alloc(32, 1).toString("base64");
function policyFixture() {
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
function generate(f) {
  const policies = policyFixture();
  return functionalFixtureTrustSource(
    f.bytes,
    f.admitted,
    policies.bytes,
    policies.admitted,
  );
}

const sha = (value) => createHash("sha256").update(value).digest("hex");
const canonicalBytes = (value) => Buffer.from(functionalCanonicalJSON(value));

function liveFixture() {
  const policies = policyFixture();
  const paths = [
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
      ...paths.map((path) => ({
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
    run: {
      id: 10,
      head_sha: sourceCommit,
      repository: { id: 1289153439, full_name: "pulkitxm/edith" },
      head_repository: { id: 1289153439, full_name: "pulkitxm/edith" },
      triggering_actor: { id: 65671483 },
      run_attempt: 1,
      pull_requests: [
        {
          number: 1014,
          head: { sha: sourceCommit, repo: { id: 1289153439 } },
          base: { sha: "b".repeat(40), repo: { id: 1289153439 } },
        },
      ],
      workflow_id: 20,
      actor: { id: 65671483 },
      event: "pull_request",
      path: ".github/workflows/hosted-functional-actions.yml",
      status: "in_progress",
      conclusion: null,
    },
    job: {
      id: 11,
      run_id: 10,
      run_attempt: 1,
      runner_name: "GitHub Actions synthetic",
      head_sha: sourceCommit,
      name: "functional-build",
      status: "in_progress",
      conclusion: null,
      labels: ["macos-26", "ARM64"],
    },
    context: {
      event: {
        action: "synchronize",
        number: 1014,
        repository: { id: 1289153439, full_name: "pulkitxm/edith" },
        pull_request: {
          number: 1014,
          head: {
            sha: sourceCommit,
            ref: "feat/extension-marketplace",
            repo: { id: 1289153439, full_name: "pulkitxm/edith" },
          },
          base: {
            sha: "b".repeat(40),
            ref: "main",
            repo: { id: 1289153439, full_name: "pulkitxm/edith" },
          },
        },
      },
      pullRequest: {
        number: 1014,
        state: "open",
        merged: false,
        merge_commit_sha: "c".repeat(40),
        head: {
          sha: sourceCommit,
          ref: "feat/extension-marketplace",
          repo: { id: 1289153439, full_name: "pulkitxm/edith" },
        },
        base: {
          sha: "b".repeat(40),
          ref: "main",
          repo: { id: 1289153439, full_name: "pulkitxm/edith" },
        },
      },
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
    producer: structuredClone(launch),
    context: structuredClone(evidence.context),
  };
  return { manifest, evidence, policies, observed, observe: () => observed };
}

function fixture() {
  const live = liveFixture();
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
      ...live.evidence.launch,
      pid: 43,
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

test("fixture anchor is generated only from independently hash-admitted source-built artifact bytes", () => {
  const f = fixture();
  const result = generate(f);
  assert.equal(
    result.generatedPath,
    "Extensions/fixtureSupport/WorkerFixtureUITrustAnchor.swift",
  );
  assert(result.source.includes("try! WorkerFixtureUITrust("));
  assert(
    result.source.includes(`issuerKey: Data(base64Encoded: "${encoded}")!`),
  );
  assert(
    result.source.includes(
      'identifier \\"com.pulkit.edith.tests\\" and anchor trusted',
    ),
  );
  assert(!result.source.includes("ProcessInfo"));
  assert.equal(
    (result.source.match(/try WorkerFixtureRolePolicy\(/g) ?? []).length,
    40,
  );
  assert(result.source.includes('section: "extension"'));
});

test("descriptor selected keys, source changes, duplicate fields and foreign paths cannot create fixture trust", () => {
  for (const mutate of [
    (f) => {
      f.admitted = { ...f.admitted, artifactSHA256: "d".repeat(64) };
    },
    (f) => {
      f.admitted = { ...f.admitted, sourceCommit: "e".repeat(40) };
    },
    (f) => {
      f.admitted = { ...f.admitted, runID: 0 };
    },
    (f) => {
      f.admitted = { ...f.admitted, trusted: true };
    },
    (f) => {
      f.admitted = { ...f.admitted, artifactID: 12 };
    },
  ]) {
    const f = fixture();
    mutate(f);
    assert.throws(() => generate(f));
  }
  for (const mutate of [
    (a) => {
      a.issuerPublicKey = "foreign";
    },
    (a) => {
      a.root = `${root}/..`;
    },
    (a) => {
      a.host.path = "/Applications/Edith.app";
    },
    (a) => {
      a.producer.path = "/usr/bin/true";
    },
    (a) => {
      a.roleCertificateSHA256 = "";
    },
    (a) => {
      a.host.requirement = "trusted\ninvalid";
    },
    (a) => {
      a.descriptor = { issuerKey: encoded };
    },
  ]) {
    const f = fixture();
    mutate(f.artifact);
    f.bytes = Buffer.from(functionalCanonicalJSON(f.artifact));
    f.admitted = { ...f.admitted, artifactSHA256: sha(f.bytes) };
    assert.throws(() => generate(f));
  }
  const f = fixture();
  f.bytes = Buffer.from(`{"schema":2,${f.bytes.toString().slice(1)}`);
  assert.throws(() =>
    admitFunctionalFixtureHost(
      f.bytes,
      f.admittedIssuer,
      f.hostEvidence,
      f.observeHost,
    ),
  );
  assert.throws(() => generate(f));
});

test("policy source requires exact independently pinned original manifest and all39 native cases", () => {
  const f = policyFixture();
  assert.equal(
    functionalFixtureRolePolicySource(f.bytes, f.admitted).sourceCommit,
    sourceCommit,
  );
  for (const mutate of [
    (f) => {
      f.admitted.policySHA256 = "d".repeat(64);
    },
    (f) => {
      f.admitted.manifest.sha256 = "d".repeat(64);
    },
    (f) => {
      f.admitted.cases[0].bytes = Buffer.from("foreign");
    },
    (f) => {
      f.admitted.cases[0].path = "Extensions/keepAwake/Runtime.swift";
    },
    (f) => {
      f.admitted.cases.pop();
    },
    (f) => {
      f.admitted.sourceCommit = "foreign";
    },
    (f) => {
      f.admitted.descriptor = {};
    },
  ]) {
    const value = policyFixture();
    mutate(value);
    assert.throws(() =>
      functionalFixtureRolePolicySource(value.bytes, value.admitted),
    );
  }
});

test("admitted policy hash cannot relax original roles or closed scopes and bounds", () => {
  for (const mutate of [
    (p) => {
      p[0].primaryRole = "app";
    },
    (p) => {
      p[0].operations.push(p[0].operations[0]);
    },
    (p) => {
      p[0].operations = ["../foreign"];
    },
    (p) => {
      p[0].presentations[0].section = "clipboard";
    },
    (p) => {
      p[0].presentations[0].location = "panel";
    },
    (p) => {
      p[0].presentations.push(p[0].presentations[0]);
    },
    (p) => {
      p[0].inputs = [{ name: "agents", maximumBytes: 268435457 }];
    },
    (p) => {
      p[0].inputs = [{ name: "agents", maximumBytes: 1 }];
      p[0].outputs = ["agents"];
    },
    (p) => {
      p[0].caseSHA256 = "e".repeat(64);
    },
    (p) => {
      p[0].manifestSHA256 = "e".repeat(64);
    },
    (p) => {
      p[0].uiOnly = false;
    },
    (p) => {
      p.pop();
    },
  ]) {
    const f = policyFixture();
    mutate(f.policies);
    f.bytes = Buffer.from(functionalCanonicalJSON(f.policies));
    f.admitted.policySHA256 = createHash("sha256")
      .update(f.bytes)
      .digest("hex");
    assert.throws(() => functionalFixtureRolePolicySource(f.bytes, f.admitted));
  }
  const f = fixture();
  const p = policyFixture();
  p.admitted.sourceCommit = "e".repeat(40);
  assert.throws(() =>
    functionalFixtureTrustSource(f.bytes, f.admitted, p.bytes, p.admitted),
  );
});

function fileScopeFixture() {
  return {
    name: "victim",
    kind: "file",
    purpose: "mutable-state",
    root: "owner-outputs",
    components: [{ phase: true }, { literal: "victim.bin" }],
    maximumBytes: 4096,
    maximumEntries: 1,
    initialState: "present",
    allowedStates: ["present", "absent"],
    immutableFiles: [],
    mutableFiles: [],
  };
}

function compileFileScopes(scopes) {
  const value = policyFixture();
  value.policies[0].fileScopes = scopes;
  value.bytes = Buffer.from(functionalCanonicalJSON(value.policies));
  value.admitted.policySHA256 = createHash("sha256")
    .update(value.bytes)
    .digest("hex");
  return functionalFixtureRolePolicySource(value.bytes, value.admitted);
}

test("required file scopes compile exact purpose states bounds and finite source transforms", () => {
  const scope = fileScopeFixture();
  scope.components = [
    { phase: true },
    { sessionUUID: "uppercase" },
    { literal: "victim.bin" },
  ];
  const source = compileFileScopes([scope]).swiftExpression;
  assert(source.includes("purpose: .mutableState"));
  assert(source.includes("root: .ownerOutputs"));
  assert(
    source.includes(
      'components: [.phase, .sessionUUID(.uppercase), .literal("victim.bin")]',
    ),
  );
  assert(
    source.includes(
      "maximumBytes: 4096, maximumEntries: 1, initialState: .present",
    ),
  );
  assert(source.includes("allowedStates: [.present, .absent]"));
  const directory = {
    ...fileScopeFixture(),
    name: "scan",
    kind: "directory",
    components: [{ phase: true }, { literal: "scan" }],
    allowedStates: ["present"],
    mutableFiles: [
      {
        components: ["victim.bin"],
        maximumBytes: 4096,
        initialState: "present",
        allowedStates: ["present", "absent"],
      },
    ],
  };
  assert(
    compileFileScopes([directory]).swiftExpression.includes(
      "WorkerFixtureMutableFileScope",
    ),
  );
  const empty = {
    ...directory,
    purpose: "immutable-input",
    root: "owner-home",
    maximumBytes: 0,
    maximumEntries: 0,
    mutableFiles: [],
  };
  assert(
    compileFileScopes([empty]).swiftExpression.includes(
      "maximumBytes: 0, maximumEntries: 0",
    ),
  );
  const missing = policyFixture();
  delete missing.policies[0].fileScopes;
  missing.bytes = Buffer.from(functionalCanonicalJSON(missing.policies));
  missing.admitted.policySHA256 = createHash("sha256")
    .update(missing.bytes)
    .digest("hex");
  assert.throws(() =>
    functionalFixtureRolePolicySource(missing.bytes, missing.admitted),
  );
});

test("file scope compilation rejects unknown authority traversal state widening and directory aliases", () => {
  for (const mutate of [
    (v) => {
      v.root = "shared-root";
    },
    (v) => {
      v.purpose = "arbitrary-write";
    },
    (v) => {
      v.kind = "symlink";
    },
    (v) => {
      v.components = [{ literal: "../foreign" }];
    },
    (v) => {
      v.components = [{ literal: ".." }];
    },
    (v) => {
      v.components = [{ literal: "a\\b" }];
    },
    (v) => {
      v.components = [{ literal: "é" }];
    },
    (v) => {
      v.components = [{ phase: "updated" }];
    },
    (v) => {
      v.components = [{ phase: true }, { phase: true }];
    },
    (v) => {
      v.components = [{ sessionUUID: "automatic" }];
    },
    (v) => {
      v.components = [
        { sessionUUID: "uppercase" },
        { sessionUUID: "lowercase" },
      ];
    },
    (v) => {
      v.initialState = "unknown";
    },
    (v) => {
      v.allowedStates = ["absent"];
    },
    (v) => {
      v.allowedStates = ["present", "present"];
    },
    (v) => {
      v.allowedStates = ["present", "directory"];
    },
    (v) => {
      v.maximumBytes = 0;
    },
    (v) => {
      v.maximumBytes = 268435457;
    },
    (v) => {
      v.maximumEntries = 2;
    },
    (v) => {
      v.root = "owner-inputs";
    },
    (v) => {
      v.immutableFiles = [{ components: ["extra"], maximumBytes: 1 }];
    },
    (v) => {
      v.callerSegments = ["foreign"];
    },
  ]) {
    const scope = fileScopeFixture();
    mutate(scope);
    assert.throws(() => compileFileScopes([scope]));
  }
  assert.throws(() =>
    compileFileScopes([fileScopeFixture(), fileScopeFixture()]),
  );
  const directory = {
    ...fileScopeFixture(),
    kind: "directory",
    purpose: "immutable-input",
    root: "owner-data",
    maximumBytes: 2,
    maximumEntries: 3,
    allowedStates: ["present"],
    immutableFiles: [
      { components: ["Foo"], maximumBytes: 1 },
      { components: ["foo"], maximumBytes: 1 },
    ],
  };
  assert.throws(() => compileFileScopes([directory]));
  directory.immutableFiles[0].components = ["Foo", "a"];
  directory.immutableFiles[1].components = ["foo", "b"];
  directory.maximumEntries = 4;
  assert.throws(() => compileFileScopes([directory]));
  directory.immutableFiles[0].components = ["Foo"];
  directory.immutableFiles[1].components = ["Foo", "child"];
  assert.throws(() => compileFileScopes([directory]));
  directory.immutableFiles = [];
  directory.maximumEntries = 0;
  assert.throws(() => compileFileScopes([directory]));
  directory.maximumBytes = 0;
  compileFileScopes([directory]);
  directory.mutableFiles = [
    {
      components: ["victim"],
      maximumBytes: 1,
      initialState: "present",
      allowedStates: ["present", "absent"],
    },
  ];
  assert.throws(() => compileFileScopes([directory]));
});

test("single live issuer compiles bootstrap before final Host and preserves all39 role policies", () => {
  const f = fixture();
  assert.equal(f.manifest.runID, 10);
  assert.equal(f.manifest.jobID, 11);
  assert(!Object.hasOwn(f.admittedIssuer, "artifactID"));
  assert.equal(
    f.bootstrap.generatedPath,
    "Extensions/fixtureSupport/WorkerFixtureBootstrapTrustAnchor.swift",
  );
  assert(f.bootstrap.source.includes("try! WorkerFixtureBootstrapTrust("));
  assert(!f.bootstrap.source.includes("hostExecutableSHA256"));
  assert(!f.bootstrap.source.includes(f.artifact.host.executableSHA256));
  assert(f.bootstrap.source.includes(f.manifest.producer.executableSHA256));
  assert.equal(
    (f.bootstrap.source.match(/try WorkerFixtureRolePolicy\(/g) ?? []).length,
    40,
  );
  const role = generate(f);
  assert(role.source.includes(f.artifact.host.executableSHA256));
  assert.equal(role.sourceSHA256, sha(role.source));
  assert(!role.source.includes("privateKey"));
});

test("independent active run job build signer source and actual birth evidence cannot be forged", () => {
  const mutations = [
    (f) => {
      f.manifest.runID = 99;
    },
    (f) => {
      f.manifest.jobID = 99;
    },
    (f) => {
      f.evidence.run.head_sha = "e".repeat(40);
    },
    (f) => {
      f.evidence.job.head_sha = "e".repeat(40);
    },
    (f) => {
      f.evidence.job.run_id = 99;
    },
    (f) => {
      f.evidence.run.repository.full_name = "foreign/repo";
    },
    (f) => {
      f.evidence.run.actor.id = 1;
    },
    (f) => {
      f.evidence.job.labels.push("self-hosted");
    },
    (f) => {
      f.evidence.job.labels = ["macos-14"];
    },
    (f) => {
      f.evidence.run.status = "completed";
      f.evidence.run.conclusion = "success";
    },
    (f) => {
      f.evidence.job.status = "completed";
      f.evidence.job.conclusion = "success";
    },
    (f) => {
      f.evidence.artifactID = 12;
    },
    (f) => {
      f.evidence.trusted = true;
    },
    (f) => {
      f.manifest.privateKey = encoded;
    },
    (f) => {
      f.manifest.producer.certificateSHA256 = Buffer.alloc(32, 8).toString(
        "base64",
      );
    },
    (f) => {
      f.manifest.producer.executableSHA256 = "e".repeat(64);
    },
    (f) => {
      f.manifest.producer.sourceSHA256 = "e".repeat(64);
    },
    (f) => {
      f.evidence.build.source.bytes = canonicalBytes({
        sourceCommit,
        files: [],
      });
    },
    (f) => {
      f.evidence.build.toolchain.bytes = Buffer.from("different toolchain");
    },
    (f) => {
      f.evidence.bootstrap.issuerPublicKey = Buffer.alloc(32, 7).toString(
        "base64",
      );
    },
    (f) => {
      f.evidence.bootstrap.producer.birthSeconds += 1;
    },
    (f) => {
      f.observed.producer.birthMicroseconds += 1;
    },
    (f) => {
      f.observed.producer.pid += 1;
    },
    (f) => {
      f.observed.producer = null;
    },
  ];
  for (const mutate of mutations) {
    const f = liveFixture();
    mutate(f);
    assert.throws(() =>
      admitFunctionalLiveIssuer(
        canonicalBytes(f.manifest),
        f.evidence,
        f.observe,
      ),
    );
  }
});

test("dead or replaced issuer and changed Host invalidate already admitted compilation", () => {
  for (const mutate of [
    (f) => {
      f.observed.producer = null;
    },
    (f) => {
      f.observed.run.id += 1;
    },
    (f) => {
      f.observed.job.id += 1;
    },
    (f) => {
      f.observed.job.status = "completed";
    },
    (f) => {
      f.observed.run.conclusion = "success";
    },
    (f) => {
      f.observed.sourceCommit = "e".repeat(40);
    },
    (f) => {
      f.observed.producer.birthSeconds += 1;
    },
    (f) => {
      f.observed.producer.executableSHA256 = "e".repeat(64);
    },
    (f) => {
      f.observed.producer.certificateSHA256 = Buffer.alloc(32, 5).toString(
        "base64",
      );
    },
  ]) {
    const f = fixture();
    mutate(f);
    assert.throws(() => generate(f));
    assert.throws(() =>
      functionalFixtureBootstrapTrustSource(
        f.manifestBytes,
        f.admittedIssuer,
        f.policies.bytes,
        f.policies.admitted,
      ),
    );
  }
  for (const mutate of [
    (f) => {
      f.observedHost.value.host.executableSHA256 = "e".repeat(64);
    },
    (f) => {
      f.observedHost.value.sourceSHA256 = "e".repeat(64);
    },
    (f) => {
      f.observedHost.value.bootstrapSHA256 = "e".repeat(64);
    },
    (f) => {
      f.observedHost.value = null;
    },
  ]) {
    const f = fixture();
    mutate(f);
    assert.throws(() => generate(f));
  }
});

test("Host admission rejects source toolchain signer hash and invented bootstrap graph", () => {
  for (const mutate of [
    (f) => {
      f.hostEvidence.runID = 99;
    },
    (f) => {
      f.hostEvidence.jobID = 99;
    },
    (f) => {
      f.hostEvidence.bootstrapSHA256 = "e".repeat(64);
    },
    (f) => {
      f.hostEvidence.source.sha256 = "e".repeat(64);
    },
    (f) => {
      f.hostEvidence.toolchain.sha256 = "e".repeat(64);
    },
    (f) => {
      f.artifact.issuerManifestSHA256 = "e".repeat(64);
    },
    (f) => {
      f.artifact.issuerPublicKey = Buffer.alloc(32, 6).toString("base64");
    },
    (f) => {
      f.artifact.host.executableSHA256 = "e".repeat(64);
    },
    (f) => {
      f.artifact.host.certificateSHA256 = Buffer.alloc(32, 6).toString(
        "base64",
      );
    },
    (f) => {
      f.artifact.host.path = "/Applications/Edith.app";
    },
  ]) {
    const f = fixture();
    mutate(f);
    assert.throws(() =>
      admitFunctionalFixtureHost(
        canonicalBytes(f.artifact),
        f.admittedIssuer,
        f.hostEvidence,
        f.observeHost,
      ),
    );
  }
});

test("genuine PR context rejects dispatch forks stale source attempts and reversed merge parents", () => {
  const mutations = [
    (f) => {
      f.evidence.run.event = "workflow_dispatch";
    },
    (f) => {
      f.evidence.run.repository.id += 1;
    },
    (f) => {
      f.evidence.run.head_repository.id += 1;
    },
    (f) => {
      f.evidence.run.triggering_actor.id = 1;
    },
    (f) => {
      f.evidence.run.run_attempt += 1;
    },
    (f) => {
      f.evidence.run.workflow_id += 1;
    },
    (f) => {
      f.evidence.context.event.number = 1015;
    },
    (f) => {
      f.evidence.context.event.repository.id += 1;
    },
    (f) => {
      f.evidence.context.event.action = "closed";
    },
    (f) => {
      f.evidence.context.event.pull_request.head.repo.id += 1;
    },
    (f) => {
      f.evidence.context.pullRequest.head.repo.id += 1;
    },
    (f) => {
      f.evidence.context.pullRequest.base.repo.id += 1;
    },
    (f) => {
      f.evidence.context.pullRequest.head.sha = "f".repeat(40);
    },
    (f) => {
      f.evidence.context.pullRequest.base.sha = "f".repeat(40);
    },
    (f) => {
      f.evidence.context.pullRequest.state = "closed";
    },
    (f) => {
      f.evidence.context.pullRequest.merged = true;
    },
    (f) => {
      f.evidence.context.pullRequest.merge_commit_sha = "f".repeat(40);
    },
    (f) => {
      f.evidence.context.mergeCommit.sha = sourceCommit;
    },
    (f) => {
      f.evidence.context.mergeCommit.parents.reverse();
    },
    (f) => {
      f.evidence.context.mergeCommit.parents.pop();
    },
    (f) => {
      f.evidence.context.workflow.path = ".github/workflows/release.yml";
    },
    (f) => {
      f.evidence.context.workflow.state = "disabled_manually";
    },
  ];
  for (const mutate of mutations) {
    const f = liveFixture();
    mutate(f);
    assert.throws(() =>
      admitFunctionalLiveIssuer(
        canonicalBytes(f.manifest),
        f.evidence,
        f.observe,
      ),
    );
  }
  for (const mutate of [
    (f) => {
      f.observed.context.runAttempt += 1;
      f.observed.run.run_attempt += 1;
    },
    (f) => {
      f.observed.context.mergeCommit.sha = "f".repeat(40);
    },
    (f) => {
      f.observed.context.workflow.id += 1;
      f.observed.run.workflow_id += 1;
    },
    (f) => {
      f.observed.context.pullRequest.head.sha = "f".repeat(40);
    },
  ]) {
    const f = fixture();
    mutate(f);
    assert.throws(() => generate(f));
  }
});

test("Host artifact admission pins actual live birth executable signer and same uid", () => {
  for (const mutate of [
    (f) => {
      f.hostEvidence.hostProcess.pid = f.evidence.launch.pid;
    },
    (f) => {
      f.hostEvidence.hostProcess.uid += 1;
    },
    (f) => {
      f.hostEvidence.hostProcess.executable =
        "/Applications/Edith.app/Contents/MacOS/Edith";
    },
    (f) => {
      f.hostEvidence.hostProcess.executableSHA256 = "e".repeat(64);
    },
    (f) => {
      f.hostEvidence.hostProcess.certificateSHA256 = Buffer.alloc(
        32,
        7,
      ).toString("base64");
    },
    (f) => {
      f.hostEvidence.hostProcess.requirement = "anchor apple";
    },
  ]) {
    const f = fixture();
    mutate(f);
    assert.throws(() =>
      admitFunctionalFixtureHost(
        f.bytes,
        f.admittedIssuer,
        f.hostEvidence,
        f.observeHost,
      ),
    );
  }
  for (const mutate of [
    (f) => {
      f.observedHost.value.hostProcess.birthMicroseconds += 1;
    },
    (f) => {
      f.observedHost.value.hostProcess.pid += 1;
    },
    (f) => {
      f.observedHost.value.hostProcess = null;
    },
  ]) {
    const f = fixture();
    mutate(f);
    assert.throws(() => generate(f));
  }
});

test("Notch policy compiles only its exact signed settings and catalog operation set", () => {
  for (const operations of [
    ["notch.settings.read", "notch.settings.write"],
    [
      "notch.settings.read",
      "notch.settings.write",
      "notchShelf.cli.catalog",
      "notch.customize",
    ],
    ["notchShelf.cli.catalog"],
    ["notch.settings.write", "notch.settings.read", "notchShelf.cli.catalog"],
  ]) {
    const f = policyFixture();
    f.policies.find((policy) => policy.owner === "notchShelf").operations =
      operations;
    f.bytes = canonicalBytes(f.policies);
    f.admitted.policySHA256 = sha(f.bytes);
    assert.throws(() => functionalFixtureRolePolicySource(f.bytes, f.admitted));
  }
});

test("only PR source bindings remain immutable across unrelated API metadata updates", () => {
  const f = fixture();
  f.observed.context.pullRequest.comments = 12;
  f.observed.context.pullRequest.updated_at = "2026-10-12T03:00:00Z";
  f.observed.context.workflow.updated_at = "2026-10-12T03:00:00Z";
  assert.equal(generate(f).artifactSHA256, f.admitted.artifactSHA256);
  for (const mutate of [
    (f) => {
      f.evidence.run.pull_requests = [];
    },
    (f) => {
      f.evidence.run.pull_requests[0].number = 1015;
    },
    (f) => {
      f.evidence.run.pull_requests[0].head.repo.id += 1;
    },
    (f) => {
      f.evidence.run.pull_requests[0].base.sha = "e".repeat(40);
    },
    (f) => {
      f.evidence.context.event.pull_request.head.ref = "foreign";
      f.evidence.context.pullRequest.head.ref = "foreign";
    },
  ]) {
    const f = liveFixture();
    mutate(f);
    assert.throws(() =>
      admitFunctionalLiveIssuer(
        canonicalBytes(f.manifest),
        f.evidence,
        f.observe,
      ),
    );
  }
  const changedActor = fixture();
  changedActor.observed.run.actor.id = 320458784;
  assert.throws(() => generate(changedActor));
  const ready = liveFixture();
  ready.evidence.context.event.action = "ready_for_review";
  ready.observed.context.event.action = "ready_for_review";
  assert(
    admitFunctionalLiveIssuer(
      canonicalBytes(ready.manifest),
      ready.evidence,
      ready.observe,
    ),
  );
});

test("worker defaults filenames compile only the closed actual engine or UI suite derivation", () => {
  for (const domain of ["engine", "ui"]) {
    const f = policyFixture();
    const scope = {
      name: "preferences",
      kind: "file",
      purpose: "mutable-state",
      root: "owner-home",
      components: [
        { literal: "Library" },
        { literal: "Preferences" },
        { workerDefaultsPlist: domain },
      ],
      maximumBytes: 4096,
      maximumEntries: 1,
      initialState: "absent",
      allowedStates: ["absent", "present"],
      immutableFiles: [],
      mutableFiles: [],
    };
    const compile = (value) => {
      f.policies[0].fileScopes = [value];
      f.bytes = canonicalBytes(f.policies);
      f.admitted.policySHA256 = sha(f.bytes);
      return functionalFixtureRolePolicySource(f.bytes, f.admitted);
    };
    assert(
      compile(scope).swiftExpression.includes(
        `.workerDefaultsPlist(.${domain})`,
      ),
    );
    for (const mutate of [
      (s) => {
        s.components[2].workerDefaultsPlist = "foreign";
      },
      (s) => {
        s.components[2].workerDefaultsPlist = true;
      },
      (s) => {
        s.components[2].suite = "arbitrary";
      },
      (s) => {
        s.components[1].literal = "Other";
      },
      (s) => {
        s.components.push({ phase: true });
      },
      (s) => {
        s.components = [{ workerDefaultsPlist: domain }];
      },
      (s) => {
        s.root = "owner-data";
      },
      (s) => {
        s.purpose = "immutable-input";
      },
      (s) => {
        s.kind = "directory";
      },
    ]) {
      const changed = structuredClone(scope);
      mutate(changed);
      assert.throws(() => compile(changed));
    }
  }
});

test("current attempt job and nonempty runner remain bound throughout issuer lifetime", () => {
  for (const mutate of [
    (f) => {
      f.evidence.job.run_attempt += 1;
    },
    (f) => {
      delete f.evidence.job.run_attempt;
    },
    (f) => {
      f.evidence.job.runner_name = "";
    },
    (f) => {
      f.evidence.job.runner_name = " ";
    },
    (f) => {
      f.evidence.job.runner_name = "runner\nforeign";
    },
    (f) => {
      delete f.evidence.job.runner_name;
    },
  ]) {
    const f = liveFixture();
    mutate(f);
    assert.throws(() =>
      admitFunctionalLiveIssuer(
        canonicalBytes(f.manifest),
        f.evidence,
        f.observe,
      ),
    );
  }
  for (const mutate of [
    (f) => {
      f.observed.job.run_attempt += 1;
    },
    (f) => {
      f.observed.job.runner_name = "GitHub Actions replaced";
    },
  ]) {
    const f = fixture();
    mutate(f);
    assert.throws(() => generate(f));
  }
});
