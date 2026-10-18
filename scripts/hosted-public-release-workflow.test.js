import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";

const ci = Bun.YAML.parse(readFileSync(".github/workflows/ci.yml", "utf8"));
const reusable = Bun.YAML.parse(
  readFileSync(
    ".github/workflows/hosted-public-release-verification.yml",
    "utf8",
  ),
);
const route = ci.jobs["hosted-public-release-verification"];
const called = reusable.jobs["public-release"];
const allows = (expression, github, inputs) =>
  new Function("github", "inputs", `return Boolean(${expression})`)(
    github,
    inputs,
  );
const github = {
  repository: "pulkitxm/edith",
  event_name: "workflow_dispatch",
  actor_id: "65671483",
  ref: "refs/heads/main",
  sha: "a".repeat(40),
};
const inputs = {
  public_release_validation_sha: github.sha,
  public_release_validation: "synthetic-request",
  hosted_host_tests_sha: "",
  hosted_shell_journey_sha: "",
  hosted_managed_views_sha: "",
  hosted_managed_artifacts_run: "",
  hosted_managed_artifacts_sha: "",
  hosted_sparkle_update_sha: "",
  release: false,
  rebuild: "",
};

test("the actual public route admits only current main reviewed source and a closed hosted mode", () => {
  expect(allows(route.if, github, inputs)).toBe(true);
  for (const change of [
    { repository: "foreign/repository" },
    { actor_id: "foreign" },
    { event_name: "pull_request" },
    { ref: "refs/heads/feat/extension-marketplace" },
    { sha: "b".repeat(40) },
  ])
    expect(allows(route.if, { ...github, ...change }, inputs)).toBe(false);
  for (const key of Object.keys(inputs)) {
    const value =
      key === "release" ? true : key.startsWith("public_") ? "" : "foreign";
    expect(allows(route.if, github, { ...inputs, [key]: value })).toBe(false);
  }
  expect(route.permissions).toEqual({ contents: "read", actions: "read" });
  expect(route.uses).toBe(
    "./.github/workflows/hosted-public-release-verification.yml",
  );
  expect(route.secrets).toBeUndefined();
});

test("either public input excludes ordinary CI and every existing hosted route", () => {
  const changes = ci.jobs.changes.if.replace(/startsWith\(/g, "startsWith(");
  for (const key of [
    "public_release_validation_sha",
    "public_release_validation",
  ]) {
    const publicInputs = {
      ...inputs,
      public_release_validation_sha: "",
      public_release_validation: "",
      [key]: "synthetic",
    };
    expect(allows(changes, github, publicInputs)).toBe(false);
    for (const name of [
      "hosted-host-tests",
      "hosted-original-shell",
      "hosted-managed-views",
    ])
      expect(
        allows(ci.jobs[name].if, github, {
          ...publicInputs,
          hosted_host_tests_sha: github.sha,
          hosted_shell_journey_sha: github.sha,
          hosted_managed_views_sha: github.sha,
          hosted_managed_artifacts_run: "1",
          hosted_managed_artifacts_sha: github.sha,
        }),
      ).toBe(false);
  }
  for (const key of [
    "public_release_validation_sha",
    "public_release_validation",
  ])
    expect(ci.on.workflow_dispatch.inputs[key].default).toBe("");
});

test("the reusable gate repeats trust checks and downloads no project evidence or credentials", () => {
  const values = {
    expected_sha: github.sha,
    request: "synthetic-request",
    release: false,
    rebuild: "",
  };
  expect(allows(called.if, github, values)).toBe(true);
  for (const change of [
    { actor_id: "foreign" },
    { repository: "foreign/repository" },
    { ref: "refs/heads/other" },
    { event_name: "push" },
    { sha: "b".repeat(40) },
  ])
    expect(allows(called.if, { ...github, ...change }, values)).toBe(false);
  for (const change of [
    { expected_sha: "" },
    { request: "" },
    { release: true },
    { rebuild: "v1" },
  ])
    expect(allows(called.if, github, { ...values, ...change })).toBe(false);
  expect(called["runs-on"]).toBe("macos-26");
  expect(reusable.permissions).toEqual({ contents: "read", actions: "read" });
  expect(reusable.on.workflow_call.secrets).toBeUndefined();
  const upload = called.steps.find((step) =>
    step.uses?.startsWith("actions/upload-artifact@"),
  );
  expect(upload.with.path).toBe("local/hosted-public-release/result.json");
  expect(
    called.steps.find(
      (step) =>
        step.name ===
        "Verify unauthenticated public bytes and actual isolated installer states",
    ).run,
  ).toBe("bun scripts/hosted-public-release/verify.mjs");
  expect(called.steps[0].with.ref).toBe(`\${{ github.sha }}`);
  expect(called.steps[0].with["persist-credentials"]).toBe(false);
});
