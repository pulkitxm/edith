import assert from "node:assert/strict";
import { constants } from "node:fs";
import { lstat, open, realpath, rename, unlink } from "node:fs/promises";
import { join } from "node:path";

export async function readSparkleFixedFile(
  directory,
  name,
  maximum,
  uid = process.getuid(),
) {
  assert(["active-catalog.json", "updated-catalog.json"].includes(name));
  assert(Number.isSafeInteger(maximum) && maximum > 0 && maximum <= 3145728);
  const root = await lstat(directory, { bigint: true });
  assert(
    root.isDirectory() &&
      root.uid === BigInt(uid) &&
      (root.mode & 0o777n) === 0o700n,
  );
  assert.equal(await realpath(directory), directory);
  const file = await open(
    join(directory, name),
    constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK,
  );
  try {
    const before = await file.stat({ bigint: true });
    assert(
      before.isFile() &&
        before.uid === root.uid &&
        before.nlink === 1n &&
        (before.mode & 0o7777n) === 0o600n &&
        before.size > 0n &&
        before.size <= BigInt(maximum),
    );
    const bytes = Buffer.alloc(Number(before.size) + 1);
    const { bytesRead } = await file.read(bytes, 0, bytes.length, 0);
    assert.equal(BigInt(bytesRead), before.size);
    const after = await file.stat({ bigint: true });
    const path = await lstat(join(directory, name), { bigint: true });
    for (const field of [
      "dev",
      "ino",
      "uid",
      "mode",
      "nlink",
      "size",
      "mtimeNs",
      "ctimeNs",
    ]) {
      assert.equal(before[field], after[field]);
      assert.equal(after[field], path[field]);
    }
    const finalRoot = await lstat(directory, { bigint: true });
    for (const field of ["dev", "ino", "uid", "mode"])
      assert.equal(root[field], finalRoot[field]);
    assert.equal(await realpath(directory), directory);
    return Buffer.from(bytes.subarray(0, bytesRead));
  } finally {
    await file.close();
  }
}

export async function createSparkleCatalogSwitch(directory) {
  const previous = await readSparkleFixedFile(
    directory,
    "active-catalog.json",
    3145728,
  );
  const updated = await readSparkleFixedFile(
    directory,
    "updated-catalog.json",
    3145728,
  );
  for (const bytes of [previous, updated]) {
    const value = JSON.parse(bytes);
    assert.deepEqual(Object.keys(value).sort(), ["payload", "signature"]);
    assert(
      typeof value.payload === "string" && typeof value.signature === "string",
    );
  }
  let completed = false;
  return async () => {
    assert(!completed);
    assert.deepEqual(
      await readSparkleFixedFile(directory, "active-catalog.json", 3145728),
      previous,
    );
    assert.deepEqual(
      await readSparkleFixedFile(directory, "updated-catalog.json", 3145728),
      updated,
    );
    const temporary = join(directory, "sparkle-catalog.tmp");
    const file = await open(temporary, "wx", 0o600);
    try {
      await file.writeFile(updated);
      await file.sync();
    } finally {
      await file.close();
    }
    try {
      assert.deepEqual(
        await readSparkleFixedFile(directory, "active-catalog.json", 3145728),
        previous,
      );
      await rename(temporary, join(directory, "active-catalog.json"));
    } catch (error) {
      await unlink(temporary);
      throw error;
    }
    completed = true;
    assert.deepEqual(
      await readSparkleFixedFile(directory, "active-catalog.json", 3145728),
      updated,
    );
  };
}
