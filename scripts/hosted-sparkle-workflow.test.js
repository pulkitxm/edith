import { expect, test } from "bun:test";
import { readFile } from "node:fs/promises";

const ci = await readFile(".github/workflows/ci.yml", "utf8");
const workflow = await readFile(
  ".github/workflows/hosted-sparkle-update.yml",
  "utf8",
);
const route = ci
  .split("  hosted-sparkle-update:\n")[1]
  .split("  changes:\n")[0];
const predicate = (source) =>
  new Function(
    "github",
    "inputs",
    `return Boolean(${source.match(/ {4}if: ([^\n]+)/)[1]})`,
  );
const routeAllows = predicate(route);
const calledAllows = predicate(workflow);
const github = {
  repository: "pulkitxm/edith",
  event_name: "workflow_dispatch",
  actor_id: "65671483",
  ref: "refs/heads/feat/hosted-sparkle-verification",
  sha: "a".repeat(40),
};
const inputs = {
  hosted_sparkle_update_sha: github.sha,
  expected_sha: github.sha,
  hosted_host_tests_sha: "",
  hosted_shell_journey_sha: "",
  hosted_managed_views_sha: "",
  hosted_managed_artifacts_run: "",
  hosted_managed_artifacts_sha: "",
  public_release_validation_sha: "",
  public_release_validation: "",
  release: false,
  rebuild: "",
};

test("only exact reviewed hosted source actors and nonpublishing refs can run the standard updater", () => {
  for (const ref of [
    github.ref,
    "refs/heads/feat/hosted-sparkle-ui-flow",
    "refs/heads/main",
    "refs/heads/feat/extension-marketplace",
  ]) {
    expect(routeAllows({ ...github, ref }, inputs)).toBe(true);
    expect(calledAllows({ ...github, ref }, inputs)).toBe(true);
  }
  for (const changed of [
    { repository: "foreign/repo" },
    { event_name: "pull_request" },
    { actor_id: "foreign" },
    { ref: "refs/heads/foreign" },
    { sha: "b".repeat(40) },
  ]) {
    expect(routeAllows({ ...github, ...changed }, inputs)).toBe(false);
    expect(calledAllows({ ...github, ...changed }, inputs)).toBe(false);
  }
  for (const changed of [{ release: true }, { rebuild: "v1" }]) {
    expect(routeAllows(github, { ...inputs, ...changed })).toBe(false);
    expect(calledAllows(github, { ...inputs, ...changed })).toBe(false);
  }
  expect(
    routeAllows(github, { ...inputs, hosted_sparkle_update_sha: "" }),
  ).toBe(false);
  expect(
    calledAllows(github, { ...inputs, expected_sha: "b".repeat(40) }),
  ).toBe(false);
});

test("all other hosted and public requests are mutually exclusive and normal CI cannot run a fixture request", () => {
  for (const key of [
    "hosted_host_tests_sha",
    "hosted_shell_journey_sha",
    "hosted_managed_views_sha",
    "hosted_managed_artifacts_run",
    "hosted_managed_artifacts_sha",
    "public_release_validation_sha",
    "public_release_validation",
  ])
    expect(routeAllows(github, { ...inputs, [key]: "foreign" })).toBe(false);
  for (const name of [
    "hosted-host-tests",
    "hosted-original-shell",
    "hosted-managed-views",
  ]) {
    const allows = predicate(ci.split(`  ${name}:\n`)[1]);
    expect(
      allows(
        { ...github, ref: "refs/heads/main" },
        {
          ...inputs,
          hosted_host_tests_sha: github.sha,
          hosted_shell_journey_sha: github.sha,
          hosted_managed_views_sha: github.sha,
          hosted_managed_artifacts_run: "42",
          hosted_managed_artifacts_sha: github.sha,
        },
      ),
    ).toBe(false);
  }
  const changes = ci.split("  changes:\n")[1].split("    runs-on:")[0];
  expect(changes).toContain("inputs.hosted_sparkle_update_sha != ''");
  expect(changes).toContain("inputs.public_release_validation_sha != ''");
  expect(changes).toContain("inputs.public_release_validation != ''");
});

test("the workflow pins tool and source before actual updater work and retains only bounded synthetic results", () => {
  expect(workflow).toContain(`ref: "\${{ github.sha }}"`);
  expect(workflow).toContain("persist-credentials: false");
  expect(workflow).toContain("contents: read");
  expect(workflow).not.toContain("contents: write");
  const setup = "oven-sh/setup-bun@0c5077e51419868618aeaa5fe8019c62421857d6";
  expect(workflow).toContain(setup);
  expect(workflow).toContain("bun-version: 1.4.2");
  expect(workflow.indexOf(setup)).toBeLessThan(
    workflow.indexOf("run: bun scripts/hosted-sparkle-update/run-update.mjs"),
  );
  expect(workflow).toContain("bun scripts/hosted-host-manifest-cold.mjs");
  expect(workflow).toContain(
    "swift test --package-path Tests/HostedSparkleUpdate --jobs 1",
  );
  const uploads = workflow
    .split("      - name: Retain bounded synthetic update outcomes")[1]
    .split("      - name: Remove the owned")[0];
  expect(uploads).toContain("if: always()");
  expect(uploads).toContain("if: success()");
  expect(uploads).toContain("case-*/result.json");
  expect(uploads).toContain("case-*/build-receipt.json");
  for (const name of [
    "marketplace-installed-calendar.png",
    "storage-distribution.png",
  ])
    expect(uploads).toContain(`local/hosted-sparkle-update/${name}`);
  for (const forbidden of [
    "*.xcresult",
    "sparkle-bootstrap",
    ".p12",
    "privateKey",
    "operator.token",
    "DerivedData",
    "sparkle-update.zip",
  ])
    expect(uploads).not.toContain(forbidden);
});
