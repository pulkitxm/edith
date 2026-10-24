import assert from "node:assert/strict";

export const managedNativeBuildSteps = [
  "Verify lifecycle tools and their frozen index",
  "Require a native worker package",
  "Test this extension's optional native packages",
  "Exercise this worker against the frozen host",
  "Build only this extension",
];
export const managedNativeTestSteps = [
  "Verify lifecycle tools and their frozen index",
  "Verify native cache integrity and private SDK composition",
  "Run make ci-marketplace-runtime ci-extension-support ci-extension-docs ci-extension-commands ci-comments",
  "Run bun scripts/test-extension-catalog-retention.mjs",
  "Run bun scripts/test-extension-marketplace.mjs",
];

export const shippingNativeTestSteps = [
  "Verify lifecycle tools and their frozen index",
  "Validate the shipping extension and marketplace",
  "Run bun scripts/test-extension-catalog-retention.mjs",
  "Run bun scripts/test-extension-marketplace.mjs",
  "Verify bounded peer failure diagnostics",
  "Verify authenticated peer transport and lifecycle",
  "Exercise original Keep Awake controls and native lifecycle",
  "Verify Keep Awake peer rejection contracts",
];

export function validateNonpublishingNativeJobs(jobs, definitions, runID) {
  assert.equal(definitions.length, 40);
  assert.equal(new Set(definitions.map(({ id }) => id)).size, 40);
  assert.equal(jobs.length, 44);
  assert.equal(new Set(jobs.map(({ id }) => id)).size, 44);
  assert.deepEqual(
    jobs.map(({ name }) => name).sort(),
    [
      "plan",
      "frozen-host",
      "tests",
      "publish",
      ...definitions.map(({ id }) => `build (${id})`),
    ].sort(),
  );
  for (const job of jobs) {
    assert(Number.isSafeInteger(job.id) && job.id > 0);
    assert.equal(job.run_id, runID);
    assert.equal(job.status, "completed");
    assert.equal(
      job.conclusion,
      job.name === "publish" ? "skipped" : "success",
    );
    const names =
      job.name === "tests"
        ? managedNativeTestSteps
        : job.name.startsWith("build (")
          ? managedNativeBuildSteps
          : [];
    for (const name of names) {
      const matches = job.steps.filter((step) => step.name === name);
      assert.equal(
        matches.length,
        1,
        `Expected actual required native step: ${job.name}/${name}`,
      );
      assert.equal(matches[0].status, "completed");
      assert.equal(matches[0].conclusion, "success");
    }
  }
}
