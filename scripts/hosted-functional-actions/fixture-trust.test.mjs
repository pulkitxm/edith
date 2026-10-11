import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import test from "node:test";
import { functionalCanonicalJSON } from "./contract.mjs";
import {
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
    operations: [`${owner}.probe`],
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

function fixture() {
  const artifact = {
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
      requirement: 'identifier "com.pulkit.edith.tests" and anchor trusted',
    },
    producer: {
      path: `${root}/Producer/functional-producer`,
      executableSHA256: "c".repeat(64),
    },
    workerCertificateSHA256: encoded,
    roleCertificateSHA256: encoded,
  };
  const bytes = Buffer.from(functionalCanonicalJSON(artifact));
  return {
    artifact,
    bytes,
    admitted: {
      sourceCommit,
      runID: 10,
      jobID: 11,
      artifactID: 12,
      artifactSHA256: createHash("sha256").update(bytes).digest("hex"),
    },
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
    39,
  );
  assert(result.source.includes('section: "extension"'));
});

test("descriptor selected keys, source changes, duplicate fields and foreign paths cannot create fixture trust", () => {
  for (const mutate of [
    (f) => {
      f.admitted.artifactSHA256 = "d".repeat(64);
    },
    (f) => {
      f.admitted.sourceCommit = "e".repeat(40);
    },
    (f) => {
      f.admitted.runID = 0;
    },
    (f) => {
      f.admitted.trusted = true;
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
    f.admitted.artifactSHA256 = createHash("sha256")
      .update(f.bytes)
      .digest("hex");
    assert.throws(() => generate(f));
  }
  const f = fixture();
  f.bytes = Buffer.from(`{"schema":1,${f.bytes.toString().slice(1)}`);
  f.admitted.artifactSHA256 = createHash("sha256")
    .update(f.bytes)
    .digest("hex");
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
