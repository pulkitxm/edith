import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtemp, readFile, realpath, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import {
  inertFixtureWorkers,
  supportedFixtureWorkers,
  validateWorkerFixtureProof,
  validateWorkerFixtureSelection,
  workerFixtureEnvironment,
} from "./test-extension-workers.mjs";

const definitions = JSON.parse(
  await readFile("Extensions/manifest.json", "utf8"),
);
const workers = definitions.filter((entry) => entry.contractVersion === 1);

test("all39 declared workers are admitted before any fixture build", () => {
  assert.equal(workers.length, 39);
  assert.deepEqual(validateWorkerFixtureSelection(definitions, []), workers);
  for (const requested of [[], ["futureWorker"], ["music", "futureWorker"]])
    assert.throws(
      () =>
        validateWorkerFixtureSelection(
          [...definitions, { id: "futureWorker", contractVersion: 1 }],
          requested,
        ),
      /startup rejected/,
    );
  assert.throws(
    () => validateWorkerFixtureSelection(definitions, ["unknown"]),
    /Unknown worker/,
  );
});

test("all eleven strict inert owners and conditional owners remain selectable", () => {
  assert.equal(inertFixtureWorkers.size, 11);
  for (const worker of workers)
    assert.deepEqual(validateWorkerFixtureSelection(definitions, [worker.id]), [
      worker,
    ]);
  assert.deepEqual(
    validateWorkerFixtureSelection(definitions, ["calendar", "music"]),
    ["calendar", "music"].map((id) =>
      workers.find((worker) => worker.id === id),
    ),
  );
});

test("launcher and native harness have the same fail-closed boundary", async () => {
  const source = await readFile(
    "Packages/EdithHost/Tests/LifecycleHarness/WorkerLifecycleFixture.swift",
    "utf8",
  );
  const inert = source.match(/static let inertIDs[\s\S]*?= \[([\s\S]*?)\]/)[1];
  assert.deepEqual(
    new Set([...inert.matchAll(/"([^"]+)"/g)].map((match) => match[1])),
    inertFixtureWorkers,
  );
  const supported = source.match(
    /static let supportedIDs[\s\S]*?= \[([\s\S]*?)\]/,
  )[1];
  assert.deepEqual(
    new Set([...supported.matchAll(/"([^"]+)"/g)].map((match) => match[1])),
    supportedFixtureWorkers,
  );
  const harness = await readFile(
    "Packages/EdithHost/Tests/LifecycleHarness/Harness.swift",
    "utf8",
  );
  assert(
    harness.indexOf("requireSupported(extensionID)") <
      harness.indexOf("copyItem(at: sourceApp"),
  );
});

test("inert proof never promotes unavailable features or metadata to media coverage", () => {
  const music = {
    surfaceDataValidated: false,
    inertFeatureDeclineValidated: true,
    studioDataValidated: false,
    studioMetadataValidated: false,
  };
  const studio = {
    surfaceDataValidated: true,
    inertFeatureDeclineValidated: false,
    studioDataValidated: false,
    studioMetadataValidated: true,
  };
  validateWorkerFixtureProof(music, { id: "music", surfaceContractVersion: 1 });
  validateWorkerFixtureProof(studio, {
    id: "studio",
    surfaceContractVersion: 1,
  });
  for (const [id, proof, field] of [
    ["music", music, "surfaceDataValidated"],
    ["music", music, "inertFeatureDeclineValidated"],
    ["studio", studio, "studioDataValidated"],
    ["studio", studio, "studioMetadataValidated"],
  ])
    assert.throws(() =>
      validateWorkerFixtureProof(
        { ...proof, [field]: !proof[field] },
        { id, surfaceContractVersion: 1 },
      ),
    );
  assert.throws(() =>
    validateWorkerFixtureProof(music, {
      id: "futureWorker",
      surfaceContractVersion: 1,
    }),
  );
});

test("fixture subprocesses inherit only owned homes and closed environment", async () => {
  const home = await realpath(
    await mkdtemp(join(tmpdir(), "edith-fixture-env-")),
  );
  try {
    const identifier =
      "com.pulkit.edith.tests.worker-20000000-0000-0000-0000-000000000001";
    const old = process.env.EDITH_FIXTURE_UNRELATED_SECRET;
    process.env.EDITH_FIXTURE_UNRELATED_SECRET = "synthetic-must-not-inherit";
    try {
      const environment = workerFixtureEnvironment(home, identifier);
      const output = JSON.parse(
        execFileSync(
          process.execPath,
          [
            "-e",
            "process.stdout.write(JSON.stringify({home:process.env.HOME,path:process.env.PATH,ssh:process.env.SSH_AUTH_SOCK??null,secret:process.env.EDITH_FIXTURE_UNRELATED_SECRET??null,defaults:process.env.EDITH_SHARED_DEFAULTS_SUITE??null,fixture:process.env.EDITH_EXTENSION_FIXTURE_HOME,identifier:process.env.EDITH_EXTENSION_TEST_HOST_IDENTIFIER}))",
          ],
          { encoding: "utf8", env: environment },
        ),
      );
      assert.deepEqual(output, {
        home,
        path: "/usr/bin:/bin:/usr/sbin:/sbin",
        ssh: null,
        secret: null,
        defaults: null,
        fixture: home,
        identifier,
      });
      assert.equal(
        workerFixtureEnvironment(home).EDITH_EXTENSION_TEST_HOST_IDENTIFIER,
        undefined,
      );
      assert.throws(() => workerFixtureEnvironment("relative-home"));
      assert.throws(() => workerFixtureEnvironment(home, "com.pulkit.edith"));
      assert.throws(() =>
        workerFixtureEnvironment(home, "com.pulkit.edith.tests.worker-invalid"),
      );
    } finally {
      if (old === undefined) delete process.env.EDITH_FIXTURE_UNRELATED_SECRET;
      else process.env.EDITH_FIXTURE_UNRELATED_SECRET = old;
    }
  } finally {
    await rm(home, { recursive: true, force: true });
  }
});
