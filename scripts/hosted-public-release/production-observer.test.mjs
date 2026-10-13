import { test } from "bun:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { productionVerifiedInputs } from "./production-inputs.mjs";
import {
  observeProductionHistory,
  prepareProductionObserver,
  productionObserverEnvironment,
  productionObserverHosted,
  validateProductionActionResult,
} from "./production-observer.mjs";
import {
  productionRemainingBudget,
  validateProductionInfo,
  validateProductionRestoration,
} from "./production-update.mjs";

const hosted = () => ({
  GITHUB_ACTIONS: "true",
  RUNNER_ENVIRONMENT: "github-hosted",
  RUNNER_OS: "macOS",
  GITHUB_REPOSITORY: "pulkitxm/edith",
  GITHUB_REPOSITORY_ID: "1289153439",
  GITHUB_EVENT_NAME: "workflow_dispatch",
  GITHUB_REF: "refs/heads/main",
  GITHUB_SHA: "a".repeat(40),
  GITHUB_ACTOR_ID: "65671483",
  PUBLIC_RELEASE_VERIFICATION: "1",
  PUBLISH: "false",
  REBUILD: "",
});

const syntheticIdentity = (pid, role = "host") => ({
  role,
  pid,
  generation: `${pid}:1`,
  executable: `/synthetic/${role}`,
  codeHash: "b".repeat(40),
  running: true,
});

test("historical cleanup observes all admitted identities in bounded batches under one deadline", async () => {
  for (const count of [13, 17, 24]) {
    const expected = Array.from({ length: count }, (_, index) =>
      syntheticIdentity(200000 + index),
    );
    const calls = [];
    let clock = 100;
    const actual = await observeProductionHistory(
      expected,
      async (rows, remaining) => {
        calls.push({ rows, remaining });
        clock += 25;
        return rows.map((row) => ({ ...row, running: false }));
      },
      200,
      () => clock,
    );
    assert.deepEqual(
      calls.map(({ rows }) => rows.length),
      [12, count - 12],
    );
    assert.deepEqual(
      calls.map(({ remaining }) => remaining),
      [100, 75],
    );
    assert.deepEqual(
      actual,
      expected.map((row) => ({ ...row, running: false })),
    );
  }
});

test("historical cleanup rejects changed identities and expired batches without fresh time", async () => {
  const expected = Array.from({ length: 13 }, (_, index) =>
    syntheticIdentity(200000 + index),
  );
  for (const edit of [
    { pid: 400000 },
    { generation: "1:2" },
    { executable: "/synthetic/unadmitted" },
    { codeHash: "c".repeat(40) },
    { running: "false" },
  ])
    await assert.rejects(
      observeProductionHistory(
        expected,
        async (rows) =>
          rows.map((row, index) => (index ? row : { ...row, ...edit })),
        200,
        () => 100,
      ),
    );
  let calls = 0;
  let clock = 100;
  await assert.rejects(
    observeProductionHistory(
      expected,
      async (rows) => {
        calls++;
        clock = 200;
        return rows;
      },
      200,
      () => clock,
    ),
  );
  assert.equal(calls, 1);
  await assert.rejects(
    observeProductionHistory([...expected, expected[0]], async () => {
      throw new Error("Duplicate identity reached observer");
    }),
  );
  await assert.rejects(
    observeProductionHistory(
      Array.from({ length: 25 }, (_, index) =>
        syntheticIdentity(200000 + index),
      ),
      async () => {
        throw new Error("Excess history reached observer");
      },
    ),
  );
});

test("sixty-second restoration caps native calls and retains the original absolute expiry", async () => {
  const expected = Array.from({ length: 24 }, (_, index) =>
    syntheticIdentity(200000 + index),
  );
  let clock = 0;
  const budgets = [];
  const rows = await observeProductionHistory(
    expected,
    async (batch, timeout) => {
      budgets.push(timeout);
      clock = budgets.length === 1 ? 51000 : 59999;
      return batch.map((row) => ({ ...row, running: false }));
    },
    60000,
    () => clock,
  );
  assert.equal(rows.length, 24);
  assert.deepEqual(budgets, [10000, 9000]);
  clock = 0;
  let calls = 0;
  await assert.rejects(
    observeProductionHistory(
      expected,
      async (batch, timeout) => {
        assert.equal(timeout, 10000);
        calls++;
        clock = 60000;
        return batch;
      },
      60000,
      () => clock,
    ),
  );
  assert.equal(calls, 1);
});

test("accepted relaunch permits exact old owner retirement but other actions require live owners", () => {
  const host = syntheticIdentity(200000);
  const updater = syntheticIdentity(200001, "sparkleUpdater");
  for (const running of [
    [false, false],
    [false, true],
    [true, false],
    [true, true],
  ]) {
    const result = {
      performedAction: "installRelaunch",
      postActionOwners: [
        { ...updater, running: running[0] },
        { ...host, running: running[1] },
      ],
    };
    assert.equal(
      validateProductionActionResult("installRelaunch", result, [
        host,
        updater,
      ]),
      result,
    );
    if (running.some((value) => !value))
      assert.throws(() =>
        validateProductionActionResult(
          "installUpdate",
          { ...result, performedAction: "installUpdate" },
          [host, updater],
        ),
      );
  }
  for (const edit of [
    { pid: 400000 },
    { generation: "1:2" },
    { codeHash: "c".repeat(40) },
    { executable: "/synthetic/other" },
  ])
    assert.throws(() =>
      validateProductionActionResult(
        "installRelaunch",
        {
          performedAction: "installRelaunch",
          postActionOwners: [{ ...updater, ...edit, running: false }, host],
        },
        [host, updater],
      ),
    );
  assert.throws(() =>
    validateProductionActionResult(
      "goHome",
      {
        performedAction: "goHome",
        postActionOwners: [updater, host],
      },
      [host, updater],
    ),
  );
});

test("production child environments retain the actual home and discard unrelated inherited authority", () => {
  const home = "/Users/synthetic";
  const environment = {
    HOME: home,
    PATH: "/usr/bin:/bin",
    TMPDIR: "/private/tmp/synthetic",
    SECRET: "synthetic-only",
    GITHUB_TOKEN: "synthetic-only",
  };
  assert.deepEqual(productionObserverEnvironment(environment, home), {
    HOME: home,
    PATH: environment.PATH,
    TMPDIR: environment.TMPDIR,
  });
  for (const key of [
    "PYTHONPATH",
    "PYTHONHOME",
    "NODE_OPTIONS",
    "NODE_PATH",
    "CFFIXED_USER_HOME",
    "SSH_AUTH_SOCK",
    "EDITH_APPLICATION_IDENTIFIER",
    "EDITH_EXTENSION_DATA_ROOT",
  ])
    assert.throws(() =>
      productionObserverEnvironment(
        { ...environment, [key]: "synthetic-only" },
        home,
      ),
    );
  assert.throws(() =>
    productionObserverEnvironment(
      { ...environment, HOME: "/Users/foreign" },
      home,
    ),
  );
});

test("production observer rejects unreviewed source event owner and publication before any native work", () => {
  productionObserverHosted(hosted(), "a".repeat(40));
  for (const [key, value] of Object.entries({
    GITHUB_ACTOR_ID: "1",
    GITHUB_REF: "refs/heads/fixture",
    GITHUB_EVENT_NAME: "pull_request",
    GITHUB_SHA: "b".repeat(40),
    GITHUB_REPOSITORY_ID: "1",
    RUNNER_ENVIRONMENT: "self-hosted",
    PUBLISH: "true",
    PUBLIC_RELEASE_VERIFICATION: "0",
  }))
    assert.throws(() =>
      productionObserverHosted({ ...hosted(), [key]: value }, "a".repeat(40)),
    );
});

test("faked verification flags and copied capability shells never create execution authority", async () => {
  for (const fake of [
    {},
    {
      artifactVerificationExecuted: true,
      productionCompatibilityValidated: true,
    },
    { request: { source: "a".repeat(40) }, roles: [] },
  ]) {
    assert.throws(() => productionVerifiedInputs(fake));
    await assert.rejects(prepareProductionObserver(fake));
  }
});

test("restoration needs both physical saved layout hashes and rejects empty partial or changed observations", () => {
  const layout = {
    "com.pulkit.edith.shared:surfaceGrid.home": "a".repeat(64),
    "com.pulkit.edith.shared:surfaceGrid.notch": "b".repeat(64),
    "com.pulkit.edith.shared:surfaceEditorTarget": createHash("sha256")
      .update("notch")
      .digest("hex"),
    "com.pulkit.edith.shared:surfaceEditorWidget": "c".repeat(64),
  };
  validateProductionRestoration(layout, { ...layout });
  for (const bad of [
    {},
    { "com.pulkit.edith.shared:surfaceGrid.home": "a".repeat(64) },
    { ...layout, "com.pulkit.edith.shared:surfaceGrid.notch": "d".repeat(64) },
    { ...layout, "com.pulkit.edith.shared:surfaceEditorWidget": "" },
    {
      ...layout,
      "com.pulkit.edith.shared:surfaceEditorWidget": createHash("sha256")
        .update("")
        .digest("hex"),
    },
    {
      ...layout,
      "com.pulkit.edith.shared:surfaceEditorTarget": "d".repeat(64),
    },
  ])
    assert.throws(() => validateProductionRestoration(layout, bad));
  assert.throws(() => validateProductionRestoration({}, {}));
});

test("ordinary CLI restoration rejects stale versions paused owners missing PIDs and false partial success", () => {
  const info = {
    id: "keepAwake",
    version: "1.0.0",
    installed: true,
    compatible: true,
    enabled: true,
    running: true,
    removalPending: false,
    disablePending: false,
    offline: false,
    processIdentifier: 400,
  };
  validateProductionInfo(info, "1.0.0", true);
  for (const edit of [
    { version: "1.0.1" },
    { enabled: false },
    { installed: false },
    { running: false },
    { processIdentifier: null },
    { processIdentifier: 0 },
    { compatible: false },
    { disablePending: true },
    { removalPending: true },
    { offline: true },
  ])
    assert.throws(() =>
      validateProductionInfo({ ...info, ...edit }, "1.0.0", true),
    );
  assert.throws(() =>
    validateProductionInfo({ completed: true }, "1.0.0", true),
  );
});

test("old owner retirement and successor readiness share one unchanged Sparkle budget", () => {
  const deadline = 60010;
  assert.equal(productionRemainingBudget(deadline, 10), 60000);
  assert.equal(productionRemainingBudget(deadline, 40010), 20000);
  assert.equal(productionRemainingBudget(deadline, 60009), 1);
  for (const now of [60010, 60011, -1, NaN, Infinity]) {
    assert.throws(() => productionRemainingBudget(deadline, now));
  }
});

test("actual fixed Sparkle helper byte and linkage counterexamples run with script CI", () => {
  const root = join(dirname(fileURLToPath(import.meta.url)), "../..");
  execFileSync(
    "python3",
    ["-I", "-B", join(root, "scripts/test-production-sparkle-inputs.py")],
    {
      cwd: root,
      env: {
        PATH: process.env.PATH,
        TMPDIR: tmpdir(),
        PYTHONDONTWRITEBYTECODE: "1",
      },
      timeout: 30000,
      maxBuffer: 65536,
    },
  );
});
