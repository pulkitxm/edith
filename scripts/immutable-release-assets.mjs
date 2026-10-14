import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { constants } from "node:fs";
import { chmod, lstat, mkdtemp, open, realpath, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { basename, dirname, join, resolve } from "node:path";
import { downloadReleaseAsset } from "./release-asset-read.mjs";
import { uploadReleaseAsset } from "./release-asset-upload.mjs";
import { lookupRelease } from "./release-lookup.mjs";

const upload = (repository, releaseID, tag, file, name) =>
  uploadReleaseAsset({ repository, releaseID, tag, file, name });
const identity = (value) => [
  value.dev,
  value.ino,
  value.uid,
  value.mode,
  value.nlink,
  value.size,
  value.mtimeNs,
  value.ctimeNs,
];

export async function snapshotReleaseFile(
  file,
  destination,
  {
    readChunk = (input, buffer) => input.read(buffer, 0, buffer.length, null),
  } = {},
) {
  const path = join(await realpath(dirname(resolve(file))), basename(file));
  const input = await open(
    path,
    constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK,
  );
  let output;
  try {
    const before = await input.stat({ bigint: true });
    assert(
      before.isFile() &&
        before.nlink === 1n &&
        before.uid === BigInt(process.getuid()) &&
        (before.mode & 0o022n) === 0n,
    );
    assert(before.size > 0n && before.size <= 1024n ** 3n);
    assert.deepEqual(
      identity(await lstat(path, { bigint: true })),
      identity(before),
    );
    output = await open(destination, "wx", 0o600);
    const hash = createHash("sha256");
    const buffer = Buffer.alloc(1024 ** 2);
    let bytes = 0;
    while (true) {
      const { bytesRead } = await readChunk(input, buffer);
      if (!bytesRead) break;
      bytes += bytesRead;
      assert(BigInt(bytes) <= before.size);
      const chunk = buffer.subarray(0, bytesRead);
      hash.update(chunk);
      await output.writeFile(chunk);
    }
    assert.equal(BigInt(bytes), before.size);
    assert.deepEqual(
      identity(await input.stat({ bigint: true })),
      identity(before),
    );
    assert.deepEqual(
      identity(await lstat(path, { bigint: true })),
      identity(before),
    );
    await output.sync();
    return { file: destination, bytes, sha256: hash.digest("hex") };
  } finally {
    await output?.close();
    await input.close();
  }
}

export async function publishExtensionAssets({
  repository,
  item,
  entry,
  files,
  uploadAsset = upload,
  readRelease = lookupRelease,
  downloadAsset = downloadReleaseAsset,
}) {
  assert.equal(new Set(files.map(([, name]) => name)).size, files.length);
  const directory = await mkdtemp(
    join(await realpath(tmpdir()), "immutable-release-"),
  );
  await chmod(directory, 0o700);
  try {
    const snapshots = [];
    for (const [file, name] of files) {
      assert.match(name, /^[A-Za-z0-9_.-]+$/);
      snapshots.push({
        name,
        ...(await snapshotReleaseFile(file, join(directory, name))),
      });
    }
    const current = () => {
      const value = readRelease({
        repository,
        tag: entry.tag,
        releaseID: item.id,
      });
      assert(value && value.id === item.id && value.tag_name === entry.tag);
      const names = value.assets.map(({ name }) => name);
      if (new Set(names).size !== names.length)
        throw new Error("Duplicate immutable release asset");
      assert(
        names.every((name) => snapshots.some((row) => row.name === name)),
        "Unknown immutable release asset",
      );
      return value;
    };
    const verify = async (value, complete) => {
      for (const snapshot of snapshots) {
        const asset = value.assets.find(({ name }) => name === snapshot.name);
        if (!asset) {
          if (complete || !value.draft)
            throw new Error(
              "Published extension release is missing an immutable asset",
            );
          continue;
        }
        if (asset.size !== snapshot.bytes)
          throw new Error("Immutable asset differs from build output");
        const downloaded = await downloadAsset({
          repository,
          asset,
          expectedBytes: snapshot.bytes,
          expectedSHA256: snapshot.sha256,
          collect: false,
        });
        if (downloaded.sha256 !== snapshot.sha256)
          throw new Error("Immutable asset differs from build output");
      }
    };
    const before = current();
    await verify(before, false);
    for (const snapshot of snapshots) {
      if (before.assets.some(({ name }) => name === snapshot.name)) continue;
      if (!before.draft)
        throw new Error(
          "Published extension release is missing an immutable asset",
        );
      await uploadAsset(
        repository,
        before.id,
        entry.tag,
        snapshot.file,
        snapshot.name,
      );
    }
    const final = current();
    await verify(final, true);
    return {
      releaseID: final.id,
      tag: entry.tag,
      assets: snapshots.map(({ name, bytes, sha256 }) => ({
        name,
        bytes,
        sha256,
      })),
    };
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
}

export async function verifyImmutableReleaseAssets({
  repository,
  receipt,
  readRelease = lookupRelease,
  downloadAsset = downloadReleaseAsset,
}) {
  const item = readRelease({
    repository,
    tag: receipt.tag,
    releaseID: receipt.releaseID,
  });
  assert(item && item.id === receipt.releaseID && !item.draft);
  assert.deepEqual(
    item.assets.map(({ name }) => name).sort(),
    receipt.assets.map(({ name }) => name).sort(),
  );
  for (const row of receipt.assets) {
    const assets = item.assets.filter(({ name }) => name === row.name);
    assert.equal(assets.length, 1);
    const result = await downloadAsset({
      repository,
      asset: assets[0],
      expectedBytes: row.bytes,
      expectedSHA256: row.sha256,
      collect: false,
    });
    assert.equal(result.sha256, row.sha256);
  }
  return receipt;
}
