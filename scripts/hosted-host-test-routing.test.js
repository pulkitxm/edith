import { expect, test } from "bun:test";
import { execFileSync } from "node:child_process";
import { readFile } from "node:fs/promises";

const ci = await readFile(".github/workflows/ci.yml", "utf8");
const diagnostic = await readFile(
  ".github/workflows/hosted-host-test-diagnostics.yml",
  "utf8",
);

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
    hosted_host_tests_sha: github.sha,
    hosted_shell_journey_sha: "",
    expected_sha: github.sha,
    release: false,
    rebuild: "",
  };
  for (const ref of [
    "refs/heads/main",
    "refs/heads/feat/extension-marketplace",
    "refs/heads/feat/hosted-host-test-diagnostics",
  ]) {
    for (const actor of ["65671483", "320458784"]) {
      expect(routeAllows({ ...github, ref, actor_id: actor }, inputs)).toBe(
        true,
      );
      expect(calledAllows({ ...github, ref, actor_id: actor }, inputs)).toBe(
        true,
      );
    }
  }
  for (const changed of [
    { ref: "refs/heads/other" },
    { ref: "refs/tags/main" },
    { ref: "refs/pull/1220/merge" },
    { actor_id: "999" },
    { repository: "other/edith" },
    { event_name: "pull_request" },
    { sha: "b".repeat(40) },
  ]) {
    expect(routeAllows({ ...github, ...changed }, inputs)).toBe(false);
    expect(calledAllows({ ...github, ...changed }, inputs)).toBe(false);
  }
  for (const changed of [{ release: true }, { rebuild: "v1.0.0" }]) {
    expect(routeAllows(github, { ...inputs, ...changed })).toBe(false);
    expect(calledAllows(github, { ...inputs, ...changed })).toBe(false);
  }
  expect(
    routeAllows(github, { ...inputs, hosted_shell_journey_sha: github.sha }),
  ).toBe(false);
  expect(routeAllows(github, { ...inputs, hosted_host_tests_sha: "" })).toBe(
    false,
  );
  expect(calledAllows(github, { ...inputs, expected_sha: "" })).toBe(false);
  expect(route).toContain(`release: \${{ inputs.release }}`);
  expect(route).toContain(`rebuild: \${{ inputs.rebuild }}`);
  expect(diagnostic).toContain(
    `EDITH_HOSTED_RELEASE: "\${{ inputs.release }}"`,
  );
  expect(diagnostic).toContain(
    `EDITH_HOSTED_REBUILD: "\${{ inputs.rebuild }}"`,
  );
});

test("original journey remains callable at reviewed final refs without changing synthetic fixture admission", async () => {
  const workflow = await readFile(
    ".github/workflows/hosted-original-shell.yml",
    "utf8",
  );
  const route = ci
    .split("  hosted-original-shell:\n")[1]
    .split("  changes:\n")[0];
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
    event_name: "workflow_dispatch",
    repository: "pulkitxm/edith",
    actor_id: "65671483",
    ref: "refs/heads/main",
    sha: "a".repeat(40),
  };
  const inputs = {
    hosted_shell_journey_sha: github.sha,
    hosted_host_tests_sha: "",
    expected_sha: github.sha,
    release: false,
    rebuild: "",
  };
  for (const ref of [
    "refs/heads/main",
    "refs/heads/feat/extension-marketplace",
    "refs/heads/feat/hosted-original-shell-journey",
    "refs/heads/feat/hosted-host-test-diagnostics",
  ]) {
    for (const actor of ["65671483", "320458784"]) {
      expect(routeAllows({ ...github, ref, actor_id: actor }, inputs)).toBe(
        true,
      );
      expect(calledAllows({ ...github, ref, actor_id: actor }, inputs)).toBe(
        true,
      );
    }
  }
  for (const changed of [
    { ref: "refs/heads/other" },
    { ref: "refs/tags/main" },
    { ref: "refs/pull/1220/merge" },
    { actor_id: "999" },
    { repository: "other/edith" },
    { event_name: "push" },
    { sha: "b".repeat(40) },
  ]) {
    expect(routeAllows({ ...github, ...changed }, inputs)).toBe(false);
    expect(calledAllows({ ...github, ...changed }, inputs)).toBe(false);
  }
  for (const changed of [{ release: true }, { rebuild: "v1.0.0" }]) {
    expect(routeAllows(github, { ...inputs, ...changed })).toBe(false);
    expect(calledAllows(github, { ...inputs, ...changed })).toBe(false);
  }
  expect(
    routeAllows(github, { ...inputs, hosted_host_tests_sha: github.sha }),
  ).toBe(false);
  expect(routeAllows(github, { ...inputs, hosted_shell_journey_sha: "" })).toBe(
    false,
  );
  expect(calledAllows(github, { ...inputs, expected_sha: "" })).toBe(false);
  expect(route).toContain(`release: \${{ inputs.release }}`);
  expect(route).toContain(`rebuild: \${{ inputs.rebuild }}`);
  for (const guard of [
    'test "$EDITH_HOSTED_RELEASE" = false',
    'test -z "$EDITH_HOSTED_REBUILD"',
    'test "$RUNNER_ENVIRONMENT" = github-hosted',
    'test "$RUNNER_OS" = macOS',
    'test "$(git rev-parse HEAD)" = "$EXPECTED_SOURCE_SHA"',
  ])
    expect(workflow).toContain(guard);
});
