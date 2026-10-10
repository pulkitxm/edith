import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { readFile, rename, writeFile } from "node:fs/promises";
import { join, resolve } from "node:path";
import { setTimeout as sleep } from "node:timers/promises";

const [operation, directory_] = process.argv.slice(2);
assert(
  ["launch", "approved", "verify"].includes(operation) && directory_,
  "Usage: test-host-remote-ui.mjs launch|approved|verify fixture-directory",
);
const directory = resolve(directory_);
const fixture = JSON.parse(
  await readFile(join(directory, "fixture.json"), "utf8"),
);
assert.equal(fixture.directory, directory);
assert.match(fixture.identifier, /^com\.pulkit\.edith\.tests\.remote-/);
async function state() {
  try {
    return JSON.parse(await readFile(join(directory, "state.json"), "utf8"));
  } catch {
    return null;
  }
}
async function until(predicate, description, timeout = 30000) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    const current = await state();
    if (current && (await predicate(current))) return current;
    await sleep(50);
  }
  throw new Error(
    `Timed out waiting for ${description}: ${JSON.stringify(await state())}`,
  );
}
async function command(name, expected) {
  await writeFile(
    join(directory, "command.next"),
    JSON.stringify({ command: name }),
  );
  await rename(
    join(directory, "command.next"),
    join(directory, "command.json"),
  );
  return until((value) => value.phase === expected, expected);
}
async function record(current) {
  return JSON.parse(await readFile(current.engineRecord, "utf8"));
}
function released(current) {
  assert.equal(current.uiRunning, false);
  assert.equal(current.leaseAvailable, true);
  assert(!current.remoteSessions.includes("sample"));
}

if (operation === "launch") {
  execFileSync("open", [
    "-g",
    "-j",
    "-n",
    fixture.carrier,
    "--args",
    "--extension-ui-carrier",
  ]);
  await sleep(1000);
  execFileSync("open", [
    "-n",
    fixture.app,
    "--args",
    "--extension-remote-fixture",
    directory,
  ]);
  const current = await until(
    (value) => ["error", "active"].includes(value.phase),
    "remote scene or public approval",
    60000,
  );
  if (current.phase === "error") {
    assert.equal(
      current.error,
      "approvalRequired",
      "The remote scene failed before approval",
    );
    await command("approval", "approval");
  }
  console.log(
    JSON.stringify({
      outcome: current.phase === "active" ? "active" : "publicApprovalRequired",
      fixtureDirectory: directory,
    }),
  );
} else if (operation === "approved") {
  await command("approved", "active");
  console.log(JSON.stringify({ outcome: "active" }));
} else {
  const active = await until(
    (value) => value.phase === "active",
    "approved active scene",
    120000,
  );
  assert.equal(active.uiRunning, true);
  assert.equal(active.leaseAvailable, false);
  assert(active.enginePID > 0 && active.uiPID > 0 && active.hostPID > 0);
  assert(new Set([active.enginePID, active.uiPID, active.hostPID]).size === 3);
  const first = await record(active);
  assert(
    first.count >= 2,
    "Click Read owned record in the actual embedded remote view",
  );
  assert(first.holds >= 1, "Click Hold owned request before verification");
  const closed = await command("close", "closed");
  released(closed);
  assert.equal(closed.enginePID, active.enginePID);
  await until(
    async (value) => (await record(value)).cancelled >= 1,
    "scene cancellation reached engine",
  );
  const reopened = await command("open", "active");
  assert.equal(reopened.enginePID, active.enginePID);
  assert(
    reopened.uiPID !== active.uiPID ||
      reopened.uiGeneration !== active.uiGeneration,
  );
  const disabled = await command("disable", "disabled");
  released(disabled);
  assert.equal(disabled.enginePID, null);
  await command("enable", "enabled");
  const fresh = await command("open", "active");
  assert(fresh.enginePID > 0 && fresh.enginePID !== active.enginePID);
  const finalClose = await command("close", "closed");
  released(finalClose);
  const stopped = await command("quit", "stopped");
  assert.equal(stopped.enginePID, null);
  released(stopped);
  const result = {
    outcome: "passed",
    actualEmbeddedButton: true,
    engineRelay: true,
    pendingCallCancelled: true,
    lastCloseExited: true,
    freshSceneGeneration: true,
    disableExitedBothRoles: true,
    freshEngineGeneration: true,
    packageLeaseReleased: true,
    sameExecutableCarrier: true,
  };
  await writeFile(join(directory, "result.json"), JSON.stringify(result));
  console.log(JSON.stringify(result));
}
