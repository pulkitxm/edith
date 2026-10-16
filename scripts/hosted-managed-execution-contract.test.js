import { expect, test } from "bun:test";
import { readFile } from "node:fs/promises";
import {
  admitManagedExecution,
  managedApplicationEnvironment,
  managedAuthenticatedFetch,
  parseManagedExecutionArguments,
  validateManagedExecutionResults,
} from "./hosted-managed-views/execution-contract.mjs";

const source = "a".repeat(40);
const environment = {
  GITHUB_ACTIONS: "true",
  RUNNER_OS: "macOS",
  RUNNER_ENVIRONMENT: "github-hosted",
  GITHUB_REPOSITORY: "pulkitxm/edith",
  GITHUB_ACTOR_ID: "65671483",
  GITHUB_EVENT_NAME: "workflow_dispatch",
  GITHUB_REF: "refs/heads/feat/hosted-managed-view-execution",
  GITHUB_SHA: source,
  EXPECTED_SOURCE_SHA: source,
  EDITH_HOSTED_MANAGED_VIEWS: "1",
  PUBLISH: "false",
  REBUILD: "",
};

test("hosted execution admits only reviewed exact nonpublishing source and closed command inputs", () => {
  expect(
    parseManagedExecutionArguments([
      "--artifact-run",
      "12345",
      "--artifact-source",
      source,
      "--chunk",
      "0",
    ]),
  ).toEqual({ runID: 12345, artifactSource: source, chunk: 0 });
  for (const args of [
    [],
    ["--artifact-run", "123", "--artifact-source", source],
    ...["-1", "3", "0.5", "00", "unknown"].map((chunk) => [
      "--artifact-run",
      "123",
      "--artifact-source",
      source,
      "--chunk",
      chunk,
    ]),
    [
      "--artifact-run",
      "123",
      "--artifact-source",
      source,
      "--chunk",
      "0",
      "--skip",
    ],
    ["--artifact-run", "../123", "--artifact-source", source],
    ["--artifact-source", source, "--artifact-run", "123"],
    ["--artifact-run", "123", "--artifact-source", "bad"],
    ["--artifact-run", "123", "--artifact-source", source, "--skip"],
  ])
    expect(() => parseManagedExecutionArguments(args)).toThrow();
  expect(() => admitManagedExecution(environment, source)).not.toThrow();
  for (const key of Object.keys(environment))
    expect(() =>
      admitManagedExecution({ ...environment, [key]: "other" }, source),
    ).toThrow();
});

test("application environment omits ambient credentials and never inherits account HOME", () => {
  const fixture = {
    directory: "/synthetic/fixture",
    app: "/synthetic/fixture/Fixture.app",
    fixtureHome: "/synthetic/fixture/music-home",
    extensionID: "music",
    identifier:
      "com.pulkit.edith.tests.worker-00000000-0000-4000-8000-000000000001",
    sourceCommit: source,
    token: "do-not-copy",
    SSH_AUTH_SOCK: "do-not-copy",
  };
  const value = managedApplicationEnvironment(fixture, {
    ...environment,
    HOME: "/foreign/account",
    CFFIXED_USER_HOME: "/foreign/preferences",
    TMPDIR: "/foreign/tmp",
    GITHUB_TOKEN: "synthetic-secret",
    SSH_AUTH_SOCK: "synthetic-agent",
  });
  expect(value.HOME).toBe(fixture.fixtureHome);
  expect(value.CFFIXED_USER_HOME).toBe(fixture.fixtureHome);
  expect(value.TMPDIR).toBe("/synthetic/fixture/tmp");
  expect(value.XDG_CONFIG_HOME).toBe(`${fixture.fixtureHome}/.config`);
  expect(value.XDG_CACHE_HOME).toBe(`${fixture.fixtureHome}/.cache`);
  expect(value).not.toHaveProperty("GITHUB_TOKEN");
  expect(value.EDITH_SHARED_DEFAULTS_SUITE).toBe(fixture.identifier);
  expect(value).not.toHaveProperty("token");
  expect(value).not.toHaveProperty("SSH_AUTH_SOCK");
  expect(() =>
    managedApplicationEnvironment(
      {
        ...fixture,
        fixtureHome: "/Users/account",
      },
      environment,
    ),
  ).toThrow();
});

test("all39 aggregation refuses missing views, stale archives, failed drain and fabricated functional coverage", async () => {
  const review = JSON.parse(
    await readFile(
      new URL("../Tests/HostedManagedViews/routes.json", import.meta.url),
    ),
  );
  const fixtures = review.owners.map(({ id }) => ({
    extensionID: id,
    package: {
      version: "1.0.0",
      hostABI: "edith-host-2",
      sha256: "b".repeat(64),
    },
    sourceCommit: source,
    originalSourceCommit: "c".repeat(40),
    originalZipSHA256: "d".repeat(64),
  }));
  const results = review.owners.map((owner) => ({
    extensionID: owner.id,
    fixtureZipSHA256: "b".repeat(64),
    originalZipSHA256: "d".repeat(64),
    fixtureSourceCommit: source,
    originalSourceCommit: "c".repeat(40),
    nativePayloadScope:
      "Payload/<id>/<role>.bundle only, excluding signatures and all Host executable carriers",
    hostCarrierTransformationVerified: true,
    proof: {
      schema: 1,
      outcome: "passed",
      extensionID: owner.id,
      selectedVersion: "1.0.0",
      hostABI: "edith-host-2",
      location: owner.location,
      section: owner.section,
      factoryOverlay: owner.factoryOverlay,
      functionalActionsValidated: false,
      visible: false,
      productionExecutableUnchangedProof: false,
      managedNativeViewValidated: true,
      publicCarrierCheckIn: true,
      freshSceneGeneration: true,
      lastCloseExited: true,
      disableExitedBothRoles: true,
      packageLeaseReleased: true,
      noVisibleWindows: true,
      disabledProcesses: 0,
      presentations: 2,
      featurePayloadUnchanged: !owner.factoryOverlay,
    },
  }));
  const aggregate = validateManagedExecutionResults(results, review, fixtures);
  expect(aggregate.owners).toBe(39);
  expect(aggregate.functionalActionsValidated).toBe(false);
  for (const change of [
    (rows) => rows.pop(),
    (rows) => {
      rows[0].proof.disabledProcesses = 1;
    },
    (rows) => {
      rows[0].proof.functionalActionsValidated = true;
    },
    (rows) => {
      rows[0].originalZipSHA256 = "e".repeat(64);
    },
    (rows) => {
      rows[0].extensionID = rows[1].extensionID;
    },
  ]) {
    const rows = structuredClone(results);
    change(rows);
    expect(() =>
      validateManagedExecutionResults(rows, review, fixtures),
    ).toThrow();
  }
});

test("artifact authentication captures its credential without exposing it to compiler environments", async () => {
  const variables = { ...environment, GITHUB_TOKEN: "synthetic-credential" };
  const requests = [];
  const authenticated = managedAuthenticatedFetch(
    variables,
    async (url, init) => {
      requests.push({ url, init });
      return "synthetic-result";
    },
  );
  expect(variables).not.toHaveProperty("GITHUB_TOKEN");
  const compilerEnvironment = { ...variables, EXTENSION_SWIFT_JOBS: "1" };
  expect(compilerEnvironment).not.toHaveProperty("GITHUB_TOKEN");
  expect(
    await authenticated(
      "https://api.github.com/repos/pulkitxm/edith/actions/runs/42",
      { headers: { Accept: "application/json" } },
    ),
  ).toBe("synthetic-result");
  expect(requests[0].init.headers.Authorization).toBe(
    "Bearer synthetic-credential",
  );
  expect(requests[0].init.headers.Accept).toBe("application/json");
  expect(() => authenticated("https://foreign.invalid/asset")).toThrow();
  expect(requests).toHaveLength(1);
  expect(() => managedAuthenticatedFetch({}, async () => {})).toThrow();
});
