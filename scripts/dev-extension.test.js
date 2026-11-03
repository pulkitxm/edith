import { expect, test } from "bun:test";
import { waitFor } from "./dev-extension.mjs";

const id = "synthetic";
const version = "1.0.7";
const status = (state, values = {}) => ({
  status: 0,
  stdout: JSON.stringify({ id, version, state, ...values }),
});

function polling(replies, timeoutMs = 1000) {
  let time = 0;
  let cursor = 0;
  const calls = [];
  const sleeps = [];
  return {
    calls,
    sleeps,
    options: {
      timeoutMs,
      now: () => time,
      cli: (argumentsList) => {
        calls.push(argumentsList);
        return replies[Math.min(cursor++, replies.length - 1)];
      },
      sleep: async (milliseconds) => {
        sleeps.push(milliseconds);
        time += milliseconds;
      },
    },
  };
}

test("activation succeeds only for the requested extension and version", async () => {
  const ready = {
    id,
    version,
    state: "active",
    timings: { app: { startMs: 2 } },
  };
  const run = polling([
    status("active", { version: "1.0.6" }),
    status("starting"),
    { status: 0, stdout: JSON.stringify(ready) },
  ]);
  expect(await waitFor(id, version, run.options)).toEqual(ready);
  expect(run.calls).toEqual(
    Array(3).fill(["extensions", "info", id, "--json"]),
  );
  expect(run.sleeps).toEqual([250, 250]);
});

test("an idle installed version is enabled once and checked until active", async () => {
  const run = polling([
    status("idle"),
    status("active"),
    status("idle"),
    status("active"),
  ]);
  expect((await waitFor(id, version, run.options)).state).toBe("active");
  expect(run.calls).toEqual([
    ["extensions", "info", id, "--json"],
    ["extensions", "enable", id, "--json"],
    ["extensions", "info", id, "--json"],
    ["extensions", "info", id, "--json"],
  ]);
});

test("failed activation rejects with the host failure reason", async () => {
  const run = polling([
    status("failed", { failureReason: "Synthetic startup refused." }),
  ]);
  await expect(waitFor(id, version, run.options)).rejects.toThrow(
    "synthetic 1.0.7 failed to start: Synthetic startup refused.",
  );
  expect(run.calls).toHaveLength(1);
  expect(run.sleeps).toEqual([]);
});

test("a failed activation remains a failure without diagnostic details", async () => {
  const run = polling([status("failed", { failureReason: null })]);
  await expect(waitFor(id, version, run.options)).rejects.toThrow(
    "synthetic 1.0.7 failed to start",
  );
});

test("a previous version's failure cannot be mistaken for the new build's result", async () => {
  const run = polling([
    status("failed", { version: "1.0.6", failureReason: "Retired version." }),
    status("active"),
  ]);
  expect((await waitFor(id, version, run.options)).version).toBe(version);
  expect(run.sleeps).toEqual([250]);
});

test("enable errors fail immediately and preserve their actual diagnostics", async () => {
  for (const failure of [
    { status: 4, stderr: "Synthetic approval required.\n" },
    { status: null, error: new Error("Synthetic CLI unavailable.") },
    { status: 4, stdout: "Synthetic enable rejected.\n" },
  ]) {
    const run = polling([status("idle"), failure]);
    await expect(waitFor(id, version, run.options)).rejects.toThrow(
      `synthetic 1.0.7 could not be enabled: ${failure.error?.message || failure.stderr?.trim() || failure.stdout?.trim()}`,
    );
    expect(run.calls).toHaveLength(2);
    expect(run.sleeps).toEqual([]);
  }
});

test("a timeout reports the version and state that actually remained loaded", async () => {
  const run = polling([status("active", { version: "1.0.6" })]);
  await expect(waitFor(id, version, run.options)).rejects.toThrow(
    "synthetic 1.0.7 did not become active within 1s; last observed: 1.0.6 (active)",
  );
  expect(run.calls).toHaveLength(4);
  expect(run.sleeps).toEqual([250, 250, 250, 250]);
});

test("transport errors can recover during startup and remain visible on timeout", async () => {
  const offline = { status: 1, stderr: "Synthetic host is starting.\n" };
  const recovering = polling([offline, status("active")]);
  expect((await waitFor(id, version, recovering.options)).state).toBe("active");
  const unavailable = polling([offline]);
  await expect(waitFor(id, version, unavailable.options)).rejects.toThrow(
    "last observed: status check failed: Synthetic host is starting.",
  );
});

test("polling respects the deadline even when shorter than the poll interval", async () => {
  const run = polling([status("starting")], 100);
  await expect(waitFor(id, version, run.options)).rejects.toThrow(
    "did not become active within 0.1s; last observed: 1.0.7 (starting)",
  );
  expect(run.sleeps).toEqual([100]);
});

test("malformed and foreign status responses never count as readiness", async () => {
  for (const reply of [
    { status: 0, stdout: "invalid" },
    { status: 0, stdout: "null" },
    status("active", { id: "other" }),
    status(null),
  ]) {
    const run = polling([reply]);
    await expect(waitFor(id, version, run.options)).rejects.toThrow(
      "synthetic 1.0.7: invalid extension status",
    );
  }
});
