import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { createHash } from "node:crypto";
import { constants } from "node:fs";
import { lstat, open, realpath, unlink } from "node:fs/promises";
import { basename, join, resolve } from "node:path";
import { promisify } from "node:util";
import { admitHostedJourney } from "./prepare-journey.mjs";

const sha256 = (bytes) => createHash("sha256").update(bytes).digest("hex");
const receiptKeys = [
  "schema",
  "hostIdentifier",
  "sourceCommit",
  "applicationVersion",
  "executableSHA256",
  "registrationStatus",
  "registeredCount",
  "uniqueRegisteredPathMatched",
];

export function validateJourneyRegistrationReceipt(receipt, fixture, version) {
  assert.deepEqual(Object.keys(receipt).sort(), [...receiptKeys].sort());
  assert.equal(receipt.schema, 1);
  assert.equal(receipt.hostIdentifier, fixture.identifier);
  assert.equal(receipt.sourceCommit, fixture.sourceCommit);
  assert.equal(receipt.applicationVersion, version);
  assert.equal(receipt.executableSHA256, fixture.executableSHA256[version]);
  assert.equal(receipt.registrationStatus, 0);
  assert.equal(receipt.registeredCount, 1);
  assert.equal(receipt.uniqueRegisteredPathMatched, true);
  return receipt;
}

export async function registerJourneyApplication({
  directory,
  fixture,
  environment,
  accountHome,
  version,
  registrationExecutable,
  execute = promisify(execFile),
  uid = process.getuid(),
}) {
  const fail = (phase, category) =>
    Object.assign(Error("Hosted journey registration rejected"), {
      phase,
      category,
    });
  const owned = async (path, isDirectory) => {
    assert.equal(resolve(path), path);
    assert(!/[\0\r\n]/.test(path));
    const info = await lstat(path);
    assert.equal(isDirectory ? info.isDirectory() : info.isFile(), true);
    assert(
      !info.isSymbolicLink() && info.uid === uid && (info.mode & 0o022) === 0,
    );
    if (!isDirectory) assert.equal(info.nlink, 1);
    assert.equal(await realpath(path), path);
    return info;
  };
  const readOwned = async (path, limit, privateFile = false) => {
    const before = await owned(path, false);
    assert(before.size > 0 && before.size <= limit);
    if (privateFile) assert.equal(before.mode & 0o777, 0o600);
    const handle = await open(
      path,
      constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK,
    );
    try {
      const descriptor = await handle.stat();
      assert.equal(descriptor.dev, before.dev);
      assert.equal(descriptor.ino, before.ino);
      const buffer = Buffer.alloc(before.size + 1);
      let size = 0;
      while (size < buffer.length) {
        const { bytesRead } = await handle.read(
          buffer,
          size,
          buffer.length - size,
          size,
        );
        if (bytesRead === 0) break;
        size += bytesRead;
      }
      const bytes = buffer.subarray(0, size);
      const after = await handle.stat();
      assert.equal(bytes.length, before.size);
      for (const key of ["dev", "ino", "size", "mtimeMs", "ctimeMs"])
        assert.equal(after[key], before[key]);
      const pathAfter = await owned(path, false);
      assert.equal(pathAfter.dev, before.dev);
      assert.equal(pathAfter.ino, before.ino);
      return bytes;
    } finally {
      await handle.close();
    }
  };
  let rootIdentity;
  const verifyRoot = async () => {
    const current = await owned(directory, true);
    assert.equal(current.mode & 0o777, 0o700);
    if (rootIdentity) {
      assert.equal(current.dev, rootIdentity.dev);
      assert.equal(current.ino, rootIdentity.ino);
    }
    return current;
  };
  try {
    admitHostedJourney(environment, directory, fixture.identifier, accountHome);
    assert.equal(await realpath(accountHome), accountHome);
    assert.equal(fixture.schema, 1);
    assert.equal(fixture.directory, directory);
    assert.match(fixture.sourceCommit, /^[a-f0-9]{40}$/);
    assert.deepEqual(fixture.appVersions, ["1.0.0", "2.0.0"]);
    assert.deepEqual(
      Object.keys(fixture.executableSHA256).sort(),
      fixture.appVersions,
    );
    for (const value of Object.values(fixture.executableSHA256))
      assert.match(value, /^[a-f0-9]{64}$/);
    assert(fixture.appVersions.includes(version));
    assert.equal(basename(registrationExecutable), "JourneyRegistration");
    rootIdentity = await verifyRoot();
    const tool = await owned(registrationExecutable, false);
    assert((tool.mode & 0o111) !== 0);
    assert.deepEqual(
      JSON.parse(
        await readOwned(join(directory, "journey.json"), 16_384, true),
      ),
      fixture,
    );
    for (const path of [
      "Host.app",
      "Host.app/Contents",
      "Host.app/Contents/MacOS",
    ])
      await owned(join(directory, path), true);
    await readOwned(join(directory, "Host.app/Contents/Info.plist"), 131_072);
    assert.equal(
      sha256(
        await readOwned(
          join(directory, "Host.app/Contents/MacOS/Edith"),
          268_435_456,
        ),
      ),
      fixture.executableSHA256[version],
    );
    try {
      await owned(join(directory, "registration.json"), false);
      await unlink(join(directory, "registration.json"));
    } catch (error) {
      assert.equal(error.code, "ENOENT");
    }
    await verifyRoot();
  } catch {
    throw fail("registration-admission", "invalid-registration-input");
  }
  try {
    await execute(
      registrationExecutable,
      [
        directory,
        version,
        fixture.sourceCommit,
        fixture.executableSHA256[version],
      ],
      {
        timeout: 30_000,
        maxBuffer: 16_384,
        encoding: "utf8",
        env: {
          PATH: "/usr/bin:/bin:/usr/sbin:/sbin",
          HOME: accountHome,
          CFFIXED_USER_HOME: accountHome,
          GITHUB_ACTIONS: "true",
          RUNNER_OS: "macOS",
          RUNNER_ENVIRONMENT: "github-hosted",
          EDITH_HOSTED_SHELL_JOURNEY: "1",
          EDITH_GUI_FIXTURE_DIRECTORY: directory,
          EDITH_JOURNEY_ACCOUNT_HOME: accountHome,
        },
      },
    );
  } catch (error) {
    let category =
      error.code === "ERR_CHILD_PROCESS_STDIO_MAXBUFFER"
        ? "output-limit-exceeded"
        : error.killed
          ? "timed-out"
          : error.code === "ENOENT"
            ? "tool-unavailable"
            : "command-rejected";
    if (
      category === "command-rejected" &&
      typeof error.stderr === "string" &&
      Buffer.byteLength(error.stderr) <= 16_384
    ) {
      try {
        const failure = JSON.parse(error.stderr);
        if (
          Object.keys(failure).length === 1 &&
          [
            "runner-rejected",
            "paths-rejected",
            "metadata-rejected",
            "signature-rejected",
            "registration-status-rejected",
            "registered-path-rejected",
          ].includes(failure.category)
        )
          category = failure.category;
      } catch {}
    }
    throw fail("registration-command", category);
  }
  try {
    await verifyRoot();
    assert.deepEqual(
      JSON.parse(
        await readOwned(join(directory, "journey.json"), 16_384, true),
      ),
      fixture,
    );
    assert.equal(
      sha256(
        await readOwned(
          join(directory, "Host.app/Contents/MacOS/Edith"),
          268_435_456,
        ),
      ),
      fixture.executableSHA256[version],
    );
    return validateJourneyRegistrationReceipt(
      JSON.parse(
        await readOwned(join(directory, "registration.json"), 16_384, true),
      ),
      fixture,
      version,
    );
  } catch {
    throw fail("registration-read", "invalid-registration-receipt");
  }
}
