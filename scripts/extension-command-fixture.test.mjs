import assert from "node:assert/strict";
import { readFile, readdir } from "node:fs/promises";
import test from "node:test";

test("contained command fixture uses maintained closed home and UUID setup", async () => {
  const source = await readFile("scripts/test-extension-commands.mjs", "utf8");
  assert.match(source, /com\.pulkit\.edith\.tests\.worker-\$\{crypto\.randomUUID\(\)\}/);
  assert.match(source, /workerFixtureHome\(fixture, "keepAwake"\)/);
  assert.match(source, /mkdir\(fixture, \{ mode: 0o700 \}\)/);
  assert.match(source, /mkdir\(home, \{ mode: 0o700 \}\)/);
  assert.match(source, /env: workerFixtureEnvironment\(home, identifier\)/);
  assert.match(source, /const root = await realpath\(/);
});

test("all command lifecycle scenarios retain original cancellation and drain checks", async () => {
  const source = await readFile("Packages/EdithHost/Tests/CommandHarness/main.swift", "utf8");
  assert.match(source, /\["disable", "crash", "hang", "completed", "asyncStop", "asyncHang"\]/);
  const issued = source.indexOf("fixture.issue(selection");
  const validated = source.indexOf("fixture.validateExact(selection");
  const started = source.indexOf("worker.start()");
  assert(issued >= 0 && validated >= 0 && started >= 0);
  assert(issued < validated && validated < started);
  assert.match(source, /\[pid, parent, child\]\.allSatisfy/);
  assert.match(source, /cancelled\.cancel\(\)/);
  assert.match(source, /catch is CancellationError/);
});

test("fixture issuer source belongs to exactly one shared target", async () => {
  const manifest = await readFile("Packages/EdithHost/Package.swift", "utf8");
  const support = manifest.match(/name: "WorkerLifecycleFixtureSupport", path: "Tests\/LifecycleHarness",\s*exclude: \[([\s\S]*?)\],\s*sources: \["WorkerLifecycleFixture.swift"\]/);
  assert(support);
  const excluded = [...support[1].matchAll(/"([^"]+)"/g)].map((match) => match[1]);
  const peers = (await readdir("Packages/EdithHost/Tests/LifecycleHarness"))
    .filter((name) => name.endsWith(".swift") && name !== "WorkerLifecycleFixture.swift");
  assert.deepEqual(excluded.sort(), peers.sort());
  assert.equal((manifest.match(/name: "WorkerLifecycleFixtureSupport"/g) ?? []).length, 1);
  assert.match(manifest, /name: "HostLifecycleHarness",\s*dependencies: \["EdithHostCore", "WorkerLifecycleFixtureSupport"\],\s*path: "Tests\/LifecycleHarness", exclude: \["WorkerLifecycleFixture.swift"\]/);
  assert.match(manifest, /name: "HostCommandHarness",\s*dependencies: \["EdithHostCore", "WorkerLifecycleFixtureSupport"\]/);
  for (const path of [
    "Packages/EdithHost/Tests/LifecycleHarness/Harness.swift",
    "Packages/EdithHost/Tests/CommandHarness/main.swift",
  ]) {
    const source = await readFile(path, "utf8");
    assert.equal((source.match(/^import WorkerLifecycleFixtureSupport$/gm) ?? []).length, 1);
  }
});
