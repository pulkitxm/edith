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

test("loopback downloads preserve slow progress beyond inactivity but bound stalled and trickling transfers", async () => {
  const { createServer } = await import("node:http");
  const connections = new Set();
  const server = createServer((request, response) => {
    response.writeHead(200);
    let sent = 0;
    const timer = setInterval(
      () => {
        if (request.url === "/stalled") return;
        response.write(Buffer.alloc(1, 42));
        if (++sent === 12 && request.url === "/progress") {
          clearInterval(timer);
          response.end();
        }
      },
      request.url === "/trickle" ? 250 : 100,
    );
    response.on("close", () => clearInterval(timer));
  });
  server.on("connection", (socket) => {
    connections.add(socket);
    socket.on("close", () => connections.delete(socket));
  });
  await new Promise((done) => server.listen(0, "127.0.0.1", done));
  try {
    for (const route of ["progress", "stalled", "trickle"]) {
      const value = fixture();
      const url = `http://127.0.0.1:${server.address().port}/${route}`;
      let child;
      const options = {
        ...value.options,
        asset: { id: 1, size: 12 },
        expectedBytes: 12,
        expectedSHA256: createHash("sha256")
          .update(Buffer.alloc(12, 42))
          .digest("hex"),
        timeoutMs: 1000,
        totalTimeoutMs: route === "trickle" ? 1500 : 5000,
        spawnProcess: (_command, _args, processOptions) => {
          child = spawn(
            "node",
            [
              "-e",
              `require("node:http").get(${JSON.stringify(url)}, response => response.pipe(process.stdout)).on("error", () => process.exit(1));`,
            ],
            processOptions,
          );
          return child;
        },
      };
      try {
        if (route === "progress") {
          const result = await downloadReleaseAsset(options);
          expect(result.size).toBe(12);
          expect(readFileSync(options.destination)).toEqual(
            Buffer.alloc(12, 42),
          );
        } else {
          await expect(downloadReleaseAsset(options)).rejects.toThrow(
            route === "stalled" ? "inactivity" : "total deadline",
          );
          expect(existsSync(options.destination)).toBe(false);
        }
        expect(child.exitCode !== null || child.signalCode !== null).toBe(true);
      } finally {
        value.clean();
      }
    }
  } finally {
    for (const socket of connections) socket.destroy();
    await new Promise((done) => server.close(done));
  }
}, 10000);

test("invalid transfer deadlines fail before process creation", async () => {
  for (const change of [
    { timeoutMs: 0 },
    { timeoutMs: 60_001 },
    { totalTimeoutMs: 30 * 60_000 + 1 },
    { totalTimeoutMs: 59_999 },
    { totalTimeoutMs: NaN },
  ])
    await expect(
      downloadReleaseAsset({
        repository: "synthetic/fixture",
        asset: { id: 1, size: 1 },
        ...change,
        spawnProcess: () => {
          throw new Error("Must not start");
        },
      }),
    ).rejects.toThrow("identity");
});
