import assert from "node:assert/strict";
import { join, resolve } from "node:path";
import { validateManagedViewProof } from "./contract.mjs";

const reviewedRefs = new Set([
  "refs/heads/feat/hosted-managed-view-execution",
  "refs/heads/feat/extension-marketplace",
  "refs/heads/main",
]);
const sha = /^[a-f0-9]{40}$/;

export function managedAuthenticatedFetch(environment, fetch_) {
  const token = environment.GITHUB_TOKEN;
  assert(typeof token === "string" && token.length > 0);
  delete environment.GITHUB_TOKEN;
  return (url, init = {}) => {
    assert.equal(new URL(url).origin, "https://api.github.com");
    return fetch_(url, {
      ...init,
      headers: { ...init.headers, Authorization: `Bearer ${token}` },
    });
  };
}

export function parseManagedExecutionArguments(args) {
  assert.equal(args.length, 4);
  assert.equal(args[0], "--artifact-run");
  assert.equal(args[2], "--artifact-source");
  assert.match(args[1], /^[1-9][0-9]{0,15}$/);
  const runID = Number(args[1]);
  assert(Number.isSafeInteger(runID));
  assert.match(args[3], sha);
  return { runID, artifactSource: args[3] };
}

export function admitManagedExecution(environment, sourceCommit) {
  assert.equal(environment.GITHUB_ACTIONS, "true");
  assert.equal(environment.RUNNER_OS, "macOS");
  assert.equal(environment.RUNNER_ENVIRONMENT, "github-hosted");
  assert.equal(environment.GITHUB_REPOSITORY, "pulkitxm/edith");
  assert(["65671483", "320458784"].includes(environment.GITHUB_ACTOR_ID));
  assert.equal(environment.GITHUB_EVENT_NAME, "workflow_dispatch");
  assert(reviewedRefs.has(environment.GITHUB_REF));
  assert.match(sourceCommit, sha);
  assert.equal(environment.GITHUB_SHA, sourceCommit);
  assert.equal(environment.EXPECTED_SOURCE_SHA, sourceCommit);
  assert.equal(environment.EDITH_HOSTED_MANAGED_VIEWS, "1");
  assert.equal(environment.PUBLISH, "false");
  assert.equal(environment.REBUILD, "");
}

export function managedApplicationEnvironment(fixture, environment) {
  admitManagedExecution(environment, fixture.sourceCommit);
  assert.equal(resolve(fixture.directory), fixture.directory);
  assert.equal(fixture.app, join(fixture.directory, "Fixture.app"));
  const home = join(
    fixture.directory,
    fixture.extensionID === "calendar"
      ? "synthetic-data"
      : `${fixture.extensionID}-home`,
  );
  assert.equal(fixture.fixtureHome, home);
  assert.match(
    fixture.identifier,
    /^com\.pulkit\.edith\.tests\.(worker|remote)-[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/,
  );
  assert.equal(
    fixture.identifier.includes(".remote-"),
    fixture.extensionID === "calendar",
  );
  const hosted = Object.fromEntries(
    [
      "GITHUB_REPOSITORY",
      "GITHUB_ACTOR_ID",
      "GITHUB_EVENT_NAME",
      "GITHUB_REF",
      "GITHUB_SHA",
      "EXPECTED_SOURCE_SHA",
    ].map((key) => [key, environment[key]]),
  );
  return {
    ...hosted,
    HOME: home,
    TMPDIR: join(fixture.directory, "tmp"),
    XDG_CONFIG_HOME: join(home, ".config"),
    XDG_CACHE_HOME: join(home, ".cache"),
    XDG_DATA_HOME: join(home, ".local/share"),
    EDITH_APPLICATION_IDENTIFIER: fixture.identifier,
    EDITH_SHARED_DEFAULTS_SUITE: fixture.identifier,
    EDITH_EXTENSION_FIXTURE_HOME: home,
    EDITH_REMOTE_OFFSCREEN_FIXTURE: "0",
    EDITH_REMOTE_RETAINED_NEGATIVE: "0",
    EDITH_REMOTE_UNCONNECTED_CLEANUP: "0",
    GITHUB_ACTIONS: "true",
    RUNNER_OS: "macOS",
    RUNNER_ENVIRONMENT: "github-hosted",
    EDITH_HOSTED_MANAGED_VIEWS: "1",
  };
}

export function validateManagedExecutionResults(results, review, fixtures) {
  assert.equal(results.length, 39);
  assert.equal(fixtures.length, 39);
  assert.equal(review.owners.length, 39);
  const ids = review.owners.map(({ id }) => id).sort();
  assert.equal(new Set(ids).size, 39);
  assert.deepEqual(results.map(({ extensionID }) => extensionID).sort(), ids);
  assert.deepEqual(fixtures.map(({ extensionID }) => extensionID).sort(), ids);
  validateManagedOwnerResults(results, review.owners, fixtures);
  return {
    schema: 1,
    outcome: "passed",
    owners: 39,
    managedNativeViewSmokeValidated: true,
    functionalActionsValidated: false,
    shippingHostExecutableUnchanged: false,
    factoryOverlayOwners: ["plugins", "studio"],
    originalViewScope:
      "Original managed view creation, close, reopen and disable with isolated inert engines",
    results,
  };
}

export function validateManagedOwnerResults(results, owners, fixtures) {
  const ids = owners.map(({ id }) => id).sort();
  assert.equal(new Set(ids).size, ids.length);
  assert.deepEqual(results.map(({ extensionID }) => extensionID).sort(), ids);
  assert.deepEqual(fixtures.map(({ extensionID }) => extensionID).sort(), ids);
  for (const owner of owners) {
    const result = results.find(({ extensionID }) => extensionID === owner.id);
    const fixture = fixtures.find(
      ({ extensionID }) => extensionID === owner.id,
    );
    assert.equal(result.fixtureZipSHA256, fixture.package.sha256);
    assert.equal(result.originalZipSHA256, fixture.originalZipSHA256);
    assert.equal(result.fixtureSourceCommit, fixture.sourceCommit);
    assert.equal(result.originalSourceCommit, fixture.originalSourceCommit);
    assert.equal(
      result.nativePayloadScope,
      "Payload/<id>/<role>.bundle only, excluding signatures and all Host executable carriers",
    );
    assert.equal(result.hostCarrierTransformationVerified, true);
    validateManagedViewProof(result.proof, owner, fixture.package);
  }
}
