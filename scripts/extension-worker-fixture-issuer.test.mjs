import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { validateWorkerFixtureSelection, unsupportedFixtureWorkers, supportedFixtureWorkers } from "./test-extension-workers.mjs";

const definitions = JSON.parse(await readFile("Extensions/manifest.json", "utf8"));
const workers = definitions.filter((entry) => entry.contractVersion === 1);

test("all39 defaults fail closed before fixture builds or runtime", () => {
  assert.equal(workers.length, 39);
  assert.throws(() => validateWorkerFixtureSelection(definitions, []), /startup rejected/);
  assert.throws(() => validateWorkerFixtureSelection([...definitions,
    { id: "futureWorker", contractVersion: 1 }], ["futureWorker"]), /startup rejected/);
});

test("all blocked and unresolved tool owners are rejected individually", () => {
  for (const id of unsupportedFixtureWorkers)
    assert.throws(() => validateWorkerFixtureSelection(definitions, [id]), /startup rejected/);
  assert.throws(() => validateWorkerFixtureSelection(definitions, ["unknown"]), /Unknown worker/);
});

test("known admitted and conditional IDs remain selectable", () => {
  for (const worker of workers.filter(({ id }) => !unsupportedFixtureWorkers.has(id)))
    assert.deepEqual(validateWorkerFixtureSelection(definitions, [worker.id]), [worker]);
  assert.throws(() => validateWorkerFixtureSelection(definitions, ["calendar", "music"]), /startup rejected/);
});

test("launcher and native harness have the same fail-closed boundary", async () => {
  const source = await readFile("Packages/EdithHost/Tests/LifecycleHarness/WorkerLifecycleFixture.swift", "utf8");
  const blocked = source.match(/static let blockedIDs[\s\S]*?= \[([\s\S]*?)\]/)[1];
  assert.deepEqual(new Set([...blocked.matchAll(/"([^"]+)"/g)].map((match) => match[1])), unsupportedFixtureWorkers);
  const supported = source.match(/static let supportedIDs[\s\S]*?= \[([\s\S]*?)\]/)[1];
  assert.deepEqual(new Set([...supported.matchAll(/"([^"]+)"/g)].map((match) => match[1])), supportedFixtureWorkers);
  const harness = await readFile("Packages/EdithHost/Tests/LifecycleHarness/Harness.swift", "utf8");
  assert(harness.indexOf("requireSupported(extensionID)") < harness.indexOf("copyItem(at: sourceApp"));
});
