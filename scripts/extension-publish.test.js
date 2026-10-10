import { expect, test } from "bun:test";
import { spawn } from "node:child_process";
import { createHash, generateKeyPairSync, sign } from "node:crypto";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  mergeExtensionCatalog,
  restorePublishedExtension,
} from "./extension-publish.mjs";
import { downloadReleaseAsset } from "./release-asset-read.mjs";
import { verifiedCatalogPayload } from "./verify-extension-catalog.mjs";

const packageRecord = {
  id: "calendar",
  version: "1.0.0",
  hostABI: "runtime-1",
  architecture: "arm64",
  sha256: "a".repeat(64),
  sourceFingerprint: "b".repeat(64),
  minimumSystemVersion: 14,
  downloadBytes: 1,
  installedBytes: 1,
  dependencies: [],
  downloadURL:
    "https://github.com/pulkitxm/edith/releases/download/synthetic/calendar.zip",
};
const previous = { schemaVersion: 1, revision: 1, packages: [packageRecord] };

test("app upgrades retain packages for previous host contracts", () => {
  const upgraded = {
    ...packageRecord,
    hostABI: "runtime-2",
    sha256: "c".repeat(64),
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

test("an immutable published archive larger than 1 MiB resumes through a verified stream", async () => {
  const directory = mkdtempSync(join(tmpdir(), "extension-published-resume-"));
  try {
    const archive = Buffer.alloc(2 * 1024 ** 2 + 19, 42);
    const published = {
      ...packageRecord,
      sourceFingerprint: "a".repeat(64),
      downloadBytes: archive.length,
      sha256: createHash("sha256").update(archive).digest("hex"),
    };
    const recordPath = join(directory, "calendar.json");
    const zip = join(directory, "calendar.zip");
    const metadata = join(directory, "published.json");
    const publishedZip = join(directory, "published.zip");
    writeFileSync(metadata, JSON.stringify(published));
    writeFileSync(publishedZip, archive);
    writeFileSync(zip, "different local archive");
    writeFileSync(recordPath, "local metadata");
    const options = {
      repository: "synthetic/fixture",
      record: published,
      entry: {
        version: published.version,
        fingerprint: published.sourceFingerprint,
      },
      publishedRecord: { id: 1, size: readFileSync(metadata).length },
      publishedArchive: { id: 2, size: archive.length },
      recordPath,
      zip,
      downloadAsset: (options) =>
        downloadReleaseAsset({
          ...options,
          spawnProcess: (_command, _args, spawnOptions) =>
            spawn(
              "node",
              [
                "-e",
                'require("node:fs").createReadStream(process.argv[1]).pipe(process.stdout)',
                options.asset.id === 1 ? metadata : publishedZip,
              ],
              spawnOptions,
            ),
        }),
    };
    expect(await restorePublishedExtension(options)).toEqual(published);
    expect(readFileSync(zip)).toEqual(archive);
    expect(JSON.parse(readFileSync(recordPath, "utf8"))).toEqual(published);
    writeFileSync(zip, "untouched local archive");
    writeFileSync(
      metadata,
      JSON.stringify({ ...published, sha256: "b".repeat(64) }),
    );
    await expect(restorePublishedExtension(options)).rejects.toThrow(
      "checksum",
    );
    expect(readFileSync(zip, "utf8")).toBe("untouched local archive");
    writeFileSync(
      metadata,
      JSON.stringify({ ...published, architecture: "x86_64" }),
    );
    options.publishedRecord.size = readFileSync(metadata).length;
    await expect(restorePublishedExtension(options)).rejects.toThrow(
      "source plan",
    );
    expect(readFileSync(zip, "utf8")).toBe("untouched local archive");
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});

test("all39 independent releases retain bounded compatible rollback records beyond26 updates", () => {
  const definitions = JSON.parse(
    readFileSync("Extensions/manifest.json", "utf8"),
  );
  expect(definitions).toHaveLength(39);
  let catalog = { schemaVersion: 1, revision: 0, packages: [] };
  for (let generation = 0; generation < 32; generation++) {
    const records = definitions.map(({ id, dependencies }) => ({
      ...packageRecord,
      id,
      dependencies,
      hostABI: "edith-host-2",
      version: `1.0.${generation}`,
      sourceFingerprint: createHash("sha256")
        .update(`${id}-${generation}`)
        .digest("hex"),
      downloadURL: `https://github.com/pulkitxm/edith/releases/download/synthetic/${id}.zip`,
    }));
    catalog = mergeExtensionCatalog(catalog, records, generation + 1);
    expect(catalog.packages).toHaveLength(generation === 0 ? 39 : 78);
  }
  for (const { id } of definitions) {
    expect(
      catalog.packages
        .filter((record) => record.id === id)
        .map(({ version }) => version),
    ).toEqual(["1.0.31", "1.0.30"]);
  }
  const { privateKey, publicKey } = generateKeyPairSync("ed25519");
  const payload = Buffer.from(JSON.stringify(catalog));
  const envelope = Buffer.from(
    JSON.stringify({
      payload: payload.toString("base64"),
      signature: sign(null, payload, privateKey).toString("base64"),
    }),
  );
  const rawKey = Buffer.from(
    publicKey.export({ format: "jwk" }).x,
    "base64url",
  ).toString("base64");
  expect(JSON.parse(verifiedCatalogPayload(envelope, rawKey))).toEqual(catalog);
  const tampered = JSON.parse(envelope);
  tampered.payload = Buffer.from(
    JSON.stringify({ ...catalog, revision: 999 }),
  ).toString("base64");
  expect(() =>
    verifiedCatalogPayload(Buffer.from(JSON.stringify(tampered)), rawKey),
  ).toThrow("signature");
});

test("retention preserves older OS contracts, architectures and explicit rollback packages", () => {
  const records = [];
  for (const hostABI of ["runtime-1", "runtime-2"]) {
    for (const architecture of ["arm64", "x86_64"]) {
      for (let generation = 0; generation < 5; generation++) {
        records.push({
          ...packageRecord,
          hostABI,
          architecture,
          version: `1.0.${generation}`,
        });
      }
      for (let generation = 5; generation < 9; generation++) {
        records.push({
          ...packageRecord,
          hostABI,
          architecture,
          minimumSystemVersion: 26,
          version: `1.0.${generation}`,
        });
      }
    }
  }
  const catalog = mergeExtensionCatalog(
    { schemaVersion: 1, revision: 0, packages: [] },
    records,
    1,
  );
  expect(catalog.packages).toHaveLength(16);
  for (const hostABI of ["runtime-1", "runtime-2"]) {
    for (const architecture of ["arm64", "x86_64"]) {
      const versions = catalog.packages.filter(
        (record) =>
          record.hostABI === hostABI && record.architecture === architecture,
      );
      expect(
        versions
          .filter((record) => record.minimumSystemVersion === 14)
          .map(({ version }) => version),
      ).toEqual(["1.0.4", "1.0.3"]);
      expect(
        versions
          .filter((record) => record.minimumSystemVersion === 26)
          .map(({ version }) => version),
      ).toEqual(["1.0.8", "1.0.7"]);
    }
  }
});

test("catalog limits fail closed instead of losing required compatibility or accepting malformed metadata", () => {
  const records = Array.from({ length: 1001 }, (_, index) => ({
    ...packageRecord,
    id: `extension${index}`,
    downloadURL: `https://github.com/pulkitxm/edith/releases/download/synthetic/extension${index}.zip`,
  }));
  const previous = { schemaVersion: 1, revision: 0, packages: [] };
  expect(
    mergeExtensionCatalog(previous, records.slice(0, 1000), 1).packages,
  ).toHaveLength(1000);
  expect(() => mergeExtensionCatalog(previous, records, 1)).toThrow(
    "package limit",
  );
  expect(() =>
    mergeExtensionCatalog(
      previous,
      [{ ...packageRecord, downloadURL: "https://example.com/calendar.zip" }],
      1,
    ),
  ).toThrow("download URL");
  expect(() =>
    mergeExtensionCatalog(
      previous,
      [{ ...packageRecord, dependencies: ["missing"] }],
      1,
    ),
  ).toThrow("dependency");
});
