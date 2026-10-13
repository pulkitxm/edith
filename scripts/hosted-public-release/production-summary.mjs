import assert from "node:assert/strict";
import { constants } from "node:fs";
import { open } from "node:fs/promises";
import { join } from "node:path";
import { boundedProductionFile } from "./production-inputs.mjs";

const stages = [
  "host-A-normal-launch",
  "previous-public-package-enabled",
  "original-UI-and-saved-layout",
  "different-public-host-restoration",
  "public-package-restoration",
  "natural-Sparkle-service-drain",
  "natural-owned-host-engine-UI-drain",
];
export function sanitizeProductionResult(value, source) {
  assert.deepEqual(
    Object.keys(value).sort(),
    [
      "schema",
      "source",
      "application",
      "hostSources",
      "receipts",
      "completed",
      "primaryFailed",
      "cleanupFailed",
      "artifactVerificationExecuted",
      "nativeUIExecuted",
      "productionCompatibilityValidated",
      "publicReleaseValidated",
      "pending",
    ].sort(),
  );
  assert.equal(value.schema, 1);
  assert.equal(value.source, source);
  assert.match(source, /^[a-f0-9]{40}$/);
  assert.equal(value.application, "/Applications/Edith.app");
  assert(Array.isArray(value.hostSources) && value.hostSources.length === 2);
  for (const hash of value.hostSources) assert.match(hash, /^[a-f0-9]{40}$/);
  assert.notEqual(value.hostSources[0], value.hostSources[1]);
  for (const field of [
    "completed",
    "primaryFailed",
    "cleanupFailed",
    "artifactVerificationExecuted",
    "nativeUIExecuted",
  ])
    assert.equal(typeof value[field], "boolean");
  assert.equal(value.productionCompatibilityValidated, false);
  assert.equal(value.publicReleaseValidated, false);
  assert(
    Array.isArray(value.receipts) && value.receipts.length <= stages.length,
  );
  const observed = value.receipts.map((row) => {
    assert.deepEqual(Object.keys(row).sort(), ["observed", "stage"]);
    assert(stages.includes(row.stage));
    return row.stage;
  });
  assert.equal(new Set(observed).size, observed.length);
  if (value.completed) {
    assert.deepEqual(observed, stages);
    assert.equal(value.primaryFailed, false);
    assert.equal(value.cleanupFailed, false);
    assert.equal(value.artifactVerificationExecuted, true);
    assert.equal(value.nativeUIExecuted, true);
  }
  return {
    schema: 1,
    source,
    hostSources: value.hostSources,
    completed: value.completed,
    primaryFailed: value.primaryFailed,
    cleanupFailed: value.cleanupFailed,
    observedStages: observed,
    productionCompatibilityValidated: false,
    publicReleaseValidated: false,
    qualification: "actual-observer-execution-requires-terminal-review",
  };
}
if (import.meta.main) {
  assert.equal(process.argv.length, 2);
  const directory = join(process.cwd(), "local/public-host-cohort");
  let bytes;
  try {
    ({ bytes } = await boundedProductionFile(
      join(directory, "execution-result.json"),
      1024 ** 2,
    ));
  } catch (error) {
    if (error.code !== "ENOENT") throw error;
  }
  if (bytes) {
    const value = sanitizeProductionResult(
      JSON.parse(bytes),
      process.env.EXPECTED_SOURCE_SHA,
    );
    const output = await open(
      join(directory, "summary.json"),
      constants.O_WRONLY |
        constants.O_CREAT |
        constants.O_EXCL |
        constants.O_NOFOLLOW,
      0o600,
    );
    try {
      await output.writeFile(JSON.stringify(value));
      await output.sync();
    } finally {
      await output.close();
    }
  }
}
