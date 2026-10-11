import { expect, test } from "bun:test";
import { createHash, generateKeyPairSync, sign } from "node:crypto";
import {
  createSignedAppcast,
  sparkleURL,
  validateSparkleFixture,
  validateSparkleOutcome,
  verifySparkleArchive,
} from "./hosted-sparkle-update/contract.mjs";

function setup() {
  const archive = Buffer.from("Synthetic signed app archive");
  const { privateKey, publicKey } = generateKeyPairSync("ed25519");
  const key = publicKey
    .export({ type: "spki", format: "der" })
    .subarray(-32)
    .toString("base64");
  const fixture = {
    schema: 1,
    expectedUID: 501,
    initialCodeSHA256: "c".repeat(64),
    initialMetadataSHA256: "1".repeat(64),
    installedMetadataSHA256: "2".repeat(64),
    session: "00000000-0000-4000-8000-000000000001",
    sourceCommit: "a".repeat(40),
    identifier:
      "com.pulkit.edith.tests.remote-00000000-0000-4000-8000-000000000001",
    directory:
      "/Users/fixture/Applications/Edith Remote Fixture Journey 00000000-0000-4000-8000-000000000001",
    publicKey: key,
    port: 12345,
    archiveSHA256: createHash("sha256").update(archive).digest("hex"),
    archiveBytes: archive.length,
    versions: ["1.0.0", "2.0.0"],
    protectedSHA256: Object.fromEntries(
      [
        "sentinel",
        "calendarData",
        "homeLayout",
        "notchLayout",
        "installedSelection",
      ].map((key) => [key, "b".repeat(64)]),
    ),
    installedCodeSHA256: "d".repeat(64),
    installedResourcesSHA256: "e".repeat(64),
    signingRequirementSHA256: "f".repeat(64),
    producer: {
      pid: 100,
      birth: "99.1",
      uid: 501,
      executable: "/opt/homebrew/bin/node",
      executableSHA256: "c".repeat(64),
    },
  };
  fixture.ownedRolePaths = {
    engine: `${fixture.directory}/Host.app/Contents/MacOS/Edith`,
    managedUI: `${fixture.directory}/support/Edith Tests/remote-${fixture.session}/Extensions/calendar/v1/UI.app/Contents/PlugIns/UI.appex/Contents/MacOS/Edith`,
  };
  const environment = {
    GITHUB_ACTIONS: "true",
    RUNNER_OS: "macOS",
    RUNNER_ENVIRONMENT: "github-hosted",
    GITHUB_REPOSITORY: "pulkitxm/edith",
    GITHUB_ACTOR_ID: "320458784",
    GITHUB_REF: "refs/heads/feat/hosted-sparkle-update",
    GITHUB_SHA: fixture.sourceCommit,
    EDITH_HOSTED_SPARKLE_UPDATE: "1",
  };
  const signature = sign(null, archive, privateKey).toString("base64");
  const outcome = {
    schema: 1,
    sourceCommit: fixture.sourceCommit,
    session: fixture.session,
    identifier: fixture.identifier,
    outcome: "passed",
    versions: fixture.versions,
    archiveSHA256: fixture.archiveSHA256,
    downloadedBytes: fixture.archiveBytes,
    sparkleInstallObserved: true,
    nativeRelaunchObserved: true,
    producerReplacementUsed: false,
    testLaunchAfterInstall: false,
    oldHost: {
      pid: 101,
      birth: "100.1",
      uid: 501,
      executableSHA256: "c".repeat(64),
      version: "1.0.0",
      executable: `${fixture.directory}/Host.app/Contents/MacOS/Edith`,
    },
    newHost: {
      pid: 102,
      birth: "101.2",
      uid: 501,
      executableSHA256: "d".repeat(64),
      version: "2.0.0",
      executable: `${fixture.directory}/Host.app/Contents/MacOS/Edith`,
    },
    oldOwnedSurvivors: 0,
    ownedConflicts: 0,
    protectedSHA256: fixture.protectedSHA256,
    calendarReopened: true,
    newEngineObserved: true,
    newManagedUIObserved: true,
    disabledOwnedSurvivors: 0,
    removedVersions: ["1.0.0", "1.1.0"],
    wrongSignatureRejected: true,
    tamperedArchiveRejected: true,
    productionGateUnchanged: true,
    installedCodeSHA256: fixture.installedCodeSHA256,
    installedResourcesSHA256: fixture.installedResourcesSHA256,
    signingRequirementSHA256: fixture.signingRequirementSHA256,
    installedSignatureVerified: true,
    initialMetadataSHA256: fixture.initialMetadataSHA256,
    installedMetadataSHA256: fixture.installedMetadataSHA256,
  };
  outcome.oldRoles = ["engine", "managedUI"].map((role, index) => ({
    role,
    pid: 110 + index,
    birth: `100.${index}`,
    uid: fixture.expectedUID,
    executable: fixture.ownedRolePaths[role],
    running: true,
  }));
  outcome.oldRolesAfterInstall = outcome.oldRoles.map((row) => ({
    ...row,
    running: false,
  }));
  outcome.reopenedRoles = outcome.oldRoles.map((row) => ({
    ...row,
    pid: row.pid + 100,
    birth: `200.${row.pid}`,
  }));
  outcome.disabledRoles = outcome.reopenedRoles.map((row) => ({
    ...row,
    running: false,
  }));
  return { fixture, environment, archive, signature, outcome };
}

test("the exact hosted UUID source and signed full archive are admitted", () => {
  const { fixture, environment, archive, signature } = setup();
  expect(
    validateSparkleFixture(fixture, environment, "/Users/fixture"),
  ).toEqual(fixture);
  verifySparkleArchive(fixture, archive, signature);
  const xml = createSignedAppcast(fixture, signature).toString();
  expect(xml).toContain(sparkleURL(fixture, "Edith.zip"));
  expect(xml).toContain(`sparkle:edSignature="${signature}"`);
  expect(xml).toContain(`length="${archive.length}"`);
});

test("runner, source, identity, paths and unbounded metadata cannot qualify a fixture", () => {
  const { fixture, environment } = setup();
  for (const key of Object.keys(environment))
    expect(() =>
      validateSparkleFixture(
        fixture,
        { ...environment, [key]: "foreign" },
        "/Users/fixture",
      ),
    ).toThrow();
  for (const change of [
    { schema: 2 },
    { identifier: "com.pulkit.edith" },
    { session: "../escape" },
    { directory: "/Applications/Edith.app" },
    { port: 80 },
    { archiveBytes: 0 },
    { archiveBytes: 101 * 1024 * 1024 },
    { publicKey: "bad" },
    { versions: ["2.0.0", "1.0.0"] },
    { unexpected: true },
  ])
    expect(() =>
      validateSparkleFixture(
        { ...fixture, ...change },
        environment,
        "/Users/fixture",
      ),
    ).toThrow();
  expect(() => sparkleURL(fixture, "../Edith.zip")).toThrow();
});

test("tampered archives and foreign ephemeral keys are rejected", () => {
  const { fixture, archive, signature } = setup();
  expect(() =>
    verifySparkleArchive(
      fixture,
      Buffer.from("X".repeat(archive.length)),
      signature,
    ),
  ).toThrow();
  expect(() =>
    verifySparkleArchive(
      { ...fixture, publicKey: setup().fixture.publicKey },
      archive,
      signature,
    ),
  ).toThrow();
  expect(() => createSignedAppcast(fixture, "bad")).toThrow();
});

test("only actual Sparkle download install native relaunch and retained data can finish", () => {
  const { fixture, outcome } = setup();
  expect(validateSparkleOutcome(outcome, fixture)).toBe(outcome);
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
    expect(() =>
      validateSparkleOutcome({ ...outcome, [key]: false }, fixture),
    ).toThrow();
  for (const change of [
    { producerReplacementUsed: true },
    { testLaunchAfterInstall: true },
    { oldOwnedSurvivors: 1 },
    { ownedConflicts: 1 },
    { disabledOwnedSurvivors: 1 },
    { downloadedBytes: 0 },
    { newHost: outcome.oldHost },
    { protectedSHA256: {} },
    { removedVersions: [] },
    { sourceCommit: "f".repeat(40) },
    { installedCodeSHA256: "0".repeat(64) },
    { installedResourcesSHA256: "0".repeat(64) },
    { installedSignatureVerified: false },
    { oldRoles: [] },
    { oldRolesAfterInstall: outcome.oldRoles },
    { reopenedRoles: outcome.oldRoles },
    { disabledRoles: outcome.reopenedRoles },
  ])
    expect(() =>
      validateSparkleOutcome({ ...outcome, ...change }, fixture),
    ).toThrow();
});

test("same-source full updates retain executable code but replace signed metadata", () => {
  const { fixture, outcome } = setup();
  fixture.installedCodeSHA256 = fixture.initialCodeSHA256;
  outcome.installedCodeSHA256 = fixture.initialCodeSHA256;
  outcome.newHost.executableSHA256 = fixture.initialCodeSHA256;
  expect(validateSparkleOutcome(outcome, fixture)).toBe(outcome);
  expect(() =>
    validateSparkleOutcome(
      { ...outcome, installedMetadataSHA256: outcome.initialMetadataSHA256 },
      fixture,
    ),
  ).toThrow();
});
