import { expect, test } from "bun:test";
import { readFile } from "node:fs/promises";

const ci = await readFile(".github/workflows/ci.yml", "utf8");
const workflow = await readFile(
  ".github/workflows/hosted-managed-views.yml",
  "utf8",
);
const route = ci.split("  hosted-managed-views:\n")[1].split("  changes:\n")[0];
const routeAllows = new Function(
  "github",
  "inputs",
  `return Boolean(${route.match(/ {4}if: ([^\n]+)/)[1]})`,
);
const calledAllows = new Function(
  "github",
  "inputs",
  `return Boolean(${workflow.match(/ {4}if: ([^\n]+)/)[1]})`,
);
const github = {
  repository: "pulkitxm/edith",
  event_name: "workflow_dispatch",
  actor_id: "65671483",
  ref: "refs/heads/feat/hosted-managed-view-execution",
  sha: "a".repeat(40),
};
const inputs = {
  hosted_sparkle_update_sha: "",
  hosted_managed_views_sha: github.sha,
  hosted_managed_artifacts_run: "42",
  hosted_managed_artifacts_sha: "b".repeat(40),
  hosted_shell_journey_sha: "",
  hosted_host_tests_sha: "",
  expected_sha: github.sha,
  artifact_run: "42",
  artifact_source: "b".repeat(40),
  release: false,
  rebuild: "",
};
test("hosted managed route requires exact reviewed source, closed actor refs and independent original CI inputs", () => {
  for (const ref of [
    "refs/heads/main",
    "refs/heads/feat/extension-marketplace",
    github.ref,
  ]) {
    expect(routeAllows({ ...github, ref }, inputs)).toBe(true);
    expect(calledAllows({ ...github, ref }, inputs)).toBe(true);
  }
  for (const changed of [
    { actor_id: "foreign" },
    { repository: "foreign/repository" },
    { event_name: "pull_request" },
    { ref: "refs/heads/other" },
    { sha: "c".repeat(40) },
  ]) {
    expect(routeAllows({ ...github, ...changed }, inputs)).toBe(false);
    expect(calledAllows({ ...github, ...changed }, inputs)).toBe(false);
  }
  for (const changed of [
    { release: true },
    { rebuild: "v1" },
    { hosted_managed_views_sha: "" },
    { hosted_managed_artifacts_run: "" },
    { hosted_managed_artifacts_sha: "" },
    { hosted_shell_journey_sha: github.sha },
    { hosted_host_tests_sha: github.sha },
  ])
    expect(routeAllows(github, { ...inputs, ...changed })).toBe(false);
  for (const changed of [
    { release: true },
    { rebuild: "v1" },
    { artifact_run: "" },
    { artifact_source: "" },
    { expected_sha: "c".repeat(40) },
  ])
    expect(calledAllows(github, { ...inputs, ...changed })).toBe(false);
  expect(workflow).toContain(`ref: "\${{ github.sha }}"`);
  expect(workflow).toContain("actions: read");
  expect(workflow).not.toContain("contents: write");
  expect(workflow).not.toContain("*.xcresult");
});
test("managed request excludes ordinary builds and other hosted fixtures rather than accidentally publishing", () => {
  for (const name of ["hosted-host-tests", "hosted-original-shell"]) {
    const expression = ci.split(`  ${name}:\n`)[1].match(/ {4}if: ([^\n]+)/)[1];
    const allows = new Function(
      "github",
      "inputs",
      `return Boolean(${expression})`,
    );
    const prior = {
      ...inputs,
      hosted_sparkle_update_sha: "",
      public_release_validation_sha: "",
      public_release_validation: "",
      hosted_host_tests_sha: github.sha,
      hosted_shell_journey_sha: "",
      hosted_managed_views_sha: "",
      hosted_managed_artifacts_run: "",
      hosted_managed_artifacts_sha: "",
    };
    expect(
      allows(
        { ...github, ref: "refs/heads/main" },
        { ...prior, hosted_managed_views_sha: github.sha },
      ),
    ).toBe(false);
    expect(
      allows(
        { ...github, ref: "refs/heads/main" },
        { ...prior, hosted_managed_artifacts_run: "42" },
      ),
    ).toBe(false);
  }
  const change = ci.split("  changes:\n")[1].split("    runs-on:")[0];
  expect(change).toContain("inputs.hosted_managed_views_sha != ''");
  expect(change).toContain("inputs.hosted_managed_artifacts_run != ''");
  expect(change).toContain("inputs.hosted_managed_artifacts_sha != ''");
});

test("managed chunks retain every gate and only always aggregate can claim complete39", () => {
  expect(workflow).toContain("fail-fast: false");
  expect(workflow).toContain("scripts/test-hosted-managed-chunk-artifact.py");
  expect(workflow).toContain("scripts/hosted-managed-chunk-intake.test.js");
  expect(workflow).toContain("max-parallel: 3");
  expect(workflow).toContain("chunk: [0, 1, 2]");
  expect(workflow).toContain('--chunk "$MANAGED_CHUNK"');
  expect(workflow).toContain(
    `hosted-managed-original-view-chunk-\${{ matrix.chunk }}`,
  );
  expect(workflow).toContain(
    "path: local/hosted-managed-execution/result.json",
  );
  const aggregate = workflow.split("  aggregate:\n")[1];
  expect(aggregate).toContain("needs: original-views");
  const expression = aggregate.match(/ {4}if: ([^\n]+)/)[1];
  expect(expression.startsWith("always() && ")).toBe(true);
  const allows = new Function(
    "github",
    "inputs",
    "always",
    `return Boolean(${expression})`,
  );
  expect(allows(github, inputs, () => true)).toBe(true);
  for (const changed of [
    { actor_id: "foreign" },
    { repository: "foreign/repository" },
    { event_name: "pull_request" },
    { ref: "refs/heads/other" },
    { sha: "c".repeat(40) },
  ])
    expect(allows({ ...github, ...changed }, inputs, () => true)).toBe(false);
  for (const changed of [
    { release: true },
    { rebuild: "all" },
    { expected_sha: "c".repeat(40) },
    { artifact_run: "" },
    { artifact_source: "" },
  ])
    expect(allows(github, { ...inputs, ...changed }, () => true)).toBe(false);
  expect(aggregate).toContain("hosted-managed-views/aggregate-managed.mjs");
  expect(aggregate).not.toContain("MACOS_CERT");
  expect(aggregate).not.toContain("run-managed.mjs");
});

test("fixture Host receipt retention follows the actual builder output and runtime reader", async () => {
  const builder = await readFile(
    "scripts/hosted-managed-views/build-host.mjs",
    "utf8",
  );
  const runner = await readFile(
    "scripts/hosted-managed-views/run-managed.mjs",
    "utf8",
  );
  const directory = builder.match(/const output = join\(root, "([^"]+)"\);/)[1];
  expect(builder).toContain('join(output, "host-build-receipt.json")');
  const receipt = `${directory}/host-build-receipt.json`;
  expect(runner).toContain(`join(root, "${receipt}")`);
  expect(workflow).toContain(`path: ${receipt}`);
  expect(workflow).not.toContain("local/hosted-managed-build");
});
