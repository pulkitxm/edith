import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import {
  inertFixtureWorkers,
  supportedFixtureWorkers,
  validateWorkerFixtureProof,
  validateWorkerFixtureSelection,
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
