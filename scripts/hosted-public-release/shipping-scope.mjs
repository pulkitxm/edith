import assert from "node:assert/strict";
import { hosted, request } from "./contract.mjs";

export function shippingHosted(environment, expectedSHA) {
  hosted(environment, expectedSHA);
  assert.equal(environment.GITHUB_REPOSITORY_ID, "1289153439");
}

export function shippingRequest(value, expectedSHA) {
  const options = request(value);
  assert.equal(options.source, expectedSHA);
  assert.deepEqual(options.updateIDs, ["keepAwake"]);
  assert(Object.keys(options.retainedRuns).every((id) => id === "keepAwake"));
  return options;
}

export function shippingReleaseDefinitions(definitions) {
  assert.equal(definitions.length, 39);
  assert.equal(new Set(definitions.map(({ id }) => id)).size, 39);
  const selected = definitions.filter(({ id }) => id === "keepAwake");
  assert.equal(selected.length, 1);
  assert.deepEqual(selected[0].dependencies, []);
  return selected;
}

export function shippingFingerprints(definitions, fingerprints) {
  assert.deepEqual(
    Object.keys(fingerprints).sort(),
    definitions.map(({ id }) => id).sort(),
  );
  for (const value of Object.values(fingerprints))
    assert.match(value, /^[a-f0-9]{64}$/);
  return Object.fromEntries(
    shippingReleaseDefinitions(definitions).map(({ id }) => [
      id,
      fingerprints[id],
    ]),
  );
}

export function shippingProductionPlan(plan) {
  assert.deepEqual(
    plan.map(({ id }) => id),
    ["keepAwake"],
  );
}

export function shippingUpdateVersions(current, previous) {
  assert.equal(current.length, 1);
  assert.equal(previous.length, 1);
  const latest = current[0];
  const retained = previous[0];
  for (const row of [latest, retained]) {
    assert.equal(row.id, "keepAwake");
    assert.deepEqual(row.dependencies, []);
    assert.match(row.sha256, /^[a-f0-9]{64}$/);
    assert.match(row.sourceFingerprint, /^[a-f0-9]{64}$/);
  }
  assert.equal(latest.version, "1.0.1");
  assert.equal(retained.version, "1.0.0");
  for (const field of ["hostABI", "architecture", "minimumSystemVersion"])
    assert.equal(latest[field], retained[field]);
  assert.equal(latest.architecture, "arm64");
  assert.notEqual(latest.sha256, retained.sha256);
  assert.notEqual(latest.sourceFingerprint, retained.sourceFingerprint);
}
