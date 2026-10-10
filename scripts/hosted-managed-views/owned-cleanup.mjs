import assert from "node:assert/strict";
import { writeFile } from "node:fs/promises";
import { join } from "node:path";
import { managedStorePaths } from "./store-fixture.mjs";

export function managedProcessPaths(fixture) {
  const { versionDirectory } = managedStorePaths({
    directory: fixture.directory,
    identifier: fixture.identifier,
    package_: { ...fixture.package, id: fixture.extensionID },
  });
  const payload = join(versionDirectory, fixture.extensionID);
  const host = join(fixture.app, "Contents/MacOS/Edith");
  return {
    host,
    engine: host,
    ui: join(
      payload,
      "ExtensionCarrier.app/Contents/Extensions/ExtensionWorker.appex/Contents/MacOS/Edith",
    ),
    carrier: join(payload, "ExtensionCarrier.app/Contents/MacOS/Edith"),
    cameraCarrier: join(payload, "CameraCarrier.app/Contents/MacOS/Edith"),
  };
}

export function recordManagedOwnedProcesses(ledger, rows, fixture, uid) {
  assert(Array.isArray(rows) && rows.length <= 16);
  assert(Array.isArray(ledger) && ledger.length <= 16);
  const paths = managedProcessPaths(fixture);
  for (const row of rows) {
    assert.deepEqual(
      Object.keys(row).sort(),
      [
        "pid",
        "generation",
        "uid",
        "executable",
        "hostIdentifier",
        "role",
      ].sort(),
    );
    assert(Number.isSafeInteger(row.pid) && row.pid > 1);
    assert.match(row.generation, /^[0-9]{1,20}\.[0-9]{1,6}$/);
    assert.equal(row.uid, uid);
    assert.equal(row.hostIdentifier, fixture.identifier);
    assert(Object.hasOwn(paths, row.role));
    assert.equal(row.executable, paths[row.role]);
    assert(
      row.role !== "cameraCarrier" || fixture.extensionID === "virtualCamera",
    );
    const previous = ledger.find(
      ({ pid, generation }) => pid === row.pid && generation === row.generation,
    );
    if (previous) assert.deepEqual(previous, row);
    else {
      assert(ledger.length < 16);
      assert(
        !ledger.some(({ pid }) => pid === row.pid),
        "Owned PID generation changed during the fixture",
      );
      assert(
        row.role !== "host" || !ledger.some(({ role }) => role === "host"),
      );
      ledger.push({ ...row });
    }
  }
  return ledger;
}

export async function cleanupManagedOwnedProcesses({
  fixture,
  ledger,
  control,
  pause,
  now = Date.now,
}) {
  recordManagedOwnedProcesses([], ledger, fixture, process.getuid());
  await writeFile(
    join(fixture.directory, "cleanup-ledger.json"),
    JSON.stringify(ledger),
    { flag: "wx", mode: 0o600 },
  );
  let remaining = await control("--remaining");
  const validate = (rows) => {
    assert(Array.isArray(rows) && rows.length <= ledger.length);
    recordManagedOwnedProcesses([], rows, fixture, process.getuid());
    for (const row of rows)
      assert(
        ledger.some((known) =>
          Object.keys(known).every((key) => known[key] === row[key]),
        ),
      );
    return rows;
  };
  validate(remaining);
  const initialOwnedGenerations = remaining.length;
  const actions = [];
  for (const [operation, grace] of [
    ["--terminate-host", 10000],
    ["--terminate-workers", 5000],
    ["--kill", 3000],
  ]) {
    if (!remaining.length) break;
    await control(operation);
    actions.push(operation);
    const deadline = now() + grace;
    do {
      remaining = validate(await control("--remaining"));
      if (!remaining.length) break;
      await pause(100);
    } while (now() < deadline);
  }
  const receipt = {
    schema: 1,
    outcome: remaining.length ? "failed" : "drained",
    initialOwnedGenerations,
    observedGenerations: ledger.map(({ pid, generation, role }) => ({
      pid,
      generation,
      role,
    })),
    actions,
    independentlyPinnedGenerationsExited: remaining.length === 0,
    remainingOwnedGenerations: remaining.length,
    managedViewPassed: false,
  };
  await writeFile(
    join(fixture.directory, "cleanup-result.json"),
    JSON.stringify(receipt),
    { flag: "wx", mode: 0o600 },
  );
  assert.equal(
    remaining.length,
    0,
    "An independently pinned fixture generation survived bounded cleanup",
  );
  return receipt;
}
