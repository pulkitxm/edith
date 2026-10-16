import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import {
  createHash,
  randomBytes,
  randomUUID,
  timingSafeEqual,
} from "node:crypto";
import { constants } from "node:fs";
import {
  cp,
  lstat,
  mkdir,
  open,
  readFile,
  realpath,
  rename,
  rm,
} from "node:fs/promises";
import { createServer } from "node:http";
import { join } from "node:path";
import { admitHostedJourney } from "./prepare-journey.mjs";

const digest = (bytes) => createHash("sha256").update(bytes).digest("hex");

export function validateReplacementRequest(request, fixture) {
  assert.deepEqual(
    Object.keys(request).sort(),
    [
      "hostIdentifier",
      "nextVersion",
      "operation",
      "previousVersion",
      "sourceCommit",
    ].sort(),
  );
  assert.equal(request.operation, "replaceApplication");
  assert.equal(request.hostIdentifier, fixture.identifier);
  assert.equal(request.sourceCommit, fixture.sourceCommit);
  assert.equal(request.previousVersion, "1.0.0");
  assert.equal(request.nextVersion, "2.0.0");
}

export function validateReplacementProcesses(processes) {
  assert(
    Array.isArray(processes) && processes.length > 0 && processes.length <= 64,
  );
  assert(processes.some(({ role }) => role === "host"));
  for (const role of ["engine", "managedUI"])
    assert(processes.some((item) => item.role === role));
  const identities = new Set();
  for (const item of processes) {
    assert(["host", "engine", "managedUI"].includes(item.role));
    assert(Number.isInteger(item.pid) && item.pid > 1);
    assert(/^\d+:\d+$/.test(item.generation));
    assert.equal(
      item.running,
      false,
      "Owned generation must exit before replacement",
    );
    assert.equal(item.residentBytes, null);
    const key = `${item.pid}:${item.generation}`;
    assert(!identities.has(key));
    identities.add(key);
  }
}

export async function createJourneyReplacement({
  directory,
  environment,
  accountHome,
  fixture,
  audit,
  registerApplication,
  verifyApplication = (path, version, identifier) => {
    const info = JSON.parse(
      execFileSync(
        "python3",
        [
          "-c",
          "import json,plistlib,sys; print(json.dumps(plistlib.load(open(sys.argv[1],'rb'))))",
          join(path, "Contents/Info.plist"),
        ],
        { encoding: "utf8", timeout: 5_000, maxBuffer: 16_384 },
      ),
    );
    assert.equal(info.CFBundleIdentifier, identifier);
    assert.equal(info.CFBundleExecutable, "Edith");
    assert.equal(info.CFBundlePackageType, "APPL");
    assert.equal(info.CFBundleShortVersionString, version);
    execFileSync("codesign", ["--verify", "--deep", "--strict", path], {
      stdio: "pipe",
      timeout: 10_000,
    });
  },
  copy = cp,
  uid = process.getuid(),
}) {
  admitHostedJourney(environment, directory, fixture.identifier, accountHome);
  assert.equal(typeof registerApplication, "function");
  assert.equal(fixture.directory, directory);
  assert.match(fixture.sourceCommit, /^[a-f0-9]{40}$/);
  assert.deepEqual(fixture.appVersions, ["1.0.0", "2.0.0"]);
  assert.deepEqual(
    Object.keys(fixture.executableSHA256).sort(),
    fixture.appVersions,
  );
  for (const value of Object.values(fixture.executableSHA256))
    assert.match(value, /^[a-f0-9]{64}$/);
  const owned = async (path, isDirectory) => {
    const info = await lstat(path);
    assert(!info.isSymbolicLink());
    assert.equal(isDirectory ? info.isDirectory() : info.isFile(), true);
    assert.equal(info.uid, uid);
    assert.equal(info.mode & 0o022, 0);
    assert.equal(await realpath(path), path);
    return info;
  };
  const rootIdentity = await owned(directory, true);
  assert.equal(rootIdentity.mode & 0o777, 0o700);
  const original = join(directory, "Host.app");
  const replacement = join(directory, "replacement/Host.payload");
  const currentCatalog = join(directory, "active-catalog.json");
  const updatedCatalog = join(directory, "updated-catalog.json");
  const checkRoot = async () => {
    const now = await owned(directory, true);
    assert.equal(now.dev, rootIdentity.dev);
    assert.equal(now.ino, rootIdentity.ino);
  };
  const checkApp = async (path, version) => {
    await owned(path, true);
    await owned(join(path, "Contents"), true);
    await owned(join(path, "Contents/MacOS"), true);
    const executable = join(path, "Contents/MacOS/Edith");
    await owned(executable, false);
    assert.equal(
      digest(await readFile(executable)),
      fixture.executableSHA256[version],
    );
    await verifyApplication(path, version, fixture.identifier);
  };
  const protectedDigests = async () => {
    for (const [relative, expected] of Object.entries(
      fixture.protectedSHA256,
    )) {
      assert(
        !relative.startsWith("/") &&
          !relative.split("/").some((part) => ["", ".", ".."].includes(part)),
      );
      const path = join(directory, relative);
      await owned(path, false);
      assert.equal(digest(await readFile(path)), expected);
    }
  };
  const boundedCatalog = async (path) => {
    const info = await owned(path, false);
    assert(info.size > 0 && info.size <= 3_145_728);
    const bytes = await readFile(path);
    const envelope = JSON.parse(bytes);
    assert.deepEqual(Object.keys(envelope).sort(), ["payload", "signature"]);
    assert(
      typeof envelope.payload === "string" &&
        typeof envelope.signature === "string",
    );
    return bytes;
  };
  await checkApp(original, "1.0.0");
  await checkApp(replacement, "2.0.0");
  await protectedDigests();
  const oldCatalog = await boundedCatalog(currentCatalog);
  const nextCatalog = await boundedCatalog(updatedCatalog);
  const oldDigest = digest(oldCatalog);
  const nextDigest = digest(nextCatalog);
  let busy = false;
  let completed = false;
  let failed = false;
  return async (request) => {
    validateReplacementRequest(request, fixture);
    assert(!busy && !completed && !failed, "Replacement is single-use");
    busy = true;
    let moved = false;
    let catalogChanged = false;
    const previousDirectory = join(directory, "previous");
    const previous = join(previousDirectory, "Host.payload");
    const staged = join(
      directory,
      `replacement/staged-${randomUUID()}.payload`,
    );
    const writeCatalog = async (bytes) => {
      const path = join(directory, `catalog-${randomUUID()}.tmp`);
      const handle = await open(path, "wx", 0o600);
      try {
        await handle.writeFile(bytes);
        await handle.sync();
      } finally {
        await handle.close();
      }
      try {
        await rename(path, currentCatalog);
      } catch (error) {
        await rm(path);
        throw error;
      }
    };
    try {
      await checkRoot();
      await checkApp(original, "1.0.0");
      await checkApp(replacement, "2.0.0");
      await protectedDigests();
      assert.equal(digest(await boundedCatalog(currentCatalog)), oldDigest);
      assert.equal(digest(await boundedCatalog(updatedCatalog)), nextDigest);
      validateReplacementProcesses(await audit());
      await copy(replacement, staged, {
        recursive: true,
        force: false,
        errorOnExist: true,
      });
      await checkApp(staged, "2.0.0");
      await checkRoot();
      validateReplacementProcesses(await audit());
      await mkdir(previousDirectory, { recursive: false, mode: 0o700 });
      await rename(original, previous);
      moved = true;
      await rename(staged, original);
      await checkApp(original, "2.0.0");
      await registerApplication("2.0.0");
      catalogChanged = true;
      await writeCatalog(nextCatalog);
      await checkRoot();
      await protectedDigests();
      assert.equal(digest(await boundedCatalog(currentCatalog)), nextDigest);
      validateReplacementProcesses(await audit());
      completed = true;
      return {
        schema: 1,
        operation: "replaceApplication",
        hostIdentifier: fixture.identifier,
        sourceCommit: fixture.sourceCommit,
        applicationVersion: "2.0.0",
        executableSHA256: fixture.executableSHA256["2.0.0"],
        catalogSHA256: nextDigest,
        priorOwnedGenerationsExited: true,
      };
    } catch (error) {
      if (moved) {
        failed = true;
        await checkRoot();
        const app = await lstat(original).catch((failure) => {
          if (failure.code !== "ENOENT") throw failure;
        });
        if (app) {
          await owned(original, true);
          await rm(original, { recursive: true });
        }
        await rename(previous, original);
        if (catalogChanged) await writeCatalog(oldCatalog);
        await checkApp(original, "1.0.0");
        await registerApplication("1.0.0");
      }
      throw error;
    } finally {
      busy = false;
      const info = await lstat(staged).catch((error) => {
        if (error.code !== "ENOENT") throw error;
      });
      if (info) {
        await owned(staged, true);
        await rm(staged, { recursive: true });
      }
    }
  };
}

export function validateReplacementAuthorization(request, token) {
  assert.match(token, /^[a-f0-9]{64}$/);
  assert(
    (request.method === "POST" &&
      request.url === "/replace" &&
      request.contentType === "application/json") ||
      (request.method === "GET" &&
        request.url === "/state" &&
        request.contentType === undefined),
  );
  assert.equal(request.remoteAddress, "127.0.0.1");
  assert(
    typeof request.authorization === "string" &&
      request.authorization.length === 71,
  );
  assert(
    timingSafeEqual(
      Buffer.from(request.authorization),
      Buffer.from(`Bearer ${token}`),
    ),
  );
}

export async function createJourneyStateReader({
  directory,
  environment,
  accountHome,
  fixture,
  uid = process.getuid(),
}) {
  admitHostedJourney(environment, directory, fixture.identifier, accountHome);
  assert.equal(fixture.directory, directory);
  assert.match(fixture.sourceCommit, /^[a-f0-9]{40}$/);
  const root = await lstat(directory);
  assert(
    root.isDirectory() &&
      !root.isSymbolicLink() &&
      root.uid === uid &&
      (root.mode & 0o777) === 0o700,
  );
  assert.equal(await realpath(directory), directory);
  return async () => {
    const current = await lstat(directory);
    assert(
      current.isDirectory() &&
        !current.isSymbolicLink() &&
        current.uid === uid &&
        (current.mode & 0o777) === 0o700,
    );
    assert.equal(current.dev, root.dev);
    assert.equal(current.ino, root.ino);
    assert.equal(await realpath(directory), directory);
    const readFixedFile = async (name, maximumBytes) => {
      assert(name === "producer.json" || name === "state.json");
      const file = await open(
        join(directory, name),
        constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK,
      );
      try {
        const before = await file.stat({ bigint: true });
        assert(
          before.isFile() &&
            before.uid === BigInt(uid) &&
            (before.mode & 0o7777n) === 0o600n &&
            before.nlink === 1n &&
            before.size > 0n &&
            before.size <= BigInt(maximumBytes),
        );
        const bytes = Buffer.alloc(Number(before.size) + 1);
        const { bytesRead } = await file.read(bytes, 0, bytes.length, 0);
        assert.equal(BigInt(bytesRead), before.size);
        const after = await file.stat({ bigint: true });
        assert(after.isFile());
        for (const field of [
          "dev",
          "ino",
          "uid",
          "mode",
          "nlink",
          "size",
          "mtimeNs",
          "ctimeNs",
        ])
          assert.equal(after[field], before[field]);
        return JSON.parse(bytes.subarray(0, bytesRead));
      } finally {
        await file.close();
      }
    };
    const producer = await readFixedFile("producer.json", 1024);
    assert.deepEqual(
      Object.keys(producer).sort(),
      ["schema", "hostIdentifier", "sourceCommit", "phase", "category"].sort(),
    );
    assert.equal(producer.schema, 1);
    assert.equal(producer.hostIdentifier, fixture.identifier);
    assert.equal(producer.sourceCommit, fixture.sourceCommit);
    assert.equal(producer.phase, "telemetry");
    assert.equal(producer.category, "ready");
    const state = await readFixedFile("state.json", 131_072);
    assert.equal(state.schema, 1);
    assert.equal(state.hostIdentifier, fixture.identifier);
    assert.equal(state.sourceCommit, fixture.sourceCommit);
    assert(fixture.appVersions.includes(state.applicationVersion));
    assert.equal(
      state.producerExecutableSHA256,
      fixture.executableSHA256[state.applicationVersion],
    );
    assert.equal(state.protectedDataUnchanged, true);
    assert.equal(state.declinedPermissionRequests, 0);
    const result = {
      schema: 1,
      operation: "state",
      hostIdentifier: fixture.identifier,
      sourceCommit: fixture.sourceCommit,
      state,
    };
    assert(Buffer.byteLength(JSON.stringify(result)) <= 131_072);
    return result;
  };
}

export async function startJourneyReplacementOperator(
  replace,
  { readState, stateTimeoutMs = 2000 } = {},
) {
  assert(
    Number.isInteger(stateTimeoutMs) &&
      stateTimeoutMs > 0 &&
      stateTimeoutMs <= 2000,
  );
  const token = randomBytes(32).toString("hex");
  const server = createServer(async (request, response) => {
    try {
      validateReplacementAuthorization(
        {
          method: request.method,
          url: request.url,
          remoteAddress: request.socket.remoteAddress,
          authorization: request.headers.authorization,
          contentType: request.headers["content-type"],
        },
        token,
      );
      if (request.method === "GET") {
        assert(
          request.headers["content-length"] === undefined ||
            request.headers["content-length"] === "0",
        );
        assert(request.headers["transfer-encoding"] === undefined);
        assert.equal(typeof readState, "function");
        let deadline;
        let result;
        try {
          result = await Promise.race([
            readState(),
            new Promise((_, reject) => {
              deadline = setTimeout(
                () => reject(Error("State read deadline exceeded")),
                stateTimeoutMs,
              );
            }),
          ]);
        } finally {
          clearTimeout(deadline);
        }

        const bytes = JSON.stringify(result);
        assert(Buffer.byteLength(bytes) <= 131_072);
        response.writeHead(200, {
          "Content-Type": "application/json",
          "Cache-Control": "no-store",
        });
        response.end(bytes);
        return;
      }
      let bytes = Buffer.alloc(0);
      for await (const chunk of request) {
        assert(bytes.length + chunk.length <= 1_024);
        bytes = Buffer.concat([bytes, chunk]);
      }
      assert(bytes.length > 0);
      const result = await replace(JSON.parse(bytes));
      response.writeHead(200, {
        "Content-Type": "application/json",
        "Cache-Control": "no-store",
      });
      response.end(JSON.stringify(result));
    } catch {
      response.writeHead(request.method === "GET" ? 503 : 409, {
        "Content-Type": "application/json",
        "Cache-Control": "no-store",
      });
      response.end(
        JSON.stringify({
          schema: 1,
          outcome: "rejected",
          category:
            request.method === "GET"
              ? "state-unavailable"
              : "replacement-rejected",
        }),
      );
    }
  });
  server.requestTimeout = 15_000;
  server.headersTimeout = 5_000;
  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", resolve);
  });
  const address = server.address();
  assert(address && typeof address === "object");
  return {
    endpoint: `http://127.0.0.1:${address.port}/replace`,
    token,
    close: () =>
      new Promise((resolve, reject) => {
        server.close((error) => (error ? reject(error) : resolve()));
        server.closeIdleConnections();
      }),
  };
}
