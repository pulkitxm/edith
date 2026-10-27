import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import {
  batchExtensionBuilds,
  buildCost,
  maximumBuildBatches,
} from "./extension-build-batches.mjs";

const definitions = JSON.parse(
  readFileSync("Extensions/manifest.json", "utf8"),
);
const entry = (id) => ({
  id,
  version: "1.0.0",
  supportFingerprint: "a".repeat(64),
});

test("every planned extension builds in exactly one balanced batch", () => {
  const include = definitions.map(({ id }) => entry(id));
  const batches = batchExtensionBuilds(include);
  expect(batches).toHaveLength(maximumBuildBatches);
  const ids = batches.flatMap((batch) => batch.ids.split(" "));
  expect(ids.toSorted()).toEqual(include.map(({ id }) => id).toSorted());
  expect(new Set(ids).size).toBe(ids.length);
  const costs = batches.map(({ cost }) => cost);
  const heaviest = Math.max(...include.map(({ id }) => buildCost(id)));
  expect(Math.max(...costs) - Math.min(...costs)).toBeLessThanOrEqual(heaviest);
  expect(batches.filter(({ camera }) => camera)).toHaveLength(1);
  for (const batch of batches) {
    expect(batch.builds.split(" ").map((build) => build.split("=")[0])).toEqual(
      batch.ids.split(" "),
    );
    for (const id of batch.ids.split(" "))
      for (const path of ["build.json", "Package.swift", "Sources"])
        expect(batch.supportPaths).toContain(
          `local/extension-support/${id}_*/${path}`,
        );
    expect(batch.supportKey).toMatch(/^[a-f0-9]{64}$/);
  }
});

test("small plans keep one extension per job and carry their versions", () => {
  const batches = batchExtensionBuilds([
    { ...entry("herdr"), version: "1.0.4" },
    entry("keepAwake"),
  ]);
  expect(batches.map(({ ids, builds }) => [ids, builds])).toEqual([
    ["herdr", "herdr=1.0.4"],
    ["keepAwake", "keepAwake=1.0.0"],
  ]);
  expect(batchExtensionBuilds([])).toEqual([]);
});

test("support cache keys change when any member fingerprint changes", () => {
  const [before] = batchExtensionBuilds(
    [entry("emoji"), entry("clipboard")],
    1,
  );
  const [after] = batchExtensionBuilds(
    [
      entry("emoji"),
      { ...entry("clipboard"), supportFingerprint: "b".repeat(64) },
    ],
    1,
  );
  expect(before.ids).toBe("clipboard emoji");
  expect(before.supportKey).not.toBe(after.supportKey);
});

test("malformed or duplicated plan entries are rejected", () => {
  for (const include of [
    [entry("emoji"), entry("emoji")],
    [{ ...entry("emoji"), id: "bad id" }],
    [{ ...entry("emoji"), version: "1.0" }],
    [{ ...entry("emoji"), supportFingerprint: "short" }],
    [{ ...entry("emoji"), id: "emoji;rm" }],
  ])
    expect(() => batchExtensionBuilds(include)).toThrow(
      "Invalid extension build plan",
    );
});
