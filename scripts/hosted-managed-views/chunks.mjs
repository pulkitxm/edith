import assert from "node:assert/strict";
import {
  validateManagedExecutionResults,
  validateManagedOwnerResults,
} from "./execution-contract.mjs";

export const managedChunkCount = 3;

export function managedChunkOwners(owners, chunk) {
  assert(Number.isInteger(chunk) && chunk >= 0 && chunk < managedChunkCount);
  assert.equal(owners.length, 39);
  const sorted = [...owners].sort((a, b) =>
    a.id < b.id ? -1 : a.id > b.id ? 1 : 0,
  );
  assert.equal(new Set(sorted.map(({ id }) => id)).size, 39);
  return sorted.filter((_, index) => index % managedChunkCount === chunk);
}

export function selectManagedArtifactRows(intake, definitions, chunk) {
  const expected = definitions.map(({ id }) => id).sort();
  assert.equal(expected.length, 39);
  assert.equal(new Set(expected).size, 39);
  assert.deepEqual(
    intake.originals.map(({ extensionID }) => extensionID).sort(),
    expected,
  );
  const ids = managedChunkOwners(definitions, chunk).map(({ id }) => id);
  return intake.originals.filter(({ extensionID }) =>
    ids.includes(extensionID),
  );
}

export function validateManagedChunkResults({
  results,
  fixtures,
  review,
  chunk,
  bindings,
}) {
  const owners = managedChunkOwners(review.owners, chunk);
  assert.equal(owners.length, 13);
  validateManagedOwnerResults(results, owners, fixtures);
  validateManagedChunkBindings(bindings);
  for (const fixture of fixtures) {
    assert.equal(fixture.sourceCommit, bindings.fixtureSourceCommit);
    assert.equal(fixture.originalSourceCommit, bindings.originalSourceCommit);
  }
  return {
    schema: 1,
    outcome: "passed",
    chunk,
    owners: 13,
    all39Validated: false,
    functionalActionsValidated: false,
    bindings,
    results,
    fixtures: fixtures.map(
      ({
        extensionID,
        package: package_,
        sourceCommit,
        originalSourceCommit,
        originalZipSHA256,
      }) => ({
        extensionID,
        package: package_,
        sourceCommit,
        originalSourceCommit,
        originalZipSHA256,
      }),
    ),
  };
}

export function validateManagedChunkBindings(bindings) {
  assert.deepEqual(
    Object.keys(bindings).sort(),
    [
      "fixtureSourceCommit",
      "originalSourceCommit",
      "originalCIRun",
      "managedWorkflowRun",
      "reviewSHA256",
      "fingerprintMapSHA256",
      "frozenHostArtifactSHA256",
      "frozenHostExecutableSHA256",
      "originalArtifactSetSHA256",
    ].sort(),
  );
  for (const key of ["fixtureSourceCommit", "originalSourceCommit"])
    assert.match(bindings[key], /^[a-f0-9]{40}$/);
  for (const key of ["originalCIRun", "managedWorkflowRun"])
    assert(Number.isSafeInteger(bindings[key]) && bindings[key] > 0);
  for (const key of [
    "reviewSHA256",
    "fingerprintMapSHA256",
    "frozenHostArtifactSHA256",
    "frozenHostExecutableSHA256",
    "originalArtifactSetSHA256",
  ])
    assert.match(bindings[key], /^[a-f0-9]{64}$/);
}

export function aggregateManagedChunks(chunks, review, bindings) {
  assert.equal(chunks.length, managedChunkCount);
  validateManagedChunkBindings(bindings);
  assert.deepEqual(chunks.map(({ chunk }) => chunk).sort(), [0, 1, 2]);
  const results = [],
    fixtures = [];
  for (const value of chunks) {
    assert.equal(value.schema, 1);
    assert.equal(value.outcome, "passed");
    assert.equal(value.all39Validated, false);
    assert.equal(value.functionalActionsValidated, false);
    assert.equal(value.owners, 13);
    assert.deepEqual(value.bindings, bindings);
    validateManagedChunkResults({ ...value, review });
    results.push(...value.results);
    fixtures.push(...value.fixtures);
  }
  return {
    ...validateManagedExecutionResults(results, review, fixtures),
    bindings,
    chunks: managedChunkCount,
    all39Validated: true,
  };
}
