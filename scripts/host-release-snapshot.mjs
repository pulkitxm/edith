import { createHash } from "node:crypto";
import {
  chmodSync,
  closeSync,
  constants,
  fchmodSync,
  fstatSync,
  lstatSync,
  mkdtempSync,
  openSync,
  readSync,
  rmSync,
  writeSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

export const hostAssets = [
  "Edith.dmg",
  "appcast.xml",
  "host-release-proof.json",
  "build-metadata.json",
  "toolchain-provenance.json",
];

function identity(status) {
  return [
    status.dev,
    status.ino,
    status.mode,
    status.uid,
    status.nlink,
    status.size,
    status.mtimeNs,
    status.ctimeNs,
  ]
    .map(String)
    .join(":");
}

function readAsset(file, maximum, destination) {
  const before = lstatSync(file, { bigint: true });
  if (
    !before.isFile() ||
    before.nlink !== 1n ||
    before.size < 1n ||
    before.size > BigInt(maximum) ||
    (before.mode & 0o7022n) !== 0n
  )
    throw new Error("Invalid bounded release asset");
  const descriptor = openSync(
    file,
    constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK,
  );
  let output;
  try {
    if (identity(fstatSync(descriptor, { bigint: true })) !== identity(before))
      throw new Error("Host release assets changed after preflight");
    if (destination) {
      output = openSync(destination, "wx", 0o600);
      fchmodSync(output, 0o600);
    }
    const hash = createHash("sha256");
    const buffer = Buffer.alloc(1024 ** 2);
    let size = 0;
    for (;;) {
      const count = readSync(descriptor, buffer, 0, buffer.length, null);
      if (count === 0) break;
      size += count;
      if (size > Number(before.size))
        throw new Error("Host release assets changed after preflight");
      hash.update(buffer.subarray(0, count));
      if (output !== undefined) {
        let written = 0;
        while (written < count)
          written += writeSync(output, buffer, written, count - written);
      }
    }
    if (
      size !== Number(before.size) ||
      identity(fstatSync(descriptor, { bigint: true })) !== identity(before) ||
      identity(lstatSync(file, { bigint: true })) !== identity(before)
    )
      throw new Error("Host release assets changed after preflight");
    return { size, sha256: hash.digest("hex"), identity: identity(before) };
  } finally {
    if (output !== undefined) closeSync(output);
    closeSync(descriptor);
  }
}

export function assetSnapshot(directory, destination) {
  return hostAssets.map((name) => ({
    name,
    ...readAsset(
      resolve(directory, name),
      name === "Edith.dmg" ? 1024 ** 3 : 1024 ** 2,
      destination && join(destination, name),
    ),
  }));
}

export function requireAssetSnapshot(directory, snapshot) {
  if (JSON.stringify(assetSnapshot(directory)) !== JSON.stringify(snapshot))
    throw new Error("Host release assets changed after preflight");
}

export function privateHostAssets(directory) {
  const temporary = mkdtempSync(join(tmpdir(), "edith-host-release-"));
  const cleanup = () => rmSync(temporary, { recursive: true, force: true });
  try {
    chmodSync(temporary, 0o700);
    const original = assetSnapshot(directory, temporary);
    const snapshot = assetSnapshot(temporary);
    if (
      original.some(
        (asset, index) =>
          asset.size !== snapshot[index].size ||
          asset.sha256 !== snapshot[index].sha256,
      )
    )
      throw new Error("Host release snapshot differs from its input");
    requireAssetSnapshot(directory, original);
    return { directory: temporary, original, snapshot, cleanup };
  } catch (error) {
    cleanup();
    throw error;
  }
}
