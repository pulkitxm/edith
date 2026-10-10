import { expect, test } from "bun:test";
import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import {
  existsSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  downloadReleaseAsset,
  releaseAssetMatchesFile,
} from "./release-asset-read.mjs";

const size = 2 * 1024 ** 2 + 17;
const bytes = Buffer.alloc(size, 42);
const checksum = createHash("sha256").update(bytes).digest("hex");

function processSource(script) {
  return (_command, _args, options) => spawn("node", ["-e", script], options);
}

function streamingSource(count, exitCode = 0) {
  return processSource(`
    async function run() {
      let remaining = ${count};
      while (remaining > 0) {
        const count = Math.min(remaining, 65536);
        if (!process.stdout.write(Buffer.alloc(count, 42)))
          await new Promise(resolve => process.stdout.once("drain", resolve));
        remaining -= count;
      }
      process.exitCode = ${exitCode};
    }
    run();
  `);
}

function fixture() {
  const directory = mkdtempSync(join(tmpdir(), "release-asset-stream-"));
  return {
    directory,
    options: {
      repository: "synthetic/fixture",
      asset: { id: 1, size },
      expectedBytes: size,
      expectedSHA256: checksum,
      destination: join(directory, "archive.zip"),
      spawnProcess: streamingSource(size),
    },
    clean() {
      rmSync(directory, { recursive: true, force: true });
    },
  };
}

test("streams a real asset larger than 1 MiB to disk with exact size and checksum", async () => {
  const value = fixture();
  try {
    const result = await downloadReleaseAsset(value.options);
    expect(result).toEqual({ size, sha256: checksum, data: undefined });
    expect(readFileSync(value.options.destination)).toEqual(bytes);
    const local = join(value.directory, "local.zip");
    writeFileSync(local, bytes);
    expect(
      await releaseAssetMatchesFile({
        repository: value.options.repository,
        asset: value.options.asset,
        file: local,
        downloadAsset: (options) =>
          downloadReleaseAsset({
            ...options,
            spawnProcess: streamingSource(size),
          }),
      }),
    ).toBe(true);
  } finally {
    value.clean();
  }
});

test("rejects incorrect declared sizes before starting a process", async () => {
  let starts = 0;
  for (const declared of [0, -1, NaN, size - 1, 1024 ** 3 + 1]) {
    await expect(
      downloadReleaseAsset({
        repository: "synthetic/fixture",
        asset: { id: 1, size: declared },
        expectedBytes: size,
        collect: false,
        spawnProcess: () => {
          starts += 1;
          throw new Error("Must not start");
        },
      }),
    ).rejects.toThrow("size");
  }
  expect(starts).toBe(0);
});

test("truncated oversized failed and corrupt streams leave no accepted archive", async () => {
  for (const overrides of [
    { spawnProcess: streamingSource(size - 1) },
    { spawnProcess: streamingSource(size + 1) },
    { spawnProcess: streamingSource(size, 3) },
    { expectedSHA256: "a".repeat(64) },
    {
      spawnProcess: processSource("setInterval(() => {}, 1000)"),
      timeoutMs: 50,
    },
  ]) {
    const value = fixture();
    try {
      await expect(
        downloadReleaseAsset({ ...value.options, ...overrides }),
      ).rejects.toThrow();
      expect(existsSync(value.options.destination)).toBe(false);
    } finally {
      value.clean();
    }
  }
});

test("metadata collection is bounded and small assets retain their exact bytes", async () => {
  await expect(
    downloadReleaseAsset({
      repository: "synthetic/fixture",
      asset: { id: 1, size },
      spawnProcess: () => {
        throw new Error("Must not start");
      },
    }),
  ).rejects.toThrow("size");
  const result = await downloadReleaseAsset({
    repository: "synthetic/fixture",
    asset: { id: 1, size: 17 },
    spawnProcess: streamingSource(17),
  });
  expect(result.data).toEqual(Buffer.alloc(17, 42));
});
