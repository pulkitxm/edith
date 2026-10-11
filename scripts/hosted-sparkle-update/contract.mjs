import assert from "node:assert/strict";
import { createHash, createPublicKey, verify } from "node:crypto";

const sha = (value) => /^[a-f0-9]{64}$/.test(value);
const uuid = /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/;
const exactKeys = (value, keys) =>
  assert.deepEqual(Object.keys(value).sort(), [...keys].sort());

export function validateSparkleFixture(value, environment, accountHome) {
  exactKeys(value, [
    "schema",
    "session",
    "sourceCommit",
    "identifier",
    "directory",
    "publicKey",
    "port",
    "archiveSHA256",
    "archiveBytes",
    "versions",
    "protectedSHA256",
    "installedCodeSHA256",
    "installedResourcesSHA256",
    "signingRequirementSHA256",
    "producer",
    "expectedUID",
    "initialCodeSHA256",
    "initialMetadataSHA256",
    "installedMetadataSHA256",
    "ownedRolePaths",
  ]);
  assert.equal(value.schema, 1);
  assert(Number.isInteger(value.expectedUID) && value.expectedUID > 0);
  assert(uuid.test(value.session));
  assert(/^[a-f0-9]{40}$/.test(value.sourceCommit));
  assert.equal(
    value.identifier,
    `com.pulkit.edith.tests.remote-${value.session}`,
  );
  assert(/^\/Users\/[A-Za-z0-9_-]+$/.test(accountHome));
  assert.equal(
    value.directory,
    `${accountHome}/Applications/Edith Remote Fixture Journey ${value.session}`,
  );
  assert.equal(environment.GITHUB_ACTIONS, "true");
  assert.equal(environment.RUNNER_OS, "macOS");
  assert.equal(environment.RUNNER_ENVIRONMENT, "github-hosted");
  assert.equal(environment.GITHUB_REPOSITORY, "pulkitxm/edith");
  assert(["65671483", "320458784"].includes(environment.GITHUB_ACTOR_ID));
  assert(
    [
      "refs/heads/main",
      "refs/heads/feat/extension-marketplace",
      "refs/heads/feat/hosted-sparkle-update",
    ].includes(environment.GITHUB_REF),
  );
  assert.equal(environment.GITHUB_SHA, value.sourceCommit);
  assert.equal(environment.EDITH_HOSTED_SPARKLE_UPDATE, "1");
  assert(
    Number.isInteger(value.port) && value.port >= 1024 && value.port <= 65535,
  );
  const key = Buffer.from(value.publicKey, "base64");
  assert.equal(key.length, 32);
  assert.equal(key.toString("base64"), value.publicKey);
  assert(sha(value.archiveSHA256));
  for (const key of [
    "installedCodeSHA256",
    "installedResourcesSHA256",
    "signingRequirementSHA256",
    "initialCodeSHA256",
    "initialMetadataSHA256",
    "installedMetadataSHA256",
  ])
    assert(sha(value[key]));
  exactKeys(value.producer, [
    "pid",
    "birth",
    "uid",
    "executable",
    "executableSHA256",
  ]);
  assert(Number.isInteger(value.producer.pid) && value.producer.pid > 1);
  assert(/^[0-9]+\.[0-9]+$/.test(value.producer.birth));
  assert(Number.isInteger(value.producer.uid) && value.producer.uid > 0);
  assert.equal(value.producer.uid, value.expectedUID);
  exactKeys(value.ownedRolePaths, ["engine", "managedUI"]);
  assert.equal(
    value.ownedRolePaths.engine,
    `${value.directory}/Host.app/Contents/MacOS/Edith`,
  );
  assert.equal(
    value.ownedRolePaths.managedUI,
    `${value.directory}/support/Edith Tests/remote-${value.session}/Extensions/calendar/edith-host-2/arm64/1.0.0/calendar/ExtensionCarrier.app/Contents/Extensions/ExtensionWorker.appex/Contents/MacOS/Edith`,
  );
  assert(
    /^\/[A-Za-z0-9._ /-]+$/.test(value.producer.executable) &&
      !value.producer.executable.includes("//") &&
      !value.producer.executable.endsWith("/"),
  );
  assert(
    !value.producer.executable
      .split("/")
      .some((part) => part === "." || part === ".."),
  );
  assert(sha(value.producer.executableSHA256));
  assert(
    Number.isSafeInteger(value.archiveBytes) &&
      value.archiveBytes > 0 &&
      value.archiveBytes <= 100 * 1024 * 1024,
  );
  assert.deepEqual(value.versions, ["1.0.0", "2.0.0"]);
  exactKeys(value.protectedSHA256, [
    "sentinel",
    "calendarData",
    "homeLayout",
    "notchLayout",
    "installedSelection",
  ]);
  assert(Object.values(value.protectedSHA256).every(sha));
  return Object.freeze({ ...value });
}

export function sparkleURL(fixture, name) {
  assert(["appcast.xml", "Edith.zip"].includes(name));
  return `http://127.0.0.1:${fixture.port}/${fixture.session}/${name}`;
}

export function createSignedAppcast(fixture, signature) {
  const bytes = Buffer.from(signature, "base64");
  assert.equal(bytes.length, 64);
  assert.equal(bytes.toString("base64"), signature);
  return Buffer.from(
    `<?xml version="1.0" encoding="utf-8"?>\n<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><title>Synthetic update</title><item><title>Version 2.0.0</title><sparkle:version>2</sparkle:version><sparkle:shortVersionString>2.0.0</sparkle:shortVersionString><enclosure url="${sparkleURL(fixture, "Edith.zip")}" length="${fixture.archiveBytes}" type="application/octet-stream" sparkle:edSignature="${signature}" /></item></channel></rss>\n`,
  );
}

export function verifySparkleArchive(fixture, archive, signature) {
  assert.equal(archive.length, fixture.archiveBytes);
  assert.equal(
    createHash("sha256").update(archive).digest("hex"),
    fixture.archiveSHA256,
  );
  const prefix = Buffer.from("302a300506032b6570032100", "hex");
  const key = createPublicKey({
    key: Buffer.concat([prefix, Buffer.from(fixture.publicKey, "base64")]),
    format: "der",
    type: "spki",
  });
  assert(
    verify(null, archive, key, Buffer.from(signature, "base64")),
    "Synthetic update signature rejected",
  );
}

export function validateSparkleOutcome(value, fixture) {
  exactKeys(value, [
    "schema",
    "sourceCommit",
    "session",
    "identifier",
    "outcome",
    "versions",
    "archiveSHA256",
    "downloadedBytes",
    "sparkleInstallObserved",
    "nativeRelaunchObserved",
    "producerReplacementUsed",
    "testLaunchAfterInstall",
    "oldHost",
    "newHost",
    "oldOwnedSurvivors",
    "ownedConflicts",
    "protectedSHA256",
    "calendarReopened",
    "newEngineObserved",
    "newManagedUIObserved",
    "disabledOwnedSurvivors",
    "removedVersions",
    "wrongSignatureRejected",
    "tamperedArchiveRejected",
    "productionGateUnchanged",
    "installedCodeSHA256",
    "installedResourcesSHA256",
    "signingRequirementSHA256",
    "installedSignatureVerified",
    "initialMetadataSHA256",
    "installedMetadataSHA256",
    "oldRoles",
    "oldRolesAfterInstall",
    "reopenedRoles",
    "disabledRoles",
  ]);
  assert.equal(value.schema, 1);
  assert.equal(value.sourceCommit, fixture.sourceCommit);
  assert.equal(value.session, fixture.session);
  assert.equal(value.identifier, fixture.identifier);
  assert.equal(value.outcome, "passed");
  assert.deepEqual(value.versions, fixture.versions);
  assert.equal(value.archiveSHA256, fixture.archiveSHA256);
  assert.equal(value.downloadedBytes, fixture.archiveBytes);
  for (const key of [
    "installedCodeSHA256",
    "installedResourcesSHA256",
    "signingRequirementSHA256",
    "initialMetadataSHA256",
    "installedMetadataSHA256",
  ])
    assert.equal(value[key], fixture[key]);
  assert.equal(value.installedSignatureVerified, true);
  for (const key of [
    "sparkleInstallObserved",
    "nativeRelaunchObserved",
    "calendarReopened",
    "newEngineObserved",
    "newManagedUIObserved",
    "wrongSignatureRejected",
    "tamperedArchiveRejected",
    "productionGateUnchanged",
  ])
    assert.equal(value[key], true);
  assert.equal(value.producerReplacementUsed, false);
  assert.equal(value.testLaunchAfterInstall, false);
  for (const key of [
    "oldOwnedSurvivors",
    "ownedConflicts",
    "disabledOwnedSurvivors",
  ])
    assert.equal(value[key], 0);
  for (const host of [value.oldHost, value.newHost]) {
    exactKeys(host, [
      "pid",
      "birth",
      "uid",
      "executableSHA256",
      "version",
      "executable",
    ]);
    assert(Number.isInteger(host.pid) && host.pid > 1);
    assert(/^[0-9]+\.[0-9]+$/.test(host.birth));
    assert(Number.isInteger(host.uid) && host.uid > 0);
    assert.equal(host.uid, fixture.expectedUID);
    assert.equal(
      host.executable,
      `${fixture.directory}/Host.app/Contents/MacOS/Edith`,
    );
    assert(sha(host.executableSHA256));
  }
  assert.notEqual(value.oldHost.pid, value.newHost.pid);
  assert.notEqual(value.oldHost.birth, value.newHost.birth);
  assert.equal(value.oldHost.uid, value.newHost.uid);
  assert.equal(value.oldHost.version, "1.0.0");
  assert.equal(value.newHost.version, "2.0.0");
  assert.equal(value.oldHost.executableSHA256, fixture.initialCodeSHA256);
  assert.equal(value.newHost.executableSHA256, fixture.installedCodeSHA256);
  assert.notEqual(value.initialMetadataSHA256, value.installedMetadataSHA256);
  validateRoles(value.oldRoles, fixture, true);
  validateRoles(value.oldRolesAfterInstall, fixture, false);
  validateRoles(value.reopenedRoles, fixture, true);
  validateRoles(value.disabledRoles, fixture, false);
  const identity = ({ running: _running, ...row }) => row;
  assert.deepEqual(
    value.oldRolesAfterInstall.map(identity),
    value.oldRoles.map(identity),
  );
  assert.deepEqual(
    value.disabledRoles.map(identity),
    value.reopenedRoles.map(identity),
  );
  for (let index = 0; index < 2; index++) {
    assert.notEqual(value.oldRoles[index].pid, value.reopenedRoles[index].pid);
    assert.notEqual(
      value.oldRoles[index].birth,
      value.reopenedRoles[index].birth,
    );
  }
  assert.deepEqual(value.protectedSHA256, fixture.protectedSHA256);
  assert.deepEqual(value.removedVersions, ["1.0.0", "1.1.0"]);
  return value;
}

function validateRoles(rows, fixture, running) {
  assert(Array.isArray(rows) && rows.length === 2);
  assert.deepEqual(
    rows.map((row) => row.role),
    ["engine", "managedUI"],
  );
  assert.notEqual(rows[0].pid, rows[1].pid);
  for (const row of rows) {
    exactKeys(row, ["role", "pid", "birth", "uid", "executable", "running"]);
    assert(Number.isInteger(row.pid) && row.pid > 1);
    assert(/^[0-9]+\.[0-9]+$/.test(row.birth));
    assert.equal(row.uid, fixture.expectedUID);
    assert.equal(row.executable, fixture.ownedRolePaths[row.role]);
    assert.equal(row.running, running);
  }
}
