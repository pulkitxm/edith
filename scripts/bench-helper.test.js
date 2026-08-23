import { expect, test } from "bun:test";
import { $ } from "bun";

const fixture = "scripts/fixtures/bench-helper.samples";

test("benchmark fixtures produce stable machine-readable percentiles", async () => {
  const result = await $`./scripts/bench-helper.sh --fixture ${fixture} --label ${"quoted \"run\""}`
    .quiet()
    .json();

  expect(result).toEqual({
    schemaVersion: 1,
    label: 'quoted "run"',
    process: "fixture",
    pid: 0,
    samples: 5,
    cpuPercent: { median: 0.3, p95: 1.5, peak: 1.5 },
    rssMB: { median: 110, p95: 140, peak: 140 },
    idleWakeups: { median: 3 },
  });
});

test("benchmark text output carries the reviewable summary", async () => {
  const output = await $`./scripts/bench-helper.sh --fixture ${fixture} --output text`
    .quiet()
    .text();

  expect(output.trim()).toBe(
    "fixture | samples 5 | cpu median 0.300% p95 1.500% peak 1.500% | rss median 110.000 MB p95 140.000 MB peak 140.000 MB",
  );
});

test("benchmark input validation rejects ambiguous runs", async () => {
  const result = Bun.spawnSync([
    "./scripts/bench-helper.sh",
    "--fixture",
    fixture,
    "--samples",
    "0",
  ]);

  expect(result.exitCode).toBe(2);
  expect(result.stderr.toString()).toContain("--samples must be a positive integer");
});
