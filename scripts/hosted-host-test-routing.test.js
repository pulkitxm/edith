import { expect, test } from "bun:test";
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
