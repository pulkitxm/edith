import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { functionalCanonicalJSON } from "./contract.mjs";

const hash = /^[0-9a-f]{64}$/;
const source = /^[0-9a-f]{40}$/;
const uuid =
  /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;

function exact(value, fields) {
  assert(value && Object.getPrototypeOf(value) === Object.prototype);
  assert.deepEqual(Object.keys(value).sort(), [...fields].sort());
}

function bytes(value) {
  assert.match(value, /^[A-Za-z0-9+/]{43}=$/);
  const result = Buffer.from(value, "base64");
  assert.equal(result.length, 32);
  assert.equal(result.toString("base64"), value);
  return result;
}

function canonicalPath(value) {
  assert(
    typeof value === "string" && value.startsWith("/") && value.length <= 4096,
  );
  assert(!value.endsWith("/") && !value.includes("//"));
  assert(
    [...value].every(
      (character) =>
        character.charCodeAt(0) >= 32 && character.charCodeAt(0) < 127,
    ),
  );
  assert(
    !value
      .split("/")
      .slice(1)
      .some((part) => ["", ".", ".."].includes(part)),
  );
}

function swiftString(value) {
  assert(typeof value === "string");
  return `"${value.replaceAll("\\", "\\\\").replaceAll('"', '\\"')}"`;
}

export function functionalFixtureTrustSource(artifactBytes, admittedArtifact) {
  exact(admittedArtifact, [
    "sourceCommit",
    "runID",
    "jobID",
    "artifactID",
    "artifactSHA256",
  ]);
  assert.match(admittedArtifact.sourceCommit, source);
  assert.match(admittedArtifact.artifactSHA256, hash);
  for (const field of ["runID", "jobID", "artifactID"])
    assert(
      Number.isSafeInteger(admittedArtifact[field]) &&
        admittedArtifact[field] > 0,
    );
  assert(
    Buffer.isBuffer(artifactBytes) &&
      artifactBytes.length > 0 &&
      artifactBytes.length <= 65536,
  );
  assert.equal(
    createHash("sha256").update(artifactBytes).digest("hex"),
    admittedArtifact.artifactSHA256,
  );
  const artifact = JSON.parse(
    new TextDecoder("utf-8", { fatal: true }).decode(artifactBytes),
  );
  assert.equal(
    functionalCanonicalJSON(artifact),
    artifactBytes.toString("utf8"),
  );
  exact(artifact, [
    "schema",
    "sourceCommit",
    "session",
    "root",
    "hostIdentifier",
    "issuerPublicKey",
    "host",
    "producer",
    "workerCertificateSHA256",
    "roleCertificateSHA256",
  ]);
  assert.equal(artifact.schema, 1);
  assert.equal(artifact.sourceCommit, admittedArtifact.sourceCommit);
  assert.match(artifact.session, uuid);
  canonicalPath(artifact.root);
  assert(artifact.root.endsWith(`/functional-fixture-${artifact.session}`));
  assert.equal(
    artifact.hostIdentifier,
    `com.pulkit.edith.tests.worker-${artifact.session}`,
  );
  exact(artifact.host, [
    "path",
    "executableSHA256",
    "certificateSHA256",
    "requirement",
  ]);
  assert.equal(artifact.host.path, `${artifact.root}/Fixture.app`);
  assert.match(artifact.host.executableSHA256, hash);
  bytes(artifact.host.certificateSHA256);
  assert(
    typeof artifact.host.requirement === "string" &&
      artifact.host.requirement.length > 0 &&
      artifact.host.requirement.length <= 1024,
  );
  assert(
    [...artifact.host.requirement].every(
      (character) =>
        character.charCodeAt(0) >= 32 && character.charCodeAt(0) < 127,
    ),
  );
  exact(artifact.producer, ["path", "executableSHA256"]);
  assert.equal(
    artifact.producer.path,
    `${artifact.root}/Producer/functional-producer`,
  );
  assert.match(artifact.producer.executableSHA256, hash);
  bytes(artifact.issuerPublicKey);
  bytes(artifact.workerCertificateSHA256);
  bytes(artifact.roleCertificateSHA256);
  const data = (value) => `Data(base64Encoded: ${swiftString(value)})!`;
  const arguments_ = [
    `sourceCommit: ${swiftString(artifact.sourceCommit)}`,
    `session: ${swiftString(artifact.session)}`,
    `root: ${swiftString(artifact.root)}`,
    `issuerKey: ${data(artifact.issuerPublicKey)}`,
    `hostExecutableSHA256: ${swiftString(artifact.host.executableSHA256)}`,
    `hostRequirement: ${swiftString(artifact.host.requirement)}`,
    `hostCertificateSHA256: ${data(artifact.host.certificateSHA256)}`,
    `workerCertificateSHA256: ${data(artifact.workerCertificateSHA256)}`,
    `roleCertificateSHA256: ${data(artifact.roleCertificateSHA256)}`,
    `producerExecutable: ${swiftString(artifact.producer.path)}`,
    `producerExecutableSHA256: ${swiftString(artifact.producer.executableSHA256)}`,
  ];
  return Object.freeze({
    sourceCommit: artifact.sourceCommit,
    artifactSHA256: admittedArtifact.artifactSHA256,
    source: `import Foundation\n\npublic enum WorkerFixtureUITrustAnchor {\n    public static let admitted: WorkerFixtureUITrust? = try! WorkerFixtureUITrust(\n        ${arguments_.join(",\n        ")}\n    )\n}\n`,
    generatedPath: "Extensions/fixtureSupport/WorkerFixtureUITrustAnchor.swift",
    scope:
      "independently admitted fixture build constants before compilation and signing",
  });
}
