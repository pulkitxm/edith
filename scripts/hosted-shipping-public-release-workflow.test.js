import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";

const workflow = Bun.YAML.parse(
  readFileSync(
    ".github/workflows/hosted-shipping-public-release-verification.yml",
    "utf8",
  ),
);
const job = workflow.jobs["public-release"];
const github = {
  repository: "pulkitxm/edith",
  repository_id: "1289153439",
  event_name: "workflow_dispatch",
  actor_id: "65671483",
  ref: "refs/heads/main",
  sha: "a".repeat(40),
};
const inputs = { expected_sha: github.sha, request: "synthetic-request" };
const allows = (github, inputs) =>
  new Function("github", "inputs", `return Boolean(${job.if})`)(github, inputs);

test("standalone shipping acceptance is main-only, exact-source, and authorized", () => {
  expect(allows(github, inputs)).toBe(true);
  expect(allows({ ...github, actor_id: "320458784" }, inputs)).toBe(true);
  for (const key of Object.keys(github))
    expect(allows({ ...github, [key]: "foreign" }, inputs)).toBe(false);
  for (const change of [{ expected_sha: "" }, { request: "" }])
    expect(allows(github, { ...inputs, ...change })).toBe(false);
  expect(Object.keys(workflow.on)).toEqual(["workflow_dispatch"]);
  expect(Object.keys(workflow.on.workflow_dispatch.inputs)).toEqual([
    "expected_sha",
    "request",
  ]);
  expect(workflow.permissions).toEqual({ contents: "read", actions: "read" });
  expect(job.env.PUBLISH).toBe("false");
  expect(job.env.REBUILD).toBe("");
  expect(job.env.EXTENSION_SWIFT_JOBS).toBe("1");
  expect(job["runs-on"]).toBe("macos-26");
  expect(job["timeout-minutes"]).toBe(180);
  expect(job.steps[0].with).toEqual({
    ref: "$" + "{{ github.sha }}",
    "fetch-depth": 0,
    "persist-credentials": false,
  });
  expect(workflow.on.workflow_dispatch.secrets).toBeUndefined();
});

test("shipping admission repeats closed environment and clean checkout before dependencies", () => {
  const admission = job.steps[1].run;
  for (const text of [
    'test "$GITHUB_ACTIONS" = true',
    'test "$RUNNER_ENVIRONMENT" = github-hosted',
    'test "$RUNNER_OS" = macOS',
    'test "$(uname -m)" = arm64',
    'test "$GITHUB_REPOSITORY" = pulkitxm/edith',
    'test "$GITHUB_REPOSITORY_ID" = 1289153439',
    'test "$GITHUB_EVENT_NAME" = workflow_dispatch',
    'test "$GITHUB_REF" = refs/heads/main',
    'test "$GITHUB_SHA" = "$EXPECTED_SOURCE_SHA"',
    '[[ "$GITHUB_ACTOR_ID" = 65671483 || "$GITHUB_ACTOR_ID" = 320458784 ]]',
    'test "$PUBLISH" = false',
    'test -z "$REBUILD"',
    'test "$(git rev-parse HEAD)" = "$EXPECTED_SOURCE_SHA"',
    'test -z "$(git status --porcelain --untracked-files=normal)"',
  ])
    expect(admission).toContain(text);
  const actual = job.steps.find(
    (step) =>
      step.run === "bun scripts/hosted-public-release/verify-shipping.mjs",
  );
  expect(actual.env).toEqual({ GITHUB_TOKEN: "$" + "{{ github.token }}" });
  const upload = job.steps.find((step) =>
    step.uses?.startsWith("actions/upload-artifact@"),
  );
  expect(upload.with.path).toBe(
    "local/hosted-shipping-public-release/result.json",
  );
  expect(upload.with.name).toBe("hosted-shipping-public-release-verification");
  expect(upload.with["retention-days"]).toBe(7);
  expect(workflow.concurrency["cancel-in-progress"]).toBe(false);
});

test("shipping entry is explicit and default full39 entry is retained", () => {
  const entry = readFileSync(
    "scripts/hosted-public-release/verify-shipping.mjs",
    "utf8",
  );
  const shared = readFileSync(
    "scripts/hosted-public-release/verify.mjs",
    "utf8",
  );
  expect(entry).toContain('await run({ scope: "shipping" })');
  expect(shared).toContain(
    'export async function run({ scope = "full39" } = {})',
  );
  expect(shared).toContain(
    'shipping ? "verify-public-keep-awake" : "verify-public-release"',
  );
  expect(shared).toContain("await run();");
  const full = Bun.YAML.parse(
    readFileSync(
      ".github/workflows/hosted-public-release-verification.yml",
      "utf8",
    ),
  );
  expect(full.on.workflow_call).toBeDefined();
  expect(
    full.jobs["public-release"].steps.some(
      (step) => step.run === "bun scripts/hosted-public-release/verify.mjs",
    ),
  ).toBe(true);
});
