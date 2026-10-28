import { expect, test } from "bun:test";
import { execFileSync, spawn } from "node:child_process";
import { createHash, generateKeyPairSync, sign } from "node:crypto";
import {
  cpSync,
  linkSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  statSync,
  unlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import {
  extensionChecksum,
  mergeExtensionCatalog,
  preflightExtensionBuilds,
  publishExtensionAssets,
  publishStableCatalog,
  restorePublishedExtension,
  runBounded,
  validateExtensionChecksum,
} from "./extension-publish.mjs";
import { extensionReleaseTag } from "./extension-release-plan.mjs";
import {
  snapshotReleaseFile,
  verifyImmutableReleaseAssets,
} from "./immutable-release-assets.mjs";
import { downloadReleaseAsset } from "./release-asset-read.mjs";
import { verifiedCatalogPayload } from "./verify-extension-catalog.mjs";

const packageRecord = {
  id: "calendar",
  version: "1.0.0",
  hostABI: "runtime-1",
  architecture: "arm64",
  sha256: "a".repeat(64),
  sourceFingerprint: "b".repeat(64),
  minimumSystemVersion: "14.0.0",
  downloadBytes: 1,
  installedBytes: 1,
  dependencies: [],
  downloadURL:
    "https://github.com/pulkitxm/edith/releases/download/synthetic/calendar.zip",
};
const previous = { schemaVersion: 1, revision: 1, packages: [packageRecord] };

test("portable catalog planning imports without installed release dependencies", () => {
  const directory = mkdtempSync(join(tmpdir(), "extension-planning-import-"));
  try {
    cpSync("scripts", join(directory, "scripts"), {
      recursive: true,
      filter: (path) => statSync(path).isDirectory() || path.endsWith(".mjs"),
    });
    const module = pathToFileURL(
      join(directory, "scripts/extension-publish.mjs"),
    ).href;
    expect(
      execFileSync(
        "node",
        [
          "--input-type=module",
          "-e",
          `await import(${JSON.stringify(module)});process.stdout.write("loaded");`,
        ],
        { encoding: "utf8", timeout: 15000 },
      ),
    ).toBe("loaded");
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});

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

test("published version metadata is immutable even when the archive digest matches", () => {
  for (const change of [
    { sourceFingerprint: "c".repeat(64) },
    { minimumSystemVersion: "15.0.0" },
    { installedBytes: 2 },
  ])
    expect(() =>
      mergeExtensionCatalog(previous, [{ ...packageRecord, ...change }], 2),
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
    const entry = {
      id: published.id,
      version: published.version,
      fingerprint: published.sourceFingerprint,
    };
    entry.tag = extensionReleaseTag(entry);
    published.downloadURL = `https://github.com/synthetic/fixture/releases/download/${encodeURIComponent(entry.tag)}/calendar.zip`;
    const recordPath = join(directory, "calendar.json");
    const zip = join(directory, "calendar.zip");
    const metadata = join(directory, "published.json");
    const publishedZip = join(directory, "published.zip");
    const checksumPath = join(directory, "calendar.zip.sha256");
    const publishedSHA = join(directory, "published.sha256");
    writeFileSync(publishedSHA, extensionChecksum(published));
    writeFileSync(metadata, JSON.stringify(published));
    writeFileSync(publishedZip, archive);
    writeFileSync(zip, "different local archive");
    writeFileSync(recordPath, "local metadata");
    const options = {
      repository: "synthetic/fixture",
      record: published,
      entry,
      publishedRecord: { id: 1, size: readFileSync(metadata).length },
      publishedArchive: { id: 2, size: archive.length },
      publishedChecksum: { id: 3, size: readFileSync(publishedSHA).length },
      checksumPath,
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
                options.asset.id === 1
                  ? metadata
                  : options.asset.id === 2
                    ? publishedZip
                    : publishedSHA,
              ],
              spawnOptions,
            ),
        }),
    };
    expect(await restorePublishedExtension(options)).toEqual(published);
    expect(readFileSync(zip)).toEqual(archive);
    expect(readFileSync(checksumPath, "utf8")).toBe(
      extensionChecksum(published),
    );
    writeFileSync(
      publishedSHA,
      extensionChecksum({ ...published, sha256: "f".repeat(64) }),
    );
    await expect(restorePublishedExtension(options)).rejects.toThrow(
      "Published extension checksum",
    );
    writeFileSync(publishedSHA, extensionChecksum(published));
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
    writeFileSync(metadata, JSON.stringify({ ...published, id: "foreign" }));
    options.publishedRecord.size = readFileSync(metadata).length;
    await expect(restorePublishedExtension(options)).rejects.toThrow(
      "release identity",
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
  expect(definitions).toHaveLength(41);
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
    expect(catalog.packages).toHaveLength(generation === 0 ? 41 : 82);
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
          minimumSystemVersion: "26.0.0",
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
          .filter((record) => record.minimumSystemVersion === "14.0.0")
          .map(({ version }) => version),
      ).toEqual(["1.0.4", "1.0.3"]);
      expect(
        versions
          .filter((record) => record.minimumSystemVersion === "26.0.0")
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

test("extension publication verifies closed immutable assets before uploads and on exact retries", async () => {
  const directory = mkdtempSync(join(tmpdir(), "extension-immutable-assets-"));
  try {
    const files = ["calendar.zip", "calendar.json", "calendar.zip.sha256"].map(
      (name) => {
        const path = join(directory, name);
        writeFileSync(path, `synthetic ${name}`);
        return [path, name];
      },
    );
    const uploaded = [];
    const remote = new Map();
    const options = {
      repository: "synthetic/fixture",
      item: {
        id: 1,
        tag_name: "extension-calendar-v1.0.0",
        draft: true,
        assets: [],
      },
      entry: { tag: "extension-calendar-v1.0.0" },
      files,
      readRelease: () => options.item,
      uploadAsset: async (_, __, ___, file, name) => {
        uploaded.push(name);
        const bytes = readFileSync(file);
        remote.set(name, bytes);
        options.item.assets.push({
          name,
          id: options.item.assets.length + 1,
          size: bytes.length,
        });
      },
      downloadAsset: async ({ asset, expectedBytes, expectedSHA256 }) => {
        const bytes = remote.get(asset.name);
        if (
          bytes.length !== expectedBytes ||
          createHash("sha256").update(bytes).digest("hex") !== expectedSHA256
        )
          throw new Error("Immutable asset differs from build output");
        return { sha256: expectedSHA256 };
      },
    };
    await publishExtensionAssets(options);
    expect(uploaded).toEqual(files.map(([, name]) => name));
    uploaded.length = 0;
    options.item.draft = false;
    await publishExtensionAssets(options);
    expect(uploaded).toEqual([]);
    const checksum = remote.get("calendar.zip.sha256");
    remote.set("calendar.zip.sha256", Buffer.alloc(checksum.length, 42));
    await expect(publishExtensionAssets(options)).rejects.toThrow(
      "Immutable asset differs",
    );
    expect(uploaded).toEqual([]);
    remote.set("calendar.zip.sha256", checksum);
    const asset = options.item.assets.pop();
    await expect(publishExtensionAssets(options)).rejects.toThrow(
      "missing an immutable asset",
    );
    options.item.draft = true;
    await publishExtensionAssets(options);
    expect(uploaded).toEqual(["calendar.zip.sha256"]);
    options.item.assets.push(asset);
    await expect(publishExtensionAssets(options)).rejects.toThrow(
      "Duplicate immutable release asset",
    );
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});

test("immutable asset publication reads the release twice by ID for any number of files", async () => {
  const directory = mkdtempSync(join(tmpdir(), "extension-asset-batch-"));
  try {
    const files = Array.from({ length: 43 }, (_, index) => {
      const path = join(directory, `evidence-${index}.json`);
      writeFileSync(path, `synthetic evidence ${index}`);
      return [path, `evidence-${index}.json`];
    });
    const item = { id: 9, tag_name: "fixture", draft: true, assets: [] };
    const reads = [];
    const remote = new Map();
    const receipt = await publishExtensionAssets({
      repository: "synthetic/fixture",
      item,
      entry: { tag: "fixture" },
      files,
      readRelease: (request) => {
        reads.push(request);
        return { ...item, assets: [...item.assets] };
      },
      uploadAsset: async (_, releaseID, __, file, name) => {
        expect(releaseID).toBe(9);
        const bytes = readFileSync(file);
        remote.set(name, bytes);
        item.assets.push({
          id: item.assets.length + 1,
          name,
          size: bytes.length,
        });
      },
      downloadAsset: async ({ asset }) => ({
        sha256: createHash("sha256")
          .update(remote.get(asset.name))
          .digest("hex"),
      }),
    });
    expect(receipt.assets).toHaveLength(43);
    expect(item.assets).toHaveLength(43);
    expect(reads).toEqual([
      { repository: "synthetic/fixture", tag: "fixture", releaseID: 9 },
      { repository: "synthetic/fixture", tag: "fixture", releaseID: 9 },
    ]);
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});

test("local checksum contents bind the actual archive hash and exact filename", async () => {
  const directory = mkdtempSync(join(tmpdir(), "extension-checksum-"));
  try {
    const file = join(directory, "calendar.zip.sha256");
    writeFileSync(file, extensionChecksum(packageRecord));
    await validateExtensionChecksum(file, packageRecord);
    for (const text of [
      extensionChecksum({ ...packageRecord, sha256: "f".repeat(64) }),
      `${packageRecord.sha256}  foreign.zip\n`,
      `${extensionChecksum(packageRecord)}extra`,
      `${packageRecord.sha256}  calendar.zip`,
    ]) {
      writeFileSync(file, text);
      await expect(
        validateExtensionChecksum(file, packageRecord),
      ).rejects.toThrow("checksum");
    }
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});

test("all local package identities are checked before any release client request", async () => {
  const directory = mkdtempSync(join(tmpdir(), "extension-identity-"));
  try {
    const archive = Buffer.from("owned synthetic archive");
    const entry = {
      id: "calendar",
      version: "1.0.0",
      fingerprint: packageRecord.sourceFingerprint,
    };
    entry.tag = extensionReleaseTag(entry);
    const record = {
      ...packageRecord,
      downloadBytes: archive.length,
      sha256: createHash("sha256").update(archive).digest("hex"),
      downloadURL: `https://github.com/synthetic/fixture/releases/download/${encodeURIComponent(entry.tag)}/calendar.zip`,
    };
    writeFileSync(join(directory, "calendar.zip"), archive);
    writeFileSync(join(directory, "calendar.json"), JSON.stringify(record));
    writeFileSync(
      join(directory, "calendar.zip.sha256"),
      extensionChecksum(record),
    );
    const calls = [];
    const options = {
      repository: "synthetic/fixture",
      directory,
      include: [entry],
      previous: { schemaVersion: 1, revision: 0, packages: [] },
      preflightAsset: ({ file }) => calls.push(file),
    };
    await preflightExtensionBuilds(options);
    expect(calls).toHaveLength(3);
    for (const wrong of [
      { ...record, id: "foreign" },
      {
        ...record,
        downloadURL: record.downloadURL.replace(
          "synthetic/fixture",
          "foreign/project",
        ),
      },
      {
        ...record,
        downloadURL: record.downloadURL.replace(
          encodeURIComponent(entry.tag),
          "foreign-tag",
        ),
      },
    ]) {
      calls.length = 0;
      writeFileSync(join(directory, "calendar.json"), JSON.stringify(wrong));
      writeFileSync(
        join(directory, "calendar.zip.sha256"),
        extensionChecksum(wrong),
      );
      await expect(preflightExtensionBuilds(options)).rejects.toThrow(
        "release identity",
      );
      expect(calls).toEqual([]);
    }
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});

test("private immutable snapshots reject FIFOs, hardlinks and same-size restored-mtime source mutation", async () => {
  const directory = mkdtempSync(join(tmpdir(), "extension-snapshot-"));
  try {
    const source = join(directory, "source");
    const output = join(directory, "snapshot");
    execFileSync("mkfifo", [source]);
    await expect(snapshotReleaseFile(source, output)).rejects.toThrow();
    unlinkSync(source);
    writeFileSync(source, "original bytes");
    linkSync(source, join(directory, "hardlink"));
    await expect(snapshotReleaseFile(source, output)).rejects.toThrow();
    unlinkSync(join(directory, "hardlink"));
    const before = statSync(source, { bigint: true });
    let changed = false;
    await expect(
      snapshotReleaseFile(source, output, {
        readChunk: async (input, buffer) => {
          const result = await input.read(buffer, 0, buffer.length, null);
          if (!changed && result.bytesRead) {
            changed = true;
            writeFileSync(source, "different data");
            execFileSync("python3", [
              "-c",
              "import os,sys;os.utime(sys.argv[1],ns=(int(sys.argv[2]),int(sys.argv[3])))",
              source,
              String(before.atimeNs),
              String(before.mtimeNs),
            ]);
            const after = statSync(source, { bigint: true });
            expect(after.size).toBe(before.size);
            expect(after.mtimeNs).toBe(before.mtimeNs);
            expect(after.ctimeNs).not.toBe(before.ctimeNs);
          }
          return result;
        },
      }),
    ).rejects.toThrow();
    expect(changed).toBe(true);
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});

test("uploads use fixed private bytes and reject remote substitution before and after promotion", async () => {
  const directory = mkdtempSync(join(tmpdir(), "extension-remote-proof-"));
  try {
    const file = join(directory, "package.zip");
    const original = Buffer.from("original synthetic archive");
    const changed = Buffer.from("modified synthetic archive");
    writeFileSync(file, original);
    const item = { id: 1, tag_name: "fixture", draft: true, assets: [] };
    let remote;
    let substitute = false;
    const downloadAsset = async ({ expectedBytes, expectedSHA256 }) => {
      const sha256 = createHash("sha256").update(remote).digest("hex");
      if (remote.length !== expectedBytes || sha256 !== expectedSHA256)
        throw new Error("Remote immutable bytes differ");
      return { sha256 };
    };
    const options = {
      repository: "synthetic/fixture",
      item,
      entry: { tag: "fixture" },
      files: [[file, "calendar.zip"]],
      readRelease: () => item,
      downloadAsset,
      uploadAsset: async (_, __, ___, snapshot, name) => {
        expect(snapshot).not.toBe(file);
        writeFileSync(file, changed);
        remote = substitute ? changed : readFileSync(snapshot);
        writeFileSync(file, original);
        item.assets.push({ id: 2, name, size: remote.length });
      },
    };
    const receipt = await publishExtensionAssets(options);
    expect(remote).toEqual(original);
    item.draft = false;
    await verifyImmutableReleaseAssets({
      repository: options.repository,
      receipt,
      readRelease: options.readRelease,
      downloadAsset,
    });
    remote = changed;
    await expect(
      verifyImmutableReleaseAssets({
        repository: options.repository,
        receipt,
        readRelease: options.readRelease,
        downloadAsset,
      }),
    ).rejects.toThrow();
    item.draft = true;
    item.assets = [];
    substitute = true;
    await expect(publishExtensionAssets(options)).rejects.toThrow();
    expect(item.draft).toBe(true);
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});

test("extension publication runs a bounded pool and stops scheduling after a failure", async () => {
  let running = 0;
  let peak = 0;
  const started = [];
  await runBounded([1, 2, 3, 4, 5, 6, 7], 3, async (item) => {
    started.push(item);
    peak = Math.max(peak, ++running);
    await new Promise((done) => setTimeout(done, 5));
    running--;
  });
  expect(peak).toBe(3);
  expect(started.sort()).toEqual([1, 2, 3, 4, 5, 6, 7]);
  const attempted = [];
  await expect(
    runBounded([1, 2, 3, 4, 5], 2, async (item) => {
      attempted.push(item);
      await new Promise((done) => setTimeout(done, 5));
      if (item === 1) throw new Error("synthetic failure");
    }),
  ).rejects.toThrow("synthetic failure");
  expect(attempted).toEqual([1, 2]);
});

test("the catalog is also published under the stable unauthenticated asset name", async () => {
  const directory = mkdtempSync(join(tmpdir(), "extension-stable-catalog-"));
  try {
    const file = join(directory, "catalog.json");
    writeFileSync(file, "synthetic catalog");
    const assets = [
      { id: 1, name: "catalog-1.json", size: 3 },
      { id: 2, name: "catalog.json", size: 99 },
    ];
    const removed = [];
    const uploaded = [];
    await publishStableCatalog({
      repository: "synthetic/fixture",
      tag: "catalog-fixture",
      file,
      readRelease: () => ({ id: 7, assets: [...assets] }),
      removeAsset: (id) => {
        removed.push(id);
        assets.splice(
          assets.findIndex((asset) => asset.id === id),
          1,
        );
      },
      uploadAsset: async (repository, releaseID, tag, _path, name) => {
        uploaded.push([repository, releaseID, tag, name]);
        assets.push({ id: 3, name, size: 17 });
      },
    });
    expect(removed).toEqual([2]);
    expect(uploaded).toEqual([
      ["synthetic/fixture", 7, "catalog-fixture", "catalog.json"],
    ]);
    await expect(
      publishStableCatalog({
        repository: "synthetic/fixture",
        tag: "catalog-fixture",
        file,
        readRelease: () => ({ id: 7, assets: [] }),
        removeAsset: () => {},
        uploadAsset: async () => {},
      }),
    ).rejects.toThrow("Stable catalog upload did not finish");
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});
