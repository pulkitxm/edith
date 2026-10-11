import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { constants } from "node:fs";
import { lstat, open, realpath } from "node:fs/promises";
import { join } from "node:path";
import { canonicalSparkleJSON } from "./prepare-update.mjs";
import { createSparkleProcessLedger } from "./process-ledger.mjs";
import { validateSparkleRecipe } from "./server.mjs";

const digest = (bytes) => createHash("sha256").update(bytes).digest("hex");
const exact = (value, keys) =>
  assert.deepEqual(Object.keys(value).sort(), [...keys].sort());
export function validateSparkleEvents(events, fixture) {
  assert(Array.isArray(events) && events.length > 0 && events.length <= 32);
  for (const event of events) {
    exact(
      event,
      event.category === "rejected"
        ? ["schema", "sourceCommit", "session", "category", "pid", "errors"]
        : ["schema", "sourceCommit", "session", "category", "pid"],
    );
    assert.equal(event.schema, 1);
    assert.equal(event.sourceCommit, fixture.sourceCommit);
    assert.equal(event.session, fixture.session);
    assert(Number.isInteger(event.pid) && event.pid > 1);
    assert(
      [
        "downloaded",
        "extracted",
        "installing",
        "relaunching",
        "rejected",
      ].includes(event.category),
    );
    if (event.category === "rejected") {
      assert(
        Array.isArray(event.errors) &&
          event.errors.length > 0 &&
          event.errors.length <= 4,
      );
      for (const error of event.errors) {
        exact(error, ["domain", "code"]);
        assert(["SUSparkleErrorDomain", "other"].includes(error.domain));
        assert(Number.isSafeInteger(error.code));
      }
    }
  }
  return events.map((event) => structuredClone(event));
}

export async function readSparkleEvents(directory, fixture) {
  assert.equal(directory, fixture.directory);
  assert.equal(await realpath(directory), directory);
  const root = await lstat(directory, { bigint: true });
  assert(
    root.isDirectory() &&
      root.uid === BigInt(fixture.expectedUID) &&
      (root.mode & 0o777n) === 0o700n,
  );
  const file = await open(
    join(directory, "sparkle-events.jsonl"),
    constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK,
  );
  try {
    const before = await file.stat({ bigint: true });
    assert(
      before.isFile() &&
        before.nlink === 1n &&
        before.uid === root.uid &&
        (before.mode & 0o7777n) === 0o600n &&
        before.size > 0n &&
        before.size <= 8192n,
    );
    const bytes = Buffer.alloc(Number(before.size) + 1);
    const { bytesRead } = await file.read(bytes, 0, bytes.length, 0);
    assert.equal(BigInt(bytesRead), before.size);
    const after = await file.stat({ bigint: true });
    for (const field of [
      "dev",
      "ino",
      "uid",
      "mode",
      "nlink",
      "size",
      "mtimeNs",
      "ctimeNs",
    ])
      assert.equal(before[field], after[field]);
    const pathState = await lstat(join(directory, "sparkle-events.jsonl"), {
      bigint: true,
    });
    for (const field of [
      "dev",
      "ino",
      "uid",
      "mode",
      "nlink",
      "size",
      "mtimeNs",
      "ctimeNs",
    ])
      assert.equal(after[field], pathState[field]);
    const finalRoot = await lstat(directory, { bigint: true });
    for (const field of ["dev", "ino", "uid", "mode"])
      assert.equal(root[field], finalRoot[field]);
    assert.equal(await realpath(directory), directory);
    const text = bytes.subarray(0, bytesRead).toString("utf8");
    assert(text.endsWith("\n"));
    return validateSparkleEvents(
      text
        .slice(0, -1)
        .split("\n")
        .map((line) => JSON.parse(line)),
      fixture,
    );
  } finally {
    await file.close();
  }
}

export function validateSparkleAction(request, fixture) {
  exact(request, [
    "operation",
    "hostIdentifier",
    "sourceCommit",
    "previousVersion",
    "nextVersion",
  ]);
  assert(
    [
      "armSparkle",
      "awaitSparkleInstall",
      "captureSparkleReopened",
      "captureSparkleDisabled",
      "captureSparkleResumed",
      "captureSparkleUpdated",
      "verifySparkleFinished",
      "verifySparkleRejection",
    ].includes(request.operation),
  );
  assert.equal(request.hostIdentifier, fixture.identifier);
  assert.equal(request.sourceCommit, fixture.sourceCommit);
  assert.equal(request.previousVersion, "1.0.0");
  assert.equal(request.nextVersion, "2.0.0");
}

export function createSparkleActions({
  preparation,
  captured,
  bindProtected,
  readState,
  readEvents,
  inventory,
  switchCatalog,
  server,
  recipe = "valid",
  pause = (ms) => new Promise((resolve) => setTimeout(resolve, ms)),
  attempts = 120,
  verifyRemoved,
}) {
  assert(["valid", "wrong-signature", "tampered-archive"].includes(recipe));
  assert(Number.isInteger(attempts) && attempts > 0 && attempts <= 120);
  let fixture = preparation.fixture;
  let ledger;
  let original;
  let installation;
  let reopened;
  let disabled;
  let negative;
  let resumed;
  let updated;
  let finished;
  let busy = false;
  const stateValue = async () => (await readState()).state;
  const inventoryMatches = (actual, expected) =>
    assert.deepEqual(actual, expected);
  const poll = async (action) => {
    let last;
    for (let index = 0; index < attempts; index++) {
      try {
        return await action();
      } catch (error) {
        last = error;
      }
      await pause(500);
    }
    throw last ?? Error("Sparkle observation deadline exceeded");
  };
  const response = (operation) => ({
    schema: 1,
    operation,
    hostIdentifier: fixture.identifier,
    sourceCommit: fixture.sourceCommit,
    outcome: "observed",
  });
  const downloaded = () => {
    const requests = server
      .observations()
      .filter((row) => row.category === "archive" && row.complete);
    assert.equal(requests.length, 1);
    assert.equal(requests[0].bytes, fixture.archiveBytes);
    return requests[0].bytes;
  };
  const preserved = (state) => {
    assert.equal(state.hostIdentifier, fixture.identifier);
    assert.equal(state.sourceCommit, fixture.sourceCommit);
    assert.equal(state.protectedDataUnchanged, true);
    assert.equal(state.declinedPermissionRequests, 0);
    for (const [stateKey, hashKey] of [
      ["home", "homeLayout"],
      ["notch", "notchLayout"],
    ])
      assert.equal(
        digest(canonicalSparkleJSON(state[stateKey])),
        fixture.protectedSHA256[hashKey],
      );
  };
  return {
    async action(request) {
      validateSparkleAction(request, fixture);
      assert(!busy);
      busy = true;
      try {
        if (request.operation === "armSparkle") {
          assert(!original);
          validateSparkleRecipe(server.recipe(), preparation, recipe);
          const state = await stateValue();
          fixture = bindProtected(fixture, state);
          inventoryMatches(await inventory("1.0.0"), preparation.initial);
          ledger = createSparkleProcessLedger(fixture);
          original = ledger.arm(await captured.snapshot());
          return response(request.operation);
        }
        assert(
          original,
          "The actual complete role ledger must precede updater actions",
        );
        if (request.operation === "awaitSparkleInstall") {
          assert(recipe === "valid" && !installation);
          const observed = await poll(async () => {
            const old = await Promise.all(
              original.map((row) => captured.observe(row)),
            );
            assert(old.every((row) => !row.running));
            const rows = await captured.snapshot();
            assert(rows.some((row) => row.role === "host"));
            const events = validateSparkleEvents(await readEvents(), fixture);
            assert(
              events.every(
                (row) =>
                  row.pid === original.find((row) => row.role === "host").pid,
              ),
            );
            assert.deepEqual(
              events.map((row) => row.category),
              ["downloaded", "extracted", "installing", "relaunching"],
            );
            downloaded();
            const application = await inventory("2.0.0");
            inventoryMatches(application, preparation.installed);
            const state = await stateValue();
            assert.equal(state.applicationVersion, "2.0.0");
            preserved(state);
            assert.equal(
              digest(
                canonicalSparkleJSON({
                  active: state.active,
                  versions: state.versions,
                }),
              ),
              fixture.protectedSHA256.installedSelection,
            );
            return { old, rows, application, events };
          });
          const installed = ledger.installed(observed.rows, observed.old);
          await switchCatalog();
          installation = { ...observed, host: installed.host };
          return response(request.operation);
        }
        if (request.operation === "captureSparkleReopened") {
          assert(installation && !reopened);
          reopened = ledger.reopened(await captured.snapshot());
          preserved(await stateValue());
          return response(request.operation);
        }
        if (request.operation === "captureSparkleDisabled") {
          assert(reopened && !disabled);
          const rows = await poll(async () => {
            const observed = await Promise.all(
              reopened
                .filter((row) => row.role !== "host")
                .map((row) => captured.observe(row)),
            );
            ledger.disabled(observed);
            return observed;
          });
          disabled = ledger.disabled(rows);
          assert.deepEqual(await captured.snapshot(), [
            reopened.find((row) => row.role === "host"),
          ]);
          preserved(await stateValue());
          return response(request.operation);
        }
        if (request.operation === "captureSparkleResumed") {
          assert(disabled && !resumed);
          resumed = await poll(async () => {
            const rows = await captured.snapshot();
            assert(rows.some((row) => row.role === "engine" && row.running));
            const state = await stateValue();
            assert.equal(state.versions.calendar, "1.0.0");
            preserved(state);
            return rows;
          });
          return response(request.operation);
        }
        if (request.operation === "captureSparkleUpdated") {
          assert(resumed && !updated);
          updated = await poll(async () => {
            const rows = await captured.snapshot();
            assert.deepEqual(rows.map((row) => row.role).sort(), [
              "engine",
              "host",
              "managedUI",
            ]);
            assert(rows.every((row) => row.running));
            assert.deepEqual(
              rows.find((row) => row.role === "host"),
              installation.host,
            );
            for (const old of resumed.filter((row) => row.role !== "host")) {
              const next = rows.find((row) => row.role === old.role);
              assert.notEqual(next.pid, old.pid);
              assert.notEqual(next.birth, old.birth);
            }
            assert.equal(
              rows.find((row) => row.role === "managedUI").executable,
              fixture.ownedRolePaths.managedUI.replace(
                "/arm64/1.0.0/calendar/",
                "/arm64/1.1.0/calendar/",
              ),
            );
            const prior = await Promise.all(
              resumed
                .filter((row) => row.role !== "host")
                .map((row) => captured.observe(row)),
            );
            assert(prior.every((row) => !row.running));
            const state = await stateValue();
            assert.equal(state.versions.calendar, "1.1.0");
            preserved(state);
            return rows;
          });
          return response(request.operation);
        }
        if (request.operation === "verifySparkleFinished") {
          assert(updated && !finished);
          const absent = await Promise.all(
            updated
              .filter((row) => row.role !== "host")
              .map((row) => captured.observe(row)),
          );
          assert(absent.every((row) => !row.running));
          assert.deepEqual(await captured.snapshot(), [installation.host]);
          const state = await stateValue();
          preserved(state);
          assert.deepEqual(state.downloaded, []);
          assert.deepEqual(state.workers, {});
          assert.deepEqual(state.presentationCounts, {});
          assert.equal(typeof verifyRemoved, "function");
          const removed = await verifyRemoved();
          assert.deepEqual(removed, ["1.0.0", "1.1.0"]);
          finished = { absent, removed, naturalDisableValidated: true };
          return response(request.operation);
        }
        assert(recipe !== "valid" && !negative);
        const rejected = await poll(async () => {
          const events = validateSparkleEvents(await readEvents(), fixture);
          assert(
            events.every(
              (row) =>
                row.pid === original.find((row) => row.role === "host").pid,
            ),
          );
          assert(
            !events.some((row) =>
              ["installing", "relaunching"].includes(row.category),
            ),
          );
          const failures = events.filter((row) => row.category === "rejected");
          assert.equal(failures.length, 1);
          assert(
            failures[0].errors.some(
              (row) =>
                row.domain === "SUSparkleErrorDomain" &&
                [3001, 3002].includes(row.code),
            ),
          );
          downloaded();
          inventoryMatches(await inventory("1.0.0"), preparation.initial);
          assert.deepEqual(await captured.snapshot(), original);
          const state = await stateValue();
          assert.equal(state.applicationVersion, "1.0.0");
          preserved(state);
          return events;
        });
        negative = {
          recipe,
          events: rejected,
          archive: validateSparkleRecipe(server.recipe(), preparation, recipe),
          actualSparkleRejectionValidated: true,
        };
        return response(request.operation);
      } finally {
        busy = false;
      }
    },
    proof() {
      return structuredClone({
        fixture,
        original,
        installation,
        reopened,
        disabled,
        resumed,
        updated,
        finished,
        negative,
      });
    },
  };
}
