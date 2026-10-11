import { expect, test } from "bun:test";
import {
  createSparkleProcessLedger,
  retireSparkleProcesses,
  validateSparkleSnapshot,
} from "./hosted-sparkle-update/process-ledger.mjs";

const fixture = {
  directory:
    "/Users/runner/Applications/Edith Remote Fixture Journey 00000000-0000-4000-8000-000000000001",
  expectedUID: 501,
  ownedRolePaths: { engine: "/owned/engine", managedUI: "/owned/ui" },
};
const rows = (offset = 0) =>
  ["host", "engine", "managedUI"].map((role, index) => ({
    role,
    pid: 100 + index + offset,
    birth: `${10 + offset}.${index}`,
    uid: 501,
    executable:
      role === "host"
        ? `${fixture.directory}/Host.app/Contents/MacOS/Edith`
        : fixture.ownedRolePaths[role],
    running: true,
  }));
const absent = (values) => values.map((row) => ({ ...row, running: false }));

test("actual complete old roles must exit before a native new host and distinct reopened roles qualify", () => {
  const ledger = createSparkleProcessLedger(fixture);
  const old = rows();
  ledger.arm(old);
  const next = rows(100);
  expect(ledger.installed([next[0]], absent(old)).host).toEqual(next[0]);
  expect(ledger.reopened(next)).toEqual(next);
  expect(ledger.disabled(absent(next.slice(1)))).toEqual(absent(next.slice(1)));
});

test("empty, duplicate, foreign and reused generation claims cannot qualify retention or drain", () => {
  for (const candidate of [
    [],
    rows().slice(0, 2),
    [rows()[0], rows()[0]],
    rows().map((row) => ({ ...row, uid: 502 })),
    rows().map((row) => ({ ...row, executable: "/foreign" })),
  ])
    expect(() =>
      validateSparkleSnapshot(candidate, fixture, { complete: true }),
    ).toThrow();
  const ledger = createSparkleProcessLedger(fixture);
  const old = rows();
  ledger.arm(old);
  expect(() => ledger.installed([rows(100)[0]], old)).toThrow();
  expect(() => ledger.installed([old[0]], absent(old))).toThrow();
  ledger.installed([rows(100)[0]], absent(old));
  expect(() => ledger.reopened([rows(100)[0], old[1], old[2]])).toThrow();
});

test("failure retirement signals only independently unchanged live generations and observes exit", async () => {
  const originals = rows();
  const live = new Set(originals.map(({ pid }) => pid));
  const signals = [];
  const result = await retireSparkleProcesses(originals, fixture, {
    observe: async (row) => ({ ...row, running: live.has(row.pid) }),
    signal: async (row, kind) => {
      signals.push([row.pid, kind]);
      live.delete(row.pid);
    },
    pause: async () => {},
  });
  expect(signals).toEqual([
    [102, "TERM"],
    [101, "TERM"],
    [100, "TERM"],
  ]);
  expect(result.every(({ running }) => !running)).toBe(true);
});

test("PID reuse and changed executable or UID refuse every cleanup signal", async () => {
  for (const mutation of [
    { birth: "999.9" },
    { executable: "/foreign" },
    { uid: 502 },
  ]) {
    const signals = [];
    await expect(
      retireSparkleProcesses([rows()[0]], fixture, {
        observe: async (row) => ({ ...row, ...mutation }),
        signal: async () => signals.push(true),
        pause: async () => {},
      }),
    ).rejects.toThrow();
    expect(signals).toEqual([]);
  }
});

test("an unexited owned process remains a failure after both bounded signal stages", async () => {
  const signals = [];
  await expect(
    retireSparkleProcesses([rows()[0]], fixture, {
      observe: async (row) => row,
      signal: async (_row, kind) => signals.push(kind),
      pause: async () => {},
    }),
  ).rejects.toThrow();
  expect(signals).toEqual(["TERM", "KILL"]);
});

test("only the two declared Calendar package paths can enter post-update cleanup authority", () => {
  const original =
    "/owned/Extensions/calendar/edith-host-2/arm64/1.0.0/calendar/ExtensionCarrier.app/Contents/Extensions/ExtensionWorker.appex/Contents/MacOS/Edith";
  const closed = {
    ...fixture,
    ownedRolePaths: { ...fixture.ownedRolePaths, managedUI: original },
  };
  const candidate = { ...rows()[2], executable: original };
  expect(validateSparkleSnapshot([candidate], closed)).toEqual([candidate]);
  const updated = {
    ...candidate,
    executable: original.replace("/1.0.0/", "/1.1.0/"),
  };
  expect(validateSparkleSnapshot([updated], closed)).toEqual([updated]);
  for (const version of ["1.2.0", "../1.1.0", "1.1.0\n"])
    expect(() =>
      validateSparkleSnapshot(
        [
          {
            ...candidate,
            executable: original.replace("/1.0.0/", `/${version}/`),
          },
        ],
        closed,
      ),
    ).toThrow();
});
