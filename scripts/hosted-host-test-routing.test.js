import { expect, test } from "bun:test";
import { execFileSync } from "node:child_process";
import { readFile } from "node:fs/promises";

const ci = await readFile(".github/workflows/ci.yml", "utf8");
const diagnostic = await readFile(
  ".github/workflows/hosted-host-test-diagnostics.yml",
  "utf8",
);

test("hosted Marketplace fixtures receive the same pinned Bun setup as normal CI before execution", () => {
  const steps = diagnostic
    .split("    steps:\n")[1]
    .split(/^ {6}- /m)
    .slice(1);
  const setup =
    "uses: oven-sh/setup-bun@0c5077e51419868618aeaa5fe8019c62421857d6";
  const setupSteps = steps.filter((step) => step.startsWith(setup));
  expect(setupSteps).toHaveLength(1);
  const normalBuild = ci
    .split("  swift-build:\n")[1]
    .split("  swift-test:\n")[0];
  expect(normalBuild).toContain(setup);
  const setupIndex = steps.indexOf(setupSteps[0]);
  const coreIndex = steps.findIndex((step) =>
    step.includes("run: python3 scripts/hosted-host-tests/watchdog.py"),
  );
  const marketplaceIndex = steps.findIndex((step) =>
    step.includes("run: make ci-marketplace-runtime-diagnostics"),
  );
  expect(coreIndex).toBeGreaterThan(setupIndex);
  expect(marketplaceIndex).toBeGreaterThan(coreIndex);
});

test("reviewed diagnostic uses the established dispatch workflow and exact immutable source", () => {
  expect(ci).toContain("hosted_host_tests_sha:");
  const route = ci
    .split("  hosted-host-tests:\n")[1]
    .split("  hosted-original-shell:\n")[0];
  for (const predicate of [
    "github.event_name == 'workflow_dispatch'",
    "inputs.hosted_host_tests_sha != ''",
    "inputs.hosted_shell_journey_sha == ''",
    "!inputs.release",
    "inputs.rebuild == ''",
    "github.repository == 'pulkitxm/edith'",
    "github.actor_id == '65671483'",
    "github.actor_id == '320458784'",
    "github.ref == 'refs/heads/feat/hosted-host-test-diagnostics'",
    "inputs.hosted_host_tests_sha == github.sha",
  ])
    expect(route).toContain(predicate);
  expect(route).toContain(
    "uses: ./.github/workflows/hosted-host-test-diagnostics.yml",
  );
  expect(route).toContain(`expected_sha: \${{ inputs.hosted_host_tests_sha }}`);
  expect(diagnostic).toContain("workflow_call:");
  expect(diagnostic).toContain(`ref: "\${{ github.sha }}"`);
  expect(diagnostic).toContain(
    `EXPECTED_SOURCE_SHA: "\${{ inputs.expected_sha }}"`,
  );
});

test("dedicated reviewed routes do not start normal CI or both fixture jobs", () => {
  const changes = ci.split("  changes:\n")[1].split("    runs-on:")[0];
  expect(changes).toContain(
    "inputs.hosted_shell_journey_sha != '' || inputs.hosted_host_tests_sha != ''",
  );
  const journey = ci
    .split("  hosted-original-shell:\n")[1]
    .split("  changes:\n")[0];
  expect(journey).toContain("inputs.hosted_host_tests_sha == ''");
  expect(diagnostic).not.toContain("secrets:");
  expect(diagnostic).toContain("permissions:\n  contents: read");
});

test("normal script CI executes pure watchdog ownership and deadline tests without native launches", () => {
  const output = execFileSync(
    "python3",
    [
      "-B",
      "-m",
      "unittest",
      "discover",
      "-s",
      "scripts/hosted-host-tests",
      "-p",
      "test_*.py",
    ],
    { encoding: "utf8", timeout: 10000, stdio: ["ignore", "pipe", "pipe"] },
  );
  expect(output).toBe("");
});

test("maintained diagnostics admit only reviewed nonpublishing owner refs and immutable source", () => {
  const route = ci
    .split("  hosted-host-tests:\n")[1]
    .split("  hosted-original-shell:\n")[0];
  const routeExpression = route.match(/ {4}if: ([^\n]+)/)[1];
  const calledExpression = diagnostic.match(/ {4}if: ([^\n]+)/)[1];
  const routeAllows = new Function(
    "github",
    "inputs",
    `return Boolean(${routeExpression})`,
  );
  const calledAllows = new Function(
    "github",
    "inputs",
    `return Boolean(${calledExpression})`,
  );
  const github = {
    event_name: "workflow_dispatch",
    repository: "pulkitxm/edith",
    actor_id: "65671483",
    ref: "refs/heads/main",
    sha: "a".repeat(40),
  };
  const inputs = {
    hosted_sparkle_update_sha: "",
    public_release_validation_sha: "",
    public_release_validation: "",
