import { expect, test } from "bun:test";
import { execFileSync } from "node:child_process";
import { executeReleaseMutation } from "./release-asset-upload.mjs";

test("release mutation and workflow watch share one bounded deadline and output budget", () => {
  let clock = 0;
  const calls = [];
  const result = executeReleaseMutation(["release", "create", "synthetic"], {
    totalTimeoutMs: 100,
    now: () => clock,
    execute: (command, args, options) => {
      calls.push({ command, args, options });
      expect(options.killSignal).toBe("SIGKILL");
      expect(options.maxBuffer).toBe(2 * 1024 ** 2);
      if (command === "pukbot") {
        expect(options.timeout).toBe(100);
        clock = 60;
        return JSON.stringify({
          workflowUrl: "https://github.com/synthetic/fixture/actions/runs/123",
        });
      }
      expect(options.timeout).toBe(40);
      clock = 99;
      return "complete";
    },
  });
  expect(result.workflowUrl).toContain("/123");
  expect(calls.map(({ command }) => command)).toEqual(["pukbot", "gh"]);
  expect(calls[1].args).toEqual([
    "run",
    "watch",
    "123",
    "--repo",
    "synthetic/fixture",
    "--exit-status",
  ]);
});

test("expired, invalid and rejected control requests never start a watch", () => {
  for (const totalTimeoutMs of [0, -1, Infinity, 30 * 60_000 + 1]) {
    let calls = 0;
    expect(() =>
      executeReleaseMutation([], { totalTimeoutMs, execute: () => calls++ }),
    ).toThrow("deadline");
    expect(calls).toBe(0);
  }
  let clock = 0;
  let calls = 0;
  expect(() =>
    executeReleaseMutation([], {
      totalTimeoutMs: 100,
      now: () => clock,
      execute: () => {
        calls++;
        clock = 100;
        return JSON.stringify({
          workflowUrl: "https://github.com/synthetic/fixture/actions/runs/123",
        });
      },
    }),
  ).toThrow("total deadline");
  expect(calls).toBe(1);
  for (const result of [
    { ok: false, error: { message: "rejected" } },
    { workflowUrl: "https://foreign.test/synthetic/fixture/actions/runs/123" },
  ]) {
    calls = 0;
    expect(() =>
      executeReleaseMutation([], {
        execute: () => {
          calls++;
          return JSON.stringify(result);
        },
      }),
    ).toThrow();
    expect(calls).toBe(1);
  }
});

test("actual owned control timeout terminates the child without retry or false success", () => {
  let calls = 0;
  expect(() =>
    executeReleaseMutation([], {
      totalTimeoutMs: 50,
      execute: (_command, _args, options) => {
        calls++;
        return execFileSync(
          process.execPath,
          ["-e", "setTimeout(() => {}, 10000)"],
          options,
        );
      },
    }),
  ).toThrow();
  expect(calls).toBe(1);
});
