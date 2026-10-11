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
    operations: [owner + ".probe"],
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
  f.bytes = Buffer.from('{"schema":1,' + f.bytes.toString().slice(1));
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
