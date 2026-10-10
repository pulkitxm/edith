import { expect, test } from "bun:test";
import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  mergeExtensionCatalog,
  restorePublishedExtension,
} from "./extension-publish.mjs";
import { downloadReleaseAsset } from "./release-asset-read.mjs";

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
