import { expect, test } from "bun:test";
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";

const ci = Bun.YAML.parse(readFileSync(".github/workflows/ci.yml", "utf8"));
const workflow = Bun.YAML.parse(
  readFileSync(
    ".github/workflows/hosted-native-compile-diagnostics.yml",
    "utf8",
  ),
);
const allows = new Function(
  "github",
  "inputs",
  `return Boolean(${ci.jobs["hosted-native-compile"].if})`,
);
const github = {
  event_name: "workflow_dispatch",
  repository: "pulkitxm/edith",
  actor_id: "65671483",
  ref: "refs/heads/feat/extension-marketplace",
  sha: "a".repeat(40),
};
const inputs = Object.fromEntries(
  Object.entries(ci.on.workflow_dispatch.inputs).map(([key, value]) => [
    key,
    value.default,
  ]),
);
inputs.hosted_native_compile_sha = github.sha;

test("pure compile admission, failure, timeout and crash retention contracts pass without native execution", () => {
  const output = execFileSync(
    "python3",
    ["-B", "scripts/test-hosted-native-compile-diagnostics.py"],
    { encoding: "utf8", timeout: 10000, stdio: ["ignore", "pipe", "pipe"] },
  );
  expect(output).toBe("");
});

test("exact-source native compile route rejects untrusted or conflicting dispatches", () => {
  expect(allows(github, inputs)).toBe(true);
  for (const [key, value] of Object.entries(inputs)) {
    if (key === "hosted_native_compile_sha") continue;
    expect(
      allows(github, {
        ...inputs,
        [key]: typeof value === "boolean" ? true : "conflicting",
      }),
    ).toBe(false);
  }
  for (const changed of [
    { event_name: "pull_request" },
    { repository: "other/edith" },
    { actor_id: "999" },
    { ref: "refs/heads/other" },
    { sha: "b".repeat(40) },
  ])
    expect(allows({ ...github, ...changed }, inputs)).toBe(false);
  expect(allows(github, { ...inputs, hosted_native_compile_sha: "" })).toBe(
    false,
  );
});

test("compile dispatch suppresses normal CI and all other dedicated routes", () => {
  const normal = new Function(
    "github",
    "inputs",
    `return Boolean(${ci.jobs.changes.if})`,
  );
  expect(normal(github, inputs)).toBe(false);
  for (const name of [
    "hosted-host-tests",
    "hosted-original-shell",
    "hosted-managed-views",
    "hosted-sparkle-update",
    "hosted-public-release-verification",
  ])
    expect(ci.jobs[name].if).toContain("!inputs.hosted_native_compile_sha");
});

test("compile workflow checks out immutable source without secrets or product launch steps", () => {
  const job = workflow.jobs["attention-compile"];
  expect(job["runs-on"]).toBe("macos-26");
  expect(job.steps[0].with.ref).toBe(`\${{ github.sha }}`);
  expect(workflow.permissions).toEqual({ contents: "read" });
  expect(job.steps.filter((step) => step.run).map((step) => step.run)).toEqual([
    "python3 scripts/hosted-native-compile-diagnostics.py",
  ]);
  expect(job.steps.at(-1).if).toBe("always()");
  expect(job.steps.at(-1).with.path).toBe("local/hosted-native-compile/");
  expect(workflow).not.toHaveProperty("secrets");
});
