import { test } from "bun:test";
import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { verifiedHostBootstrapIntent } from "./production-bootstrap.mjs";
import { validateHostReleaseDispatch } from "./production-host-dispatch.mjs";

const original = JSON.parse(
  execFileSync(
    "python3",
    [
      "-I",
      "-B",
      "-c",
      "import importlib.util,json;s=importlib.util.spec_from_file_location('cases','scripts/test-production-host-cohort.py');m=importlib.util.module_from_spec(s);s.loader.exec_module(m);print(json.dumps(m.synthetic_request()))",
    ],
    { encoding: "utf8" },
  ),
);
const template = {
  ...original,
  schema: 2,
  hosts: {
    previous: original.hosts.previous,
    current: {
      kind: "pending-public-host",
      source: original.source,
      run: null,
      runAttempt: null,
      tag: "v0.0.402",
      version: "0.0.402",
      build: 2,
    },
  },
  packages: { previous: original.packages.previous, current: null },
  catalogs: { previous: original.catalogs.previous, current: null },
};
const text = JSON.stringify(template);
const inputs = {
  release: true,
  rebuild: "",
  coordinated_host_release: text,
  hosted_native_compile_sha: "",
  public_release_validation: "",
};
const environment = {
  HOME: process.env.HOME,
  PATH: process.env.PATH,
  TMPDIR: process.env.TMPDIR,
  GITHUB_ACTIONS: "true",
  RUNNER_ENVIRONMENT: "github-hosted",
  RUNNER_OS: "Linux",
  GITHUB_REPOSITORY: "pulkitxm/edith",
  GITHUB_REPOSITORY_ID: "1289153439",
  GITHUB_EVENT_NAME: "workflow_dispatch",
  GITHUB_REF: "refs/heads/main",
  GITHUB_SHA: template.source,
  GITHUB_ACTOR_ID: "65671483",
  PUBLIC_RELEASE_VERIFICATION: "1",
};

test("dispatch validation retains the closed pending intent without granting readiness authority", () => {
  const parsed = validateHostReleaseDispatch(text, inputs, environment);
  assert.deepEqual(parsed, template);
  assert.equal(parsed.hosts.current.run, null);
  assert.throws(() => verifiedHostBootstrapIntent(parsed));
});

test("foreign dispatches diagnostics rebuilds and supplied current success never enter host publication", () => {
  for (const change of [
    { GITHUB_EVENT_NAME: "push" },
    { GITHUB_REF: "refs/heads/other" },
    { GITHUB_REPOSITORY_ID: "1" },
    { GITHUB_ACTOR_ID: "1" },
    { RUNNER_OS: "macOS" },
    { GITHUB_SHA: "b".repeat(40) },
    { PYTHONPATH: "/synthetic" },
    { NODE_OPTIONS: "--inspect" },
    { EDITH_FIXTURE: "1" },
  ])
    assert.throws(() =>
      validateHostReleaseDispatch(text, inputs, { ...environment, ...change }),
    );
  for (const change of [
    { release: false },
    { release: "true" },
    { rebuild: "v0.0.401" },
    { hosted_native_compile_sha: template.source },
    { public_release_validation: "{}" },
    { unknown_mode: true },
  ])
    assert.throws(() =>
      validateHostReleaseDispatch(text, { ...inputs, ...change }, environment),
    );
  for (const change of [
    { run: 12, runAttempt: 1 },
    { publicationVerified: true },
    { kind: "verified-public-host" },
  ]) {
    const invalid = JSON.stringify({
      ...template,
      hosts: {
        ...template.hosts,
        current: { ...template.hosts.current, ...change },
      },
    });
    assert.throws(() =>
      validateHostReleaseDispatch(
        invalid,
        { ...inputs, coordinated_host_release: invalid },
        environment,
      ),
    );
  }
  const duplicate = text.replace('"schema":2', '"schema":2,"schema":2');
  assert.throws(() =>
    validateHostReleaseDispatch(
      duplicate,
      { ...inputs, coordinated_host_release: duplicate },
      environment,
    ),
  );
});

test("the actual dispatch CLI validates before release work and remains portable without optional native execution", () => {
  for (const executable of [
    process.execPath,
    process.env.EXTENSION_TEST_NODE ?? "node",
  ]) {
    const argv = [
      fileURLToPath(new URL("./production-host-dispatch.mjs", import.meta.url)),
    ];
    const env = {
      ...environment,
      COORDINATED_HOST_RELEASE: text,
      COORDINATED_RELEASE_INPUTS: JSON.stringify(inputs),
    };
    const result = spawnSync(executable, argv, {
      env,
      encoding: "utf8",
      timeout: 10000,
    });
    assert.equal(result.error, undefined);
    assert.equal(result.status, 0, result.stderr);
    assert.equal(result.stdout, "");
    const rejected = spawnSync(executable, argv, {
      env: {
        ...env,
        COORDINATED_RELEASE_INPUTS: JSON.stringify({
          ...inputs,
          release: false,
        }),
      },
      encoding: "utf8",
      timeout: 10000,
    });
    assert.equal(rejected.error, undefined);
    assert.notEqual(rejected.status, 0);
    assert.equal(rejected.stdout, "");
  }
});

test("declared coordinated readiness cannot fall back to the ordinary live catalog route", () => {
  const result = spawnSync(
    process.env.EXTENSION_TEST_NODE ?? "node",
    ["scripts/extension-release-ready.mjs", "/synthetic/unavailable-source"],
    {
      env: {
        ...environment,
        COORDINATED_HOST_RELEASE: text,
        COORDINATED_RELEASE_INPUTS: JSON.stringify({
          ...inputs,
          release: false,
        }),
      },
      encoding: "utf8",
      timeout: 10000,
    },
  );
  assert.equal(result.error, undefined);
  assert.notEqual(result.status, 0);
  assert(!result.stderr.includes("Cannot find package"));
  assert(!result.stdout.includes("Compatible extension catalog verified"));
  assert(!result.stdout.includes("Staged cohort host readiness verified"));
});

test("workflow materializes exact dependencies only for the new declared host path before the unchanged release gates", () => {
  const workflow = readFileSync(".github/workflows/ci.yml", "utf8");
  const version = workflow.slice(
    workflow.indexOf("\n  version:\n"),
    workflow.indexOf("\n  dmg:\n"),
  );
  const publish = workflow.slice(workflow.indexOf("\n  publish:\n"));
  assert(
    workflow.includes(
      'coordinated_host_release:\n        description: "Closed pending host intent for a coordinated public release."\n        type: string\n        required: false\n        default: ""',
    ),
  );
  assert(version.includes("inputs.release || inputs.rebuild != ''"));
  assert(version.includes("if: inputs.coordinated_host_release != ''"));
  assert(
    version.indexOf("Validate coordinated host release dispatch") <
      version.indexOf("Resolve the version to release"),
  );
  assert(publish.includes("timeout-minutes: 150"));
  assert(publish.includes("contents: read"));
  assert(!publish.includes("contents: write"));
  assert(publish.includes("actions: read"));
  assert(publish.includes("GH_TOKEN: $" + "{{ secrets.RELEASE_PUSH_TOKEN }}"));
  const wait = publish.slice(
    publish.indexOf("- name: Wait for compatible extension releases"),
    publish.indexOf("- name: Require the release client to accept both assets"),
  );
  assert(wait.includes("GITHUB_TOKEN: $" + "{{ github.token }}"));
  const dependencies = publish.slice(
    publish.indexOf("- uses: oven-sh/setup-bun"),
    publish.indexOf("- name: Wait for compatible extension releases"),
  );
  assert.equal(
    dependencies.match(/if: inputs.coordinated_host_release != ''/g).length,
    2,
  );
  assert(dependencies.includes("working-directory: release-source"));
  assert(dependencies.includes("run: bun install --frozen-lockfile"));
  assert(
    publish.indexOf("Wait for compatible extension releases") <
      publish.indexOf("Commit and tag the release"),
  );
  assert(
    publish.includes(
      "run: node release-source/scripts/extension-release-ready.mjs release-source",
    ),
  );
  assert(publish.includes('RELEASE_PRERELEASE: "true"'));
  const consumer = readFileSync("scripts/extension-release-ready.mjs", "utf8");
  assert(consumer.includes("readiness.waitForStagedHostReadiness("));
  assert(consumer.includes("bootstrap.retireHostBootstrapIntent(intent)"));
  assert.equal(
    consumer.match(
      /dispatch.verifyCoordinatedHostSource\(root, template.source\)/g,
    ).length,
    3,
  );
  assert(consumer.includes("const revision = await waitForPackages({"));
});
