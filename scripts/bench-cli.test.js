import { expect, test } from "bun:test";
import {
  measureScenario,
  parseArguments,
  percentile,
  summarizeDurations,
} from "./bench-cli.mjs";

test("CLI benchmark arguments have reproducible defaults", () => {
  expect(parseArguments([])).toEqual({
    binary: "build/Build/Products/Release/ed",
    samples: 30,
    warmups: 3,
    label: "Edith CLI Release",
  });
  expect(
    parseArguments([
      "--binary",
      "/tmp/ed",
      "--samples",
      "5",
      "--warmups",
      "2",
      "--label",
      "fixture",
    ]),
  ).toEqual({
    binary: "/tmp/ed",
    samples: 5,
    warmups: 2,
    label: "fixture",
  });
});

test("CLI benchmark arguments reject ambiguous sample counts", () => {
  expect(() => parseArguments(["--samples", "0"])).toThrow(
    "--samples must be a positive integer",
  );
  expect(() => parseArguments(["--warmups", "1.5"])).toThrow(
    "--warmups must be a positive integer",
  );
});

test("CLI benchmark uses nearest-rank percentiles", () => {
  const values = [5, 1, 4, 3, 2];
  expect(percentile(values, 50)).toBe(3);
  expect(percentile(values, 95)).toBe(5);
  expect(summarizeDurations(values)).toEqual({ p50: 3, p95: 5, peak: 5 });
});

test("CLI benchmark retains every raw sample", () => {
  const durations = [1, 2, 3, 4, 5, 6];
  let invocation = 0;
  const result = measureScenario(
    "/tmp/ed",
    { name: "fixture", arguments: ["--help"] },
    5,
    1,
    () => ({
      duration: durations[invocation++],
      exitCode: 0,
      stdoutBytes: 12,
      stderrBytes: 0,
    }),
  );

  expect(result.durationMS).toEqual({ p50: 4, p95: 6, peak: 6 });
  expect(result.raw).toEqual([
    { durationMS: 2, exitCode: 0, stdoutBytes: 12, stderrBytes: 0 },
    { durationMS: 3, exitCode: 0, stdoutBytes: 12, stderrBytes: 0 },
    { durationMS: 4, exitCode: 0, stdoutBytes: 12, stderrBytes: 0 },
    { durationMS: 5, exitCode: 0, stdoutBytes: 12, stderrBytes: 0 },
    { durationMS: 6, exitCode: 0, stdoutBytes: 12, stderrBytes: 0 },
  ]);
});
