import { expect, test } from "bun:test";
import {
  catalogAssetURL,
  catalogPointer,
  parseCatalogPointer,
  verifyCatalogPointerData,
} from "./extension-catalog-pointer.mjs";

const data = Buffer.from("synthetic signed envelope");
const pointer = catalogPointer(data, 42);

test("immutable pointer bounds its fixed asset without accepting a supplied URL", () => {
  expect(parseCatalogPointer(JSON.stringify(pointer))).toEqual(pointer);
  expect(verifyCatalogPointerData(data, pointer)).toBe(data);
  expect(catalogAssetURL(pointer)).toBe(
    "https://github.com/pulkitxm/edith/releases/download/extension-catalog-v1/catalog-42.json",
  );
  for (const change of [
    { schemaVersion: 2 },
    { revision: 0 },
    { revision: 42.5 },
    { assetName: "catalog.json" },
    { assetName: "../catalog-42.json" },
    { bytes: 0 },
    { bytes: 3145729 },
    { bytes: true },
    { sha256: "A".repeat(64) },
    { url: "https://untrusted.invalid/catalog" },
  ])
    expect(() =>
      parseCatalogPointer(JSON.stringify({ ...pointer, ...change })),
    ).toThrow();
  for (const body of [
    "null",
    "[]",
    "broken",
    " ".repeat(1025),
    JSON.stringify(pointer).replace(
      '"revision":42',
      '"revision":41,"revision":42',
    ),
  ])
    expect(() => parseCatalogPointer(body)).toThrow();
  expect(() =>
    verifyCatalogPointerData(Buffer.from("tampered"), pointer),
  ).toThrow();
  expect(() =>
    verifyCatalogPointerData(data, { ...pointer, sha256: "a".repeat(64) }),
  ).toThrow();
});
