import { expect, test } from "bun:test";
import { mergeExtensionCatalog } from "./extension-publish.mjs";

const packageRecord = {
  id: "calendar",
  version: "1.0.0",
  hostABI: "runtime-1",
  architecture: "arm64",
  sha256: "original",
};
const previous = { schemaVersion: 1, revision: 1, packages: [packageRecord] };

test("app upgrades retain packages for previous host contracts", () => {
  const upgraded = {
    ...packageRecord,
    hostABI: "runtime-2",
    sha256: "new-host",
  };
  expect(mergeExtensionCatalog(previous, [upgraded], 2).packages).toEqual([
    packageRecord,
    upgraded,
  ]);
});

test("publication retries cannot replace an existing version", () => {
  expect(mergeExtensionCatalog(previous, [packageRecord], 2).packages).toEqual([
    packageRecord,
  ]);
  expect(() =>
    mergeExtensionCatalog(
      previous,
      [{ ...packageRecord, sha256: "tampered" }],
      2,
    ),
  ).toThrow("immutable");
});

test("catalog publication always increases the revision", () => {
  for (const revision of [0, 1, NaN, Number.MAX_SAFE_INTEGER + 1])
    expect(() => mergeExtensionCatalog(previous, [], revision)).toThrow(
      "increase",
    );
});
