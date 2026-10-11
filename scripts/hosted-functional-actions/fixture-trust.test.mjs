import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import test from "node:test";
import { functionalCanonicalJSON } from "./contract.mjs";
import { functionalFixtureTrustSource } from "./fixture-trust.mjs";

const sourceCommit = "a".repeat(40);
const session = "12345678-1234-4123-8123-123456789abc";
const root = `/private/synthetic/functional-fixture-${session}`;
const encoded = Buffer.alloc(32, 1).toString("base64");
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
  const result = functionalFixtureTrustSource(f.bytes, f.admitted);
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
    assert.throws(() => functionalFixtureTrustSource(f.bytes, f.admitted));
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
    assert.throws(() => functionalFixtureTrustSource(f.bytes, f.admitted));
  }
  const f = fixture();
  f.bytes = Buffer.from('{"schema":1,' + f.bytes.toString().slice(1));
  f.admitted.artifactSHA256 = createHash("sha256")
    .update(f.bytes)
    .digest("hex");
  assert.throws(() => functionalFixtureTrustSource(f.bytes, f.admitted));
});
