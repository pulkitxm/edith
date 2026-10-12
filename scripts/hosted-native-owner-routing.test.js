import { expect, test } from "bun:test";
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";

const ci = Bun.YAML.parse(readFileSync(".github/workflows/ci.yml", "utf8"));
const workflow = Bun.YAML.parse(readFileSync(".github/workflows/hosted-native-owner-tests.yml", "utf8"));
const github = {
  event_name: "workflow_dispatch",
  repository: "pulkitxm/edith",
  repository_id: "1289153439",
  actor_id: "65671483",
  ref: "refs/heads/feat/extension-marketplace",
  sha: "a".repeat(40),
};
const defaults = Object.fromEntries(Object.entries(ci.on.workflow_dispatch.inputs).map(([key, value]) => [key, value.default]));
const inputs = { ...defaults, hosted_native_owner_tests_sha: github.sha, hosted_native_owner: "attention" };
const allows = new Function("github", "inputs", `return Boolean(${ci.jobs["hosted-native-owner-tests"].if})`);
const owners = ["attention", "terminal", "timeLapse", "studio", "machines", "virtualCamera", "feature-models"];

test("original native admission, target selection, timeout and owned retirement pure contracts pass", () => {
  expect(execFileSync("python3", ["-B", "scripts/test-hosted-native-owner-tests.py"], { encoding: "utf8", timeout: 10000, stdio: ["ignore", "pipe", "pipe"] })).toBe("");
});

test("all fixed owners require exact approved source and reject conflicting dispatches", () => {
  for (const owner of owners) expect(allows(github, { ...inputs, hosted_native_owner: owner })).toBe(true);
  for (const [key, value] of Object.entries(defaults)) {
    if (key === "hosted_native_owner_tests_sha" || key === "hosted_native_owner") continue;
    expect(allows(github, { ...inputs, [key]: typeof value === "boolean" ? true : "conflicting" })).toBe(false);
  }
  for (const changed of [{ event_name: "pull_request" }, { repository: "other/edith" }, { repository_id: "999" }, { actor_id: "999" }, { ref: "refs/heads/other" }, { sha: "b".repeat(40) }]) expect(allows({ ...github, ...changed }, inputs)).toBe(false);
  for (const owner of ["", "other", "attention --skip-test"]) expect(allows(github, { ...inputs, hosted_native_owner: owner })).toBe(false);
  expect(allows(github, { ...inputs, hosted_native_owner_tests_sha: "" })).toBe(false);
});

test("both native input fields suppress normal CI and every other dedicated route", () => {
  const changes = new Function("github", "inputs", `return Boolean(${ci.jobs.changes.if})`);
  for (const key of ["hosted_native_owner_tests_sha", "hosted_native_owner"]) {
    expect(changes(github, { ...defaults, [key]: "invalid" })).toBe(false);
    for (const name of ["hosted-native-compile", "hosted-host-tests", "hosted-original-shell", "hosted-managed-views", "hosted-sparkle-update", "hosted-public-release-verification"]) expect(ci.jobs[name].if).toContain(`!inputs.${key}`);
  }
  expect(changes(github, defaults)).toBe(true);
});

test("hosted route retains original targets with separate bounded diagnostic overhead", () => {
  const job = workflow.jobs["original-tests"];
  expect(job["runs-on"]).toBe("macos-26");
  expect(job["timeout-minutes"]).toBe(45);
  expect(job.steps[0].with.ref).toBe(`\${{ github.sha }}`);
  expect(job.steps[0].with["persist-credentials"]).toBe(false);
  expect(job.steps.find(step => step.run === "python3 scripts/hosted-native-owner-tests.py")["timeout-minutes"]).toBe(42);
  expect(job.steps.at(-1).if).toBe("always()");
  expect(job.steps.at(-1).with.path).toBe("local/hosted-native-owner-tests/");
  expect(workflow.permissions).toEqual({ contents: "read" });
  expect(workflow).not.toHaveProperty("secrets");
});
