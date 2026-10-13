import { test } from "bun:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { readFile, writeFile } from "node:fs/promises";
import { join, resolve } from "node:path";
import { pathToFileURL } from "node:url";
import { planSwiftTests } from "./ci-test-plan.mjs";
import { orchestrationFixture } from "./hosted-public-release/production-orchestration-fixture.mjs";

test("known pure release tests select script checks while full and unknown workflow plans retain native owners", () => {
  const paths = [
    "scripts/production-orchestration.test.js",
    "scripts/hosted-public-release/production-orchestration-boundaries.mjs",
    "scripts/hosted-public-release/production-orchestration-client.mjs",
    "scripts/hosted-public-release/production-orchestration-fixture.mjs",
    "scripts/hosted-public-release/production-orchestration-native.py",
    "scripts/hosted-public-release/production-publication-coordinator.test.mjs",
  ];
  assert.deepEqual(planSwiftTests(paths), { include: [] });
  const full = planSwiftTests([], { all: true });
  assert(full.include.some(({ lane }) => lane === "host-runtime"));
  assert(full.include.some(({ extension }) => extension === "keepAwake"));
  assert.deepEqual(planSwiftTests(paths, { all: true }), full);
  assert.deepEqual(
    planSwiftTests([...paths, ".github/workflows/unknown-native.yml"]),
    full,
  );
});

async function withRun(variant, action) {
  await orchestrationFixture(async (fixture) => {
    const client = pathToFileURL(
      resolve(
        "scripts/hosted-public-release/production-orchestration-client.mjs",
      ),
    ).href;
    for (const name of ["gh", "pukbot", "swift"])
      await writeFile(
        join(fixture.binary, name),
        `#!/usr/bin/env bun\nimport { runSyntheticPublicationClient } from ${JSON.stringify(client)};\nrunSyntheticPublicationClient(${JSON.stringify(fixture.stateFile)});\n`,
        { mode: 0o700 },
      );
    const python = execFileSync("which", ["python3"], {
      encoding: "utf8",
    }).trim();
    await writeFile(
      join(fixture.binary, "python3"),
      `#!${python}\nimport importlib.util,sys\nsys.dont_write_bytecode=True\ns=importlib.util.spec_from_file_location('native_boundary',${JSON.stringify(resolve("scripts/hosted-public-release/production-orchestration-native.py"))})\nm=importlib.util.module_from_spec(s)\ns.loader.exec_module(m)\nm.main(${JSON.stringify(fixture.stateFile)},${JSON.stringify(python)})\n`,
      { mode: 0o700 },
    );
    const runner = join(fixture.directory, "entry.mjs");
    const preload = join(fixture.directory, "preload.mjs");
    await writeFile(
      preload,
      `import { installOrchestrationBoundaries } from ${JSON.stringify(pathToFileURL(resolve("scripts/hosted-public-release/production-orchestration-boundaries.mjs")).href)};\nawait installOrchestrationBoundaries(${JSON.stringify(fixture.stateFile)},${JSON.stringify(preload)});\n`,
    );
    await writeFile(
      runner,
      `await import(${JSON.stringify(pathToFileURL(preload).href)});
const { publishCoordinatedProductionUpdate } = await import(${JSON.stringify(pathToFileURL(join(fixture.repository, "scripts/hosted-public-release/production-publication-coordinator.mjs")).href)});
await publishCoordinatedProductionUpdate(${JSON.stringify(JSON.stringify(fixture.template))});
`,
    );
    let failure;
    try {
      execFileSync(process.execPath, [runner], {
        cwd: fixture.repository,
        env: fixture.environment,
        timeout: 15000,
        maxBuffer: 65536,
      });
    } catch (error) {
      failure = error;
    }
    const state = JSON.parse(await readFile(fixture.stateFile, "utf8"));
    const closed = state.events.filter(
      ({ kind }) => kind === "observer-closed",
    );
    assert.equal(closed.length, 1);
    assert.equal(
      state.events.filter(({ kind }) => kind === "observer-started").length,
      1,
    );
    let result;
    try {
      result = JSON.parse(
        await readFile(
          join(
            fixture.repository,
            "local/public-host-cohort/execution-result.json",
          ),
          "utf8",
        ),
      );
    } catch (error) {
      assert.equal(error.code, "ENOENT");
    }
    const summary = (source = state.source) =>
      execFileSync(
        process.execPath,
        [
          join(
            fixture.repository,
            "scripts/hosted-public-release/production-summary.mjs",
          ),
        ],
        {
          cwd: fixture.repository,
          env: {
            PATH: fixture.environment.PATH,
            TMPDIR: fixture.directory,
            HOME: fixture.home,
            EXPECTED_SOURCE_SHA: source,
          },
          timeout: 10000,
          maxBuffer: 65536,
        },
      );
    await action({
      fixture,
      failure,
      state,
      result,
      closed: closed[0],
      summary,
    });
  }, variant);
}

const stages = [
  "update-feed-route",
  "host-A-normal-launch",
  "previous-public-package-enabled",
  "original-UI-and-saved-layout",
  "different-public-host-restoration",
  "public-package-restoration",
  "natural-Sparkle-service-drain",
  "natural-owned-host-engine-UI-drain",
  "update-feed-restoration",
];

async function requireRestoredFeed(fixture) {
  const bytes = await readFile(
    join(fixture.home, "Library/Preferences/com.pulkit.edith.plist"),
  );
  assert(!bytes.includes(Buffer.from("SUFeedURL")));
}

test("pure external-boundary full orchestration retains real capabilities channels restoration and summary", async () => {
  await withRun(
    "fixed",
    async ({ fixture, failure, state, result, closed, summary }) => {
      if (failure) throw failure;
      assert.equal(state.promotions, 1);
      assert.deepEqual(closed, {
        kind: "observer-closed",
        code: 0,
        signal: null,
      });
      assert.equal(result.completed, true);
      assert.equal(result.primaryFailed, false);
      assert.equal(result.cleanupFailed, false);
      assert.equal(result.publicReleaseValidated, false);
      assert.equal(result.productionCompatibilityValidated, false);
      assert.deepEqual(
        result.receipts.map(({ stage }) => stage),
        stages,
      );
      const restoration = result.receipts.find(
        ({ stage }) => stage === "different-public-host-restoration",
      ).observed;
      const original = result.receipts.find(
        ({ stage }) => stage === "original-UI-and-saved-layout",
      ).observed;
      assert.deepEqual(restoration.restored, original.saved);
      assert.deepEqual(original.toggles, [
        { before: 0, after: 1 },
        { before: 1, after: 0 },
        { before: 0, after: 1 },
      ]);
      assert.equal(restoration.host.codeHash, "b".repeat(40));
      assert.equal(restoration.retained.version, "1.0.0");
      assert.equal(
        result.receipts.find(
          ({ stage }) => stage === "public-package-restoration",
        ).observed.updated.version,
        "1.0.1",
      );
      assert(
        state.events.findIndex(({ kind }) => kind === "restored-layout-read") <
          state.events.findIndex(({ kind }) => kind === "promoted"),
      );
      assert(
        state.events.findIndex(({ kind }) => kind === "owned-quit") <
          state.events.findIndex(({ kind }) => kind === "observer-closed"),
      );
      await requireRestoredFeed(fixture);
      assert.throws(() => summary("f".repeat(40)));
      summary();
      const sanitized = JSON.parse(
        await readFile(
          join(fixture.repository, "local/public-host-cohort/summary.json"),
          "utf8",
        ),
      );
      assert.equal(sanitized.publicReleaseValidated, false);
      assert.deepEqual(sanitized.observedStages, stages);
      assert(!JSON.stringify(sanitized).includes('"observed":'));
    },
  );
}, 25000);

for (const [variant, boundary] of [
  ["lost-run-projection", "admitCurrentProductionNativeRun"],
  ["wrong-current-run", "admitCurrentProductionNativeRun"],
  ["three-key-sparkle", "production-sparkle-inputs.py"],
]) {
  test(`pure external-boundary ${variant} rejects actual cross-module admission without promotion`, async () => {
    await withRun(variant, async ({ failure, state, result, closed }) => {
      assert(failure);
      assert(failure.stderr.toString().includes(boundary));
      assert.equal(state.promotions, 0);
      assert.equal(result, undefined);
      assert(closed.code !== 0 || closed.signal !== null);
      assert(
        !state.events.some(({ kind }) => kind === "different-host-restored"),
      );
    });
  }, 25000);
}

test("pure external-boundary historical seven-stage consumer rejects actual nine-stage execution", async () => {
  await withRun(
    "seven-stage-summary",
    async ({ fixture, failure, result, state, summary }) => {
      if (failure) throw failure;
      assert.equal(result.completed, true);
      assert.deepEqual(
        result.receipts.map(({ stage }) => stage),
        stages,
      );
      assert.equal(state.promotions, 1);
      assert.throws(() => summary());
      await assert.rejects(
        readFile(
          join(fixture.repository, "local/public-host-cohort/summary.json"),
        ),
        { code: "ENOENT" },
      );
    },
  );
}, 25000);

test("pure external-boundary real observer retirement joins without catalog promotion", async () => {
  await withRun(
    "child-retirement",
    async ({ failure, state, result, closed }) => {
      assert(failure);
      assert.equal(state.promotions, 0);
      assert.equal(result, undefined);
      assert(closed.code === 17 || closed.signal === "SIGTERM");
      assert(!state.events.some(({ kind }) => kind === "native-boundary"));
    },
  );
}, 25000);

test("pure external-boundary actual failed update drains owned identities and restores feed without promotion", async () => {
  await withRun(
    "primary-native-failure",
    async ({ fixture, failure, state, result, summary }) => {
      assert(failure);
      assert.equal(state.promotions, 0);
      assert.equal(result.completed, false);
      assert.equal(result.primaryFailed, true);
      assert.equal(result.cleanupFailed, false);
      assert.equal(result.publicReleaseValidated, false);
      assert.deepEqual(
        result.receipts.slice(-2).map(({ stage }) => stage),
        stages.slice(-2),
      );
      assert(
        result.receipts
          .at(-2)
          .observed.every(({ running }) => running === false),
      );
      assert.equal(result.receipts.at(-1).observed.restored, true);
      assert(state.events.some(({ kind }) => kind === "owned-quit"));
      await requireRestoredFeed(fixture);
      summary();
      const sanitized = JSON.parse(
        await readFile(
          join(fixture.repository, "local/public-host-cohort/summary.json"),
          "utf8",
        ),
      );
      assert.equal(sanitized.completed, false);
      assert.equal(sanitized.primaryFailed, true);
      assert.equal(sanitized.publicReleaseValidated, false);
    },
  );
}, 25000);
