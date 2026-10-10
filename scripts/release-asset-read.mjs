import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { createReadStream } from "node:fs";
import { open, rm, stat } from "node:fs/promises";

export async function releaseFileDigest(file) {
  const { size } = await stat(file);
  if (!Number.isSafeInteger(size) || size <= 0 || size > 1024 ** 3)
    throw new Error("Invalid release file size");
  const hash = createHash("sha256");
  let count = 0;
  for await (const chunk of createReadStream(file)) {
    count += chunk.length;
    if (count > size) throw new Error("Release file size changed");
    hash.update(chunk);
  }
  if (count !== size) throw new Error("Release file size changed");
  return { size, sha256: hash.digest("hex") };
}

export async function downloadReleaseAsset({
  repository,
  asset,
  expectedBytes = asset.size,
  expectedSHA256,
  destination,
  collect = !destination,
  maximumBytes = collect ? 1024 ** 2 : 1024 ** 3,
  timeoutMs = 60_000,
  spawnProcess = spawn,
}) {
  if (
    !/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(repository) ||
    !Number.isSafeInteger(asset.id) ||
    asset.id <= 0 ||
    !Number.isSafeInteger(expectedBytes) ||
    expectedBytes <= 0 ||
    expectedBytes > maximumBytes ||
    expectedBytes > (collect ? 1024 ** 2 : 1024 ** 3) ||
    asset.size !== expectedBytes ||
    !Number.isSafeInteger(timeoutMs) ||
    timeoutMs <= 0 ||
    timeoutMs > 60_000 ||
    (expectedSHA256 !== undefined && !/^[a-f0-9]{64}$/.test(expectedSHA256))
  )
    throw new Error("Invalid release asset size or identity");
  const child = spawnProcess(
    "gh",
    [
      "api",
      "-H",
      "Accept: application/octet-stream",
      `repos/${repository}/releases/assets/${asset.id}`,
    ],
    { stdio: ["ignore", "pipe", "ignore"] },
  );
  const completed = new Promise((resolve) => {
    child.once("error", (error) => resolve({ error }));
    child.once("close", (code) => resolve({ code }));
  });
  let timedOut = false;
  const timer = setTimeout(() => {
    timedOut = true;
    child.kill("SIGKILL");
  }, timeoutMs);
  let file;
  let success = false;
  try {
    if (destination) file = await open(destination, "wx", 0o600);
    const hash = createHash("sha256");
    const chunks = [];
    let size = 0;
    for await (const chunk of child.stdout) {
      size += chunk.length;
      if (size > expectedBytes)
        throw new Error("Release asset exceeds its expected size");
      hash.update(chunk);
      if (file) await file.writeFile(chunk);
      else if (collect) chunks.push(chunk);
    }
    const result = await completed;
    if (timedOut) throw new Error("Release asset download timed out");
    if (result.error || result.code !== 0)
      throw new Error("Release asset download failed");
    if (size !== expectedBytes)
      throw new Error("Release asset has an unexpected size");
    const sha256 = hash.digest("hex");
    if (expectedSHA256 !== undefined && sha256 !== expectedSHA256)
      throw new Error("Release asset checksum mismatch");
    success = true;
    return {
      size,
      sha256,
      data: collect && !file ? Buffer.concat(chunks, size) : undefined,
    };
  } finally {
    clearTimeout(timer);
    child.kill("SIGKILL");
    await completed;
    await file?.close();
    if (!success && file) await rm(destination, { force: true });
  }
}

export async function releaseAssetMatchesFile({
  repository,
  asset,
  file,
  downloadAsset = downloadReleaseAsset,
}) {
  const expected = await releaseFileDigest(file);
  if (asset.size !== expected.size) return false;
  const downloaded = await downloadAsset({
    repository,
    asset,
    expectedBytes: expected.size,
    collect: false,
  });
  return downloaded.sha256 === expected.sha256;
}
