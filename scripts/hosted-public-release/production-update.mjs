import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { constants } from "node:fs";
import { lstat, mkdir, open, realpath } from "node:fs/promises";
import { join } from "node:path";
import { setTimeout as delay } from "node:timers/promises";
import { runOwnedJourneyCommand } from "../hosted-original-shell/owned-command.mjs";
import {
  boundedProductionFile,
  prepareProductionInputs,
  productionVerifiedInputs,
} from "./production-inputs.mjs";
import { prepareProductionObserver } from "./production-observer.mjs";

const application = "/Applications/Edith.app";
const executable = `${application}/Contents/MacOS/Edith`;
const host = (rows) => {
  const values = rows.filter((row) => row.role === "host" && row.running);
  assert.equal(values.length, 1);
  return values[0];
};
export function validateProductionInfo(info, version, running) {
  assert.equal(info.id, "keepAwake");
  assert.equal(info.version, version);
  assert.equal(info.installed, true);
  assert.equal(info.compatible, true);
  assert.equal(info.enabled, running);
  assert.equal(info.running, running);
  assert.equal(info.removalPending, false);
  assert.equal(info.disablePending, false);
  assert.equal(info.offline, false);
  if (running)
    assert(
      Number.isInteger(info.processIdentifier) && info.processIdentifier > 1,
    );
  else assert.equal(info.processIdentifier, null);
}
export function validateProductionRestoration(before, after) {
  assert(before && after && !Array.isArray(before) && !Array.isArray(after));
  const keys = Object.keys(before).sort();
  const prefix = "com.pulkit.edith.shared:";
  for (const key of [
    "surfaceGrid.home",
    "surfaceGrid.notch",
    "surfaceEditorTarget",
    "surfaceEditorWidget",
  ]) {
    assert(keys.includes(prefix + key));
  }
  for (const key of keys) assert.match(before[key], /^[a-f0-9]{64}$/);
  const digest = (value) => createHash("sha256").update(value).digest("hex");
  assert.equal(before[`${prefix}surfaceEditorTarget`], digest("notch"));
  assert.notEqual(before[`${prefix}surfaceEditorWidget`], digest(""));
  assert.deepEqual(after, before);
}
export function productionRemainingBudget(deadline, now = performance.now()) {
  assert(Number.isFinite(deadline) && Number.isFinite(now));
  const remaining = deadline - now;
  assert(remaining > 0 && remaining <= 60000);
  return remaining;
}
async function waitForObserved(operation, predicate, milliseconds = 5000) {
  const deadline = performance.now() + milliseconds;
  while (true) {
    const value = await operation(deadline);
    if (predicate(value)) {
      assert(performance.now() < deadline);
      return value;
    }
    assert(
      performance.now() < deadline,
      "Original observed state deadline expired",
    );
    await delay(Math.min(50, Math.max(1, deadline - performance.now())));
  }
}
export async function executeProductionUpdate(text, { promoteCatalog } = {}) {
  const capability = await prepareProductionInputs(text);
  const verified = productionVerifiedInputs(capability);
  const observer = await prepareProductionObserver(capability);
  const receipts = [];
  const record = (stage, observed) =>
    receipts.push(Object.freeze({ stage, observed }));
  const owned = [];
  let failure;
  let cleanupFailure;
  let completed = false;
  const observeRows = async () => {
    const rows = await observer.snapshot();
    for (const row of rows)
      if (
        !owned.some(
          (value) =>
            value.pid === row.pid &&
            value.generation === row.generation &&
            value.role === row.role,
        )
      )
        owned.push(row);
    assert(owned.length <= 24);
    return rows;
  };
  const requireGeneration = async (generation) => {
    await verified.revalidate();
    const actual = await boundedProductionFile(executable, 16777216, true);
    assert.equal(
      actual.sha256,
      verified.request.hosts[generation].hostExecutableSHA256,
    );
    const rows = await observeRows();
    assert.equal(host(rows).codeHash, verified.hosts[generation].role.codeHash);
    return rows;
  };
  const action = async (name) => observer.action(name, await observeRows());
  const info = async (version) => {
    const rows = await observeRows();
    const value = await observer.cli("info", rows);
    validateProductionInfo(value, version, true);
    return { info: value, rows };
  };
  const toggle = async () => {
    const rows = await observeRows();
    const before = await observer.assertions(rows);
    assert([0, 1].includes(before.engineAssertions));
    await observer.action("pressKeep", rows);
    const expected = 1 - before.engineAssertions;
    const after = await waitForObserved(
      async () => observer.assertions(await observeRows()),
      (value) => value.engineAssertions === expected,
    );
    return { before: before.engineAssertions, after: after.engineAssertions };
  };
  try {
    await verified.revalidate();
    assert.deepEqual(await observeRows(), []);
    const mount = join(verified.directory, "installation-mount");
    await mkdir(mount, { mode: 0o700 });
    assert.equal(await realpath(mount), mount);
    let attached = false;
    try {
      await lstat(application).then(
        () => {
          throw Error("Preexisting production application");
        },
        (error) => assert.equal(error.code, "ENOENT"),
      );
      await runOwnedJourneyCommand(
        "/usr/bin/hdiutil",
        [
          "attach",
          verified.hosts.previous.dmg,
          "-readonly",
          "-nobrowse",
          "-noautoopen",
          "-mountpoint",
          mount,
        ],
        { env: verified.environment, timeoutMs: 120000, stdio: "inherit" },
      );
      attached = true;
      const source = join(mount, "Edith.app");
      assert((await lstat(source)).isDirectory());
      const actual = await boundedProductionFile(
        join(source, "Contents/MacOS/Edith"),
        16777216,
        true,
      );
      assert.equal(
        actual.sha256,
        verified.request.hosts.previous.hostExecutableSHA256,
      );
      await runOwnedJourneyCommand("/usr/bin/ditto", [source, application], {
        env: verified.environment,
        timeoutMs: 120000,
        stdio: "inherit",
      });
    } finally {
      if (attached)
        await runOwnedJourneyCommand("/usr/bin/hdiutil", ["detach", mount], {
          env: verified.environment,
          timeoutMs: 120000,
          stdio: "inherit",
        });
    }
    assert.equal(
      (await boundedProductionFile(executable, 16777216, true)).sha256,
      verified.request.hosts.previous.hostExecutableSHA256,
    );
    record("update-feed-route", await observer.prepareFeed());
    await runOwnedJourneyCommand("/usr/bin/open", ["-a", application], {
      env: verified.environment,
      timeoutMs: 120000,
      stdio: "inherit",
    });
    await waitForObserved(
      observeRows,
      (rows) => rows.filter((row) => row.role === "host").length === 1,
    );
    record("host-A-normal-launch", await requireGeneration("previous"));
    await action("finishWelcome");
    await action("goHome");
    await verified.catalog("previous");
    const installed = await observer.cli("install", await observeRows());
    validateProductionInfo(installed, "1.0.0", false);
    const enabled = await observer.cli("enable", await observeRows());
    validateProductionInfo(enabled, "1.0.0", true);
    record("previous-public-package-enabled", enabled);
    await action("widgetEditor");
    const beforeLayout = await observer.state(await observeRows());
    await action("home");
    await action("addKeep");
    await action("notch");
    await action("addKeep");
    const saved = await waitForObserved(
      async () => observer.state(await observeRows()),
      (value) =>
        Object.keys(value).some(
          (key) =>
            key.endsWith(":surfaceGrid.home") &&
            value[key] !== beforeLayout[key],
        ) &&
        Object.keys(value).some(
          (key) =>
            key.endsWith(":surfaceGrid.notch") &&
            value[key] !== beforeLayout[key],
        ),
    );
    validateProductionRestoration(saved, saved);
    const toggles = [await toggle(), await toggle(), await toggle()];
    record("original-UI-and-saved-layout", { saved, toggles });
    const beforeUpdate = await observeRows();
    await action("openEdithMenu");
    await action("checkUpdates");
    await action("installUpdate");
    await action("installRelaunch");
    const restoreDeadline = performance.now() + 60000;
    await waitForObserved(
      async (deadline) => observer.observe(beforeUpdate, deadline),
      (rows) => rows.every((row) => !row.running),
      productionRemainingBudget(restoreDeadline),
    );
    await waitForObserved(
      observeRows,
      (rows) =>
        rows.filter(
          (row) =>
            row.role === "host" &&
            row.codeHash === verified.hosts.current.role.codeHash,
        ).length === 1,
      productionRemainingBudget(restoreDeadline),
    );
    const afterHost = await requireGeneration("current");
    const retained = await info("1.0.0");
    const restored = await observer.state(afterHost);
    validateProductionRestoration(saved, restored);
    const afterAssertions = await observer.assertions(retained.rows);
    assert.equal(afterAssertions.engineAssertions, toggles.at(-1).after);
    record("different-public-host-restoration", {
      host: host(afterHost),
      retained: retained.info,
      restored,
      assertions: afterAssertions,
    });
    if (promoteCatalog) await promoteCatalog(verified.request);
    await verified.catalog("current");
    const previousOwners = (await observeRows()).filter((row) =>
      ["engine", "managedUI"].includes(row.role),
    );
    const updated = await observer.cli("update", await observeRows());
    validateProductionInfo(updated, "1.0.1", true);
    await waitForObserved(
      async (deadline) => observer.observe(previousOwners, deadline),
      (rows) => rows.every((row) => !row.running),
    );
    const final = await info("1.0.1");
    validateProductionRestoration(saved, await observer.state(final.rows));
    const packageToggle = await toggle();
    record("public-package-restoration", { updated, packageToggle });
    const sparkleRetired = await waitForObserved(observeRows, (rows) =>
      rows.every((row) => !row.role.startsWith("sparkle")),
    );
    record("natural-Sparkle-service-drain", sparkleRetired);
    completed = true;
  } catch (error) {
    failure = error;
  } finally {
    try {
      const current = await observeRows();
      const hosts = current.filter((row) => row.role === "host");
      if (hosts.length === 1) await observer.quit(hosts[0]);
      else assert.equal(hosts.length, 0);
      const retired = await waitForObserved(
        async (deadline) => observer.observe(owned, deadline),
        (rows) => rows.every((row) => !row.running),
      );
      assert.deepEqual(await observeRows(), []);
      record("natural-owned-host-engine-UI-drain", retired);
      record("update-feed-restoration", await observer.restoreFeed());
    } catch (error) {
      cleanupFailure = error;
    }
  }
  const result = {
    schema: 1,
    source: verified.request.source,
    application,
    hostSources: [
      verified.request.hosts.previous.source,
      verified.request.hosts.current.source,
    ],
    receipts,
    completed: completed && !cleanupFailure,
    primaryFailed: failure !== undefined,
    cleanupFailed: cleanupFailure !== undefined,
    artifactVerificationExecuted: true,
    nativeUIExecuted: completed,
    productionCompatibilityValidated: false,
    publicReleaseValidated: false,
    pending: ["two-real-public-release-cohort-terminal-review"],
  };
  const output = await open(
    join(verified.directory, "execution-result.json"),
    constants.O_WRONLY |
      constants.O_CREAT |
      constants.O_EXCL |
      constants.O_NOFOLLOW,
    0o600,
  );
  try {
    await output.writeFile(`${JSON.stringify(result, null, 2)}\n`);
    await output.sync();
  } finally {
    await output.close();
  }
  if (failure) throw failure;
  if (cleanupFailure) throw cleanupFailure;
  return result;
}
if (import.meta.main) {
  assert.equal(process.argv.length, 2);
  await executeProductionUpdate(process.env.PUBLIC_HOST_UPDATE_REQUEST);
}
