import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { constants } from "node:fs";
import { lstat, open, realpath, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { promisify } from "node:util";
import { validateManagedViewProof } from "./contract.mjs";
import {
  recordManagedHostObservation,
  validateManagedApprovalReceipt,
} from "./process-proof.mjs";
import {
  configureManagedUITestRun,
  managedRunnerEnvironment,
} from "./ui-project.mjs";

const execute = promisify(execFile);
export async function readOwnedManagedDocument(
  directory,
  name,
  maximum = 65536,
  afterRead = async () => {},
) {
  assert(
    [
      "result-managed-shipping.json",
      "approval-result.json",
      "fixture.json",
    ].includes(name),
  );
  assert.equal(await realpath(directory), directory);
  assert(Number.isSafeInteger(maximum) && maximum > 0 && maximum <= 131072);
  const root = await open(
    directory,
    constants.O_RDONLY | constants.O_DIRECTORY | constants.O_NOFOLLOW,
  );
  let handle;
  try {
    const rootBefore = await root.stat({ bigint: true });
    assert(
      rootBefore.isDirectory() &&
        rootBefore.uid === BigInt(process.getuid()) &&
        (rootBefore.mode & 0o7777n) === 0o700n,
    );
    handle = await open(
      join(directory, name),
      constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK,
    );
    const before = await handle.stat({ bigint: true });
    assert(
      before.isFile() &&
        before.uid === BigInt(process.getuid()) &&
        before.nlink === 1n &&
        before.size > 0n &&
        before.size <= BigInt(maximum),
    );
    const mode = before.mode & 0o7777n;
    assert(
      name === "approval-result.json"
        ? mode === 0o600n
        : mode === 0o600n || mode === 0o644n,
    );
    const buffer = Buffer.alloc(maximum + 1);
    const { bytesRead } = await handle.read(buffer, 0, buffer.length, 0);
    assert.equal(BigInt(bytesRead), before.size);
    await afterRead();
    const after = await handle.stat({ bigint: true });
    for (const key of [
      "dev",
      "ino",
      "uid",
      "mode",
      "nlink",
      "size",
      "mtimeNs",
      "ctimeNs",
    ])
      assert.equal(after[key], before[key]);
    const current = await lstat(join(directory, name), { bigint: true });
    for (const key of [
      "dev",
      "ino",
      "uid",
      "mode",
      "nlink",
      "size",
      "mtimeNs",
      "ctimeNs",
    ])
      assert.equal(current[key], before[key]);
    const rootAfter = await lstat(directory, { bigint: true });
    for (const key of ["dev", "ino", "uid", "mode"])
      assert.equal(rootAfter[key], rootBefore[key]);
    assert.equal(await realpath(directory), directory);
    return JSON.parse(buffer.subarray(0, bytesRead).toString("utf8"));
  } finally {
    await handle?.close();
    await root.close();
  }
}

export function managedToolEnvironment(environment) {
  const result = {};
  for (const key of [
    "PATH",
    "HOME",
    "TMPDIR",
    "DEVELOPER_DIR",
    "LANG",
    "LC_ALL",
  ])
    if (environment[key] !== undefined) result[key] = environment[key];
  assert(typeof result.HOME === "string" && result.HOME.startsWith("/"));
  return result;
}

export async function runManagedOwner({
  fixture,
  owner,
  plan,
  resultBundle,
  auditExecutable,
  environment,
  runCommand,
  audit,
  configure = configureManagedUITestRun,
  pause = (milliseconds) =>
    new Promise((resolve) => setTimeout(resolve, milliseconds)),
}) {
  const variables = managedRunnerEnvironment(environment, fixture);
  configure(plan, variables);
  const toolEnvironment = managedToolEnvironment(environment);
  const auditEnvironment = { ...toolEnvironment, ...variables };
  const inspect =
    audit ??
    (async () => {
      const { stdout } = await execute(auditExecutable, [fixture.directory], {
        env: auditEnvironment,
        timeout: 10000,
        maxBuffer: 16384,
      });
      return JSON.parse(stdout);
    });
  const ledger = [];
  let stopping = false,
    observationFailure;
  const observe = async () => {
    while (!stopping) {
      try {
        recordManagedHostObservation(
          ledger,
          await inspect(),
          fixture,
          process.getuid(),
        );
      } catch (error) {
        observationFailure = error;
        stopping = true;
        return;
      }
      if (!stopping) await pause(150);
    }
  };
  recordManagedHostObservation(
    ledger,
    await inspect(),
    fixture,
    process.getuid(),
  );
  const observer = observe();
  let commandFailure;
  try {
    await runCommand(
      "xcodebuild",
      [
        "test-without-building",
        "-xctestrun",
        plan,
        "-destination",
        "platform=macOS,arch=arm64",
        "-jobs",
        "1",
        "-parallel-testing-enabled",
        "NO",
        "-resultBundlePath",
        resultBundle,
      ],
      { stdio: "inherit", env: toolEnvironment, timeoutMs: 360000 },
    );
  } catch (error) {
    commandFailure = error;
  } finally {
    stopping = true;
    await observer;
  }
  if (observationFailure) throw observationFailure;
  assert.deepEqual(
    await inspect(),
    [],
    "The exact owned fixture Host remained running after XCTest exit",
  );
  if (commandFailure) throw commandFailure;
  assert.equal(
    ledger.length,
    1,
    "No actual independently observed fixture Host execution",
  );
  const proof = validateManagedViewProof(
    await readOwnedManagedDocument(
      fixture.directory,
      "result-managed-shipping.json",
    ),
    owner,
    fixture.package,
  );
  let approval = {
    publicApprovalValidated: false,
    approvalNotRequested: true,
    managedViewReady: false,
  };
  try {
    approval = validateManagedApprovalReceipt(
      await readOwnedManagedDocument(
        fixture.directory,
        "approval-result.json",
        16384,
      ),
      fixture,
      ledger,
    );
  } catch (error) {
    if (error.code !== "ENOENT") throw error;
  }
  const result = {
    schema: 1,
    extensionID: owner.id,
    fixtureSourceCommit: fixture.sourceCommit,
    originalSourceCommit: fixture.originalSourceCommit,
    fixtureZipSHA256: fixture.package.sha256,
    originalZipSHA256: fixture.originalZipSHA256,
    nativePayloadScope:
      "Payload/<id>/<role>.bundle only, excluding signatures and all Host executable carriers",
    hostCarrierTransformationVerified: true,
    hostObservations: ledger.map(({ pid, generation, uid }) => ({
      pid,
      generation,
      uid,
    })),
    hostExited: true,
    approval,
    proof,
  };
  await writeFile(
    join(fixture.directory, "execution-result.json"),
    JSON.stringify(result, null, 2),
    { flag: "wx", mode: 0o600 },
  );
  return result;
}
