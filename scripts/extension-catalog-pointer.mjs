import { createHash } from "node:crypto";
import { maximumEnvelopeBytes } from "./verify-extension-catalog.mjs";

export const catalogRepository = "pulkitxm/edith";
export const catalogTag = "extension-catalog-v1";
export const catalogReleaseURL = `https://api.github.com/repos/${catalogRepository}/releases/tags/${catalogTag}`;

export function validateCatalogPointer(pointer) {
  if (
    !pointer ||
    typeof pointer !== "object" ||
    Array.isArray(pointer) ||
    Object.keys(pointer).sort().join(",") !==
      "assetName,bytes,revision,schemaVersion,sha256" ||
    pointer.schemaVersion !== 1 ||
    !Number.isSafeInteger(pointer.revision) ||
    pointer.revision < 1 ||
    pointer.assetName !== `catalog-${pointer.revision}.json` ||
    !Number.isSafeInteger(pointer.bytes) ||
    pointer.bytes < 1 ||
    pointer.bytes > maximumEnvelopeBytes ||
    typeof pointer.sha256 !== "string" ||
    !/^[a-f0-9]{64}$/.test(pointer.sha256)
  )
    throw new Error("Invalid catalog pointer");
  return pointer;
}

export function parseCatalogPointer(body) {
  if (typeof body !== "string" || Buffer.byteLength(body) > 1024)
    throw new Error("Invalid catalog pointer");
  const keys = [
    ...body.matchAll(/"(assetName|bytes|revision|schemaVersion|sha256)"\s*:/g),
  ].map((match) => match[1]);
  if (keys.length !== 5 || new Set(keys).size !== 5)
    throw new Error("Invalid catalog pointer keys");
  return validateCatalogPointer(JSON.parse(body));
}

export function catalogPointer(data, revision) {
  return validateCatalogPointer({
    schemaVersion: 1,
    revision,
    assetName: `catalog-${revision}.json`,
    bytes: data.length,
    sha256: createHash("sha256").update(data).digest("hex"),
  });
}

export function verifyCatalogPointerData(data, pointer) {
  validateCatalogPointer(pointer);
  if (
    data.length !== pointer.bytes ||
    createHash("sha256").update(data).digest("hex") !== pointer.sha256
  )
    throw new Error("Catalog pointer asset mismatch");
  return data;
}

export function catalogAssetURL(pointer) {
  validateCatalogPointer(pointer);
  return `https://github.com/${catalogRepository}/releases/download/${catalogTag}/${pointer.assetName}`;
}
