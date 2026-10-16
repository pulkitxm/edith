import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { test } from "node:test";
import {
  compareSystemVersions,
  parseSystemVersion,
  validateMinimumSystemVersion,
} from "./extension-system-version.mjs";

test("AudioMixer manifest preserves the actual minor release requirement", async () => {
  const manifest = JSON.parse(
    await readFile("Extensions/manifest.json", "utf8"),
  );
  const audioMixer = manifest.find(({ id }) => id === "audioMixer");
  assert.equal(audioMixer.minimumSystemVersion, "14.4.0");
  for (const entry of manifest) {
    validateMinimumSystemVersion(entry.minimumSystemVersion);
    assert.ok(
      entry.sharedInputs.includes("scripts/extension-system-version.mjs"),
    );
  }
  for (const [system, allowed] of [
    ["14.3.0", false],
    ["14.4.0", true],
    ["14.5.0", true],
    ["15.0.0", true],
  ])
    assert.equal(
      compareSystemVersions(system, audioMixer.minimumSystemVersion) >= 0,
      allowed,
    );
});

test("system versions compare major, minor and patch numerically", () => {
  assert.deepEqual(parseSystemVersion("14.4.1"), [14, 4, 1]);
  assert.equal(compareSystemVersions("14.4.0", "14.4.0"), 0);
  assert.equal(compareSystemVersions("14.4.1", "14.4.0"), 1);
  assert.equal(compareSystemVersions("14.10.0", "14.4.0"), 1);
  assert.equal(compareSystemVersions("15.0.0", "14.99.0"), 1);
});

test("malformed and major-only system versions fail closed", () => {
  for (const value of [
    14,
    14.4,
    null,
    {},
    "14",
    "14.4",
    "14.4.0.0",
    "14..0",
    "14.04.0",
    "014.4.0",
    "14.4.-1",
    "14.4.+1",
    " 14.4.0",
    "14.4.0\n",
    "14.4.0-beta",
    "14.4.٠",
    "14.4.2147483648",
    "",
  ]) {
    assert.throws(() => parseSystemVersion(value));
    assert.throws(() => validateMinimumSystemVersion(value));
  }
  assert.throws(() => validateMinimumSystemVersion("13.99.0"));
});
