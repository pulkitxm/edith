import assert from "node:assert/strict";

const exact = (value, keys) =>
  assert.deepEqual(Object.keys(value).sort(), [...keys].sort());
const birth = (value) =>
  typeof value === "string" &&
  !/[\0\r\n]/.test(value) &&
  /^[0-9]+\.[0-9]+$/.test(value);

export function validateSparkleProcess(row, fixture) {
  exact(row, ["role", "pid", "birth", "uid", "executable", "running"]);
  assert(["host", "engine", "managedUI"].includes(row.role));
  assert(Number.isInteger(row.pid) && row.pid > 1);
  assert(birth(row.birth));
  assert.equal(row.uid, fixture.expectedUID);
  assert.equal(
    row.executable,
    row.role === "host"
      ? `${fixture.directory}/Host.app/Contents/MacOS/Edith`
      : fixture.ownedRolePaths[row.role],
  );
  assert.equal(typeof row.running, "boolean");
  return Object.freeze({ ...row });
}

export function validateSparkleSnapshot(
  rows,
  fixture,
  { complete = false } = {},
) {
  assert(Array.isArray(rows) && rows.length <= 3);
  const result = rows.map((row) => validateSparkleProcess(row, fixture));
  assert.equal(new Set(result.map(({ role }) => role)).size, result.length);
  assert.equal(new Set(result.map(({ pid }) => pid)).size, result.length);
  if (complete) {
    assert.deepEqual(result.map(({ role }) => role).sort(), [
      "engine",
      "host",
      "managedUI",
    ]);
    assert(result.every(({ running }) => running));
  }
  return result;
}

export function createSparkleProcessLedger(fixture) {
  let before;
  let installed;
  let reopened;
  const identity = ({ running: _running, ...row }) => row;
  const absent = (expected, actual) => {
    assert.equal(actual.length, expected.length);
    for (let index = 0; index < expected.length; index++) {
      validateSparkleProcess(actual[index], fixture);
      assert.deepEqual(identity(actual[index]), identity(expected[index]));
      assert.equal(actual[index].running, false);
    }
    return actual.map((row) => ({ ...row }));
  };
  return {
    arm(rows) {
      assert(!before, "Installation may be armed only once");
      before = validateSparkleSnapshot(rows, fixture, { complete: true });
      return before.map((row) => ({ ...row }));
    },
    installed(rows, oldObservations) {
      assert(
        before && !installed,
        "Installation requires the original complete role ledger",
      );
      absent(before, oldObservations);
      const current = validateSparkleSnapshot(rows, fixture);
      assert.equal(current.length, 1);
      assert.equal(current[0].role, "host");
      assert.equal(current[0].running, true);
      for (const old of before) {
        assert.notEqual(current[0].pid, old.pid);
        assert.notEqual(current[0].birth, old.birth);
      }
      installed = current[0];
      return { old: oldObservations, host: installed };
    },
    reopened(rows) {
      assert(installed && !reopened);
      const current = validateSparkleSnapshot(rows, fixture, {
        complete: true,
      });
      const host = current.find(({ role }) => role === "host");
      assert.deepEqual(identity(host), identity(installed));
      for (const role of ["engine", "managedUI"]) {
        const old = before.find((row) => row.role === role);
        const next = current.find((row) => row.role === role);
        assert.notEqual(next.pid, old.pid);
        assert.notEqual(next.birth, old.birth);
      }
      reopened = current;
      return current.map((row) => ({ ...row }));
    },
    disabled(rows) {
      assert(reopened);
      return absent(
        reopened.filter(({ role }) => role !== "host"),
        rows,
      );
    },
    original() {
      assert(before);
      return before.map((row) => ({ ...row }));
    },
  };
}

export async function retireSparkleProcesses(
  rows,
  fixture,
  { observe, signal, pause },
) {
  assert(Array.isArray(rows) && rows.length > 0 && rows.length <= 6);
  const unique = new Set();
  for (const row of rows) {
    validateSparkleProcess(row, fixture);
    const key = `${row.pid}:${row.birth}`;
    assert(!unique.has(key));
    unique.add(key);
  }
  const current = async (expected) => {
    const actual = await observe(expected);
    validateSparkleProcess(actual, fixture);
    assert.deepEqual(
      { ...actual, running: false },
      { ...expected, running: false },
    );
    return actual;
  };
  for (const row of [...rows].reverse()) {
    if ((await current(row)).running) {
      await signal(row, "TERM");
      for (
        let attempt = 0;
        attempt < 20 && (await current(row)).running;
        attempt++
      )
        await pause(100);
      if ((await current(row)).running) {
        await signal(row, "KILL");
        for (
          let attempt = 0;
          attempt < 20 && (await current(row)).running;
          attempt++
        )
          await pause(100);
      }
    }
    assert.equal(
      (await current(row)).running,
      false,
      "Owned generation remained after bounded retirement",
    );
  }
  return Promise.all(rows.map(current));
}
