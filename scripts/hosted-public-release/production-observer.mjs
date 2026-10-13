import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { createHash, generateKeyPairSync, randomUUID, sign } from "node:crypto";
import { constants } from "node:fs";
import { lstat, mkdir, open, readFile, realpath, rm } from "node:fs/promises";
import { userInfo } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { runOwnedJourneyCommand } from "../hosted-original-shell/owned-command.mjs";
import {
  boundedProductionFile,
  productionVerifiedInputs,
} from "./production-inputs.mjs";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const digest = (bytes) => createHash("sha256").update(bytes).digest("hex");
const actions = new Set([
  "finishWelcome",
  "goHome",
  "widgetEditor",
  "home",
  "notch",
  "addKeep",
  "openEdithMenu",
  "checkUpdates",
  "installUpdate",
  "installRelaunch",
  "pressKeep",
]);
const identityKeys = [
  "role",
  "pid",
  "generation",
  "executable",
  "codeHash",
  "running",
];
function canonical(value) {
  const sort = (entry) =>
    Array.isArray(entry)
      ? entry.map(sort)
      : entry !== null && typeof entry === "object"
        ? Object.fromEntries(
            Object.keys(entry)
              .sort()
              .map((key) => [key, sort(entry[key])]),
          )
        : entry;
  return Buffer.from(JSON.stringify(sort(value)));
}
export function productionObserverHosted(environment, sourceCommit) {
  for (const [key, value] of Object.entries({
    GITHUB_ACTIONS: "true",
    RUNNER_ENVIRONMENT: "github-hosted",
    RUNNER_OS: "macOS",
    GITHUB_REPOSITORY: "pulkitxm/edith",
    GITHUB_REPOSITORY_ID: "1289153439",
    GITHUB_EVENT_NAME: "workflow_dispatch",
    GITHUB_REF: "refs/heads/main",
    GITHUB_SHA: sourceCommit,
    PUBLIC_RELEASE_VERIFICATION: "1",
    PUBLISH: "false",
    REBUILD: "",
  }))
    assert.equal(environment[key], value);
  assert(["65671483", "320458784"].includes(environment.GITHUB_ACTOR_ID));
}

export function productionObserverEnvironment(environment, accountHome) {
  assert.equal(environment.HOME, accountHome);
  assert(!Object.keys(environment).some((key) => key.startsWith("EDITH_")));
  for (const key of [
    "CFFIXED_USER_HOME",
    "PYTHONPATH",
    "PYTHONHOME",
    "NODE_OPTIONS",
    "NODE_PATH",
    "SSH_AUTH_SOCK",
  ])
    assert(environment[key] === undefined);
  return Object.fromEntries(
    ["HOME", "PATH", "TMPDIR", "DEVELOPER_DIR", "LANG", "LC_ALL"]
      .filter((key) => environment[key] !== undefined)
      .map((key) => [key, environment[key]]),
  );
}
async function privateDirectory(path) {
  await mkdir(path, { mode: 0o700 });
  assert.equal(await realpath(path), path);
  const info = await lstat(path);
  assert(
    info.isDirectory() &&
      info.uid === process.getuid() &&
      (info.mode & 0o777) === 0o700,
  );
}
async function privateFile(path, bytes) {
  const handle = await open(
    path,
    constants.O_WRONLY |
      constants.O_CREAT |
      constants.O_EXCL |
      constants.O_NOFOLLOW,
    0o600,
  );
  try {
    await handle.writeFile(bytes);
    await handle.sync();
  } finally {
    await handle.close();
  }
}
function validatedIdentity(value, roles) {
  assert.deepEqual(Object.keys(value).sort(), [...identityKeys].sort());
  assert(
    Number.isInteger(value.pid) && value.pid > 1 && value.pid !== process.pid,
  );
  assert(/^[0-9]+:[0-9]+$/.test(value.generation));
  assert(typeof value.running === "boolean");
  assert(
    roles.some(
      (role) =>
        role.role === value.role &&
        role.executable === value.executable &&
        role.codeHash === value.codeHash,
    ),
  );
  return value;
}
export async function observeProductionHistory(
  expected,
  inspect,
  deadline = performance.now() + 10000,
  now = () => performance.now(),
) {
  assert(Array.isArray(expected) && expected.length <= 24);
  assert.equal(
    new Set(expected.map((row) => `${row.role}:${row.pid}:${row.generation}`))
      .size,
    expected.length,
  );
  const roles = expected.map((row) => ({ ...row }));
  for (const row of expected) {
    validatedIdentity(row, roles);
    assert(row.running);
  }
  const actual = [];
  for (let offset = 0; offset < expected.length; offset += 12) {
    const remaining = Math.floor(deadline - now());
    assert(remaining > 0 && remaining <= 60000);
    const batch = expected.slice(offset, offset + 12);
    const rows = await inspect(batch, Math.min(10000, remaining));
    assert(Array.isArray(rows) && rows.length === batch.length);
    rows.forEach((row, index) => {
      validatedIdentity(row, roles);
      assert.deepEqual(
        { ...row, running: true },
        { ...batch[index], running: true },
      );
    });
    assert(now() < deadline);
    actual.push(...rows);
  }
  return actual;
}
export function validateProductionActionResult(action, result, expected) {
  assert(actions.has(action));
  assert.deepEqual(Object.keys(result).sort(), [
    "performedAction",
    "postActionOwners",
  ]);
  assert.equal(result.performedAction, action);
  assert(Array.isArray(result.postActionOwners));
  assert.equal(result.postActionOwners.length, 2);
  const [peer, host] = result.postActionOwners;
  assert.equal(host.role, "host");
  assert(
    peer.role === "host" ||
      (["installUpdate", "installRelaunch"].includes(action) &&
        peer.role === "sparkleUpdater"),
  );
  for (const row of result.postActionOwners) {
    validatedIdentity(row, expected);
    const matches = expected.filter(
      (value) =>
        value.pid === row.pid &&
        value.generation === row.generation &&
        value.role === row.role,
    );
    assert.equal(matches.length, 1);
    assert(matches[0].running);
    assert.deepEqual({ ...row, running: true }, matches[0]);
    if (action !== "installRelaunch") assert(row.running);
  }
  return result;
}
export async function prepareProductionObserver(capability) {
  const verified = productionVerifiedInputs(capability);
  const sourceCommit = verified.request.source;
  const roles = [...verified.roles];
  assert.match(sourceCommit, /^[a-f0-9]{40}$/);
  productionObserverHosted(process.env, sourceCommit);
  const accountHome = userInfo().homedir;
  assert.equal(await realpath(accountHome), accountHome);
  const environment = productionObserverEnvironment(process.env, accountHome);
  for (const path of [
    "/Applications/Edith.app",
    ...[
      "/Library/Application Support/Edith",
      "/Library/Caches/Edith",
      "/Library/Logs/Edith",
      "/Library/Preferences/com.pulkit.edith.plist",
      "/Library/Preferences/com.pulkit.edith.host.plist",
      "/Library/Preferences/com.pulkit.edith.shared.plist",
    ].map((suffix) => accountHome + suffix),
  ]) {
    await lstat(path).then(
      () => {
        throw Error("Preexisting production application or state");
      },
      (error) => assert.equal(error.code, "ENOENT"),
    );
  }
  const sourcePaths = [
    "Packages/EdithHost/Sources/EdithHostCore/HostRemoteAuthentication.swift",
    "Tests/HostedProductionUpdate/ProducerSources/ProductionHostProbe.swift",
    "scripts/hosted-public-release/production-sparkle-inputs.py",
  ];
  const current = () => {
    assert.equal(
      execFileSync("git", ["rev-parse", "HEAD"], {
        cwd: root,
        env: environment,
        encoding: "utf8",
      }).trim(),
      sourceCommit,
    );
    assert.equal(
      execFileSync(
        "git",
        [
          "status",
          "--porcelain",
          "--untracked-files=all",
          "--",
          ...sourcePaths,
        ],
        { cwd: root, env: environment, encoding: "utf8" },
      ),
      "",
    );
  };
  current();
  const originals = await Promise.all(
    sourcePaths.map(async (path) => {
      const bytes = await readFile(join(root, path));
      assert.deepEqual(
        bytes,
        execFileSync("git", ["show", `${sourceCommit}:${path}`], {
          cwd: root,
          env: environment,
        }),
      );
      return bytes;
    }),
  );
  const sparklePaths = {
    sparkleAutoupdate: "Autoupdate",
    sparkleUpdater: "Updater.app/Contents/MacOS/Updater",
    sparkleDownloader: "XPCServices/Downloader.xpc/Contents/MacOS/Downloader",
    sparkleInstaller: "XPCServices/Installer.xpc/Contents/MacOS/Installer",
  };
  for (const generation of ["previous", "current"]) {
    await verified.revalidate();
    const actual = JSON.parse(
      execFileSync(
        "python3",
        [
          "-I",
          "-B",
          sourcePaths[2],
          join(verified.directory, `host-${generation}/context.json`),
        ],
        {
          cwd: root,
          env: verified.environment,
          timeout: 300000,
          maxBuffer: 65536,
        },
      ),
    );
    assert(Array.isArray(actual) && actual.length === 4);
    assert.deepEqual(
      actual.map(({ role }) => role).sort(),
      Object.keys(sparklePaths).sort(),
    );
    for (const row of actual) {
      assert.deepEqual(
        Object.keys(row).sort(),
        ["role", "executable", "codeHash", "requirement"].sort(),
      );
      assert.equal(
        row.executable,
        `/Applications/Edith.app/Contents/Frameworks/Sparkle.framework/${sparklePaths[row.role]}`,
      );
      assert.match(row.codeHash, /^[a-f0-9]{40}$/);
      assert(
        typeof row.requirement === "string" &&
          row.requirement.length > 0 &&
          row.requirement.length <= 4096,
      );
      const existing = roles.find(
        (value) =>
          value.role === row.role &&
          value.executable === row.executable &&
          value.codeHash === row.codeHash,
      );
      if (existing) assert.deepEqual(existing, row);
      else roles.push(Object.freeze(row));
    }
    current();
  }
  assert(roles.length <= 14);
  const keys = generateKeyPairSync("ed25519");
  const issuer = keys.publicKey
    .export({ format: "der", type: "spki" })
    .subarray(-32)
    .toString("base64");
  let probeSource = originals[1].toString();
  for (const [marker, replacement] of [
    ["__PRODUCTION_COHORT_ISSUER__", issuer],
    ["__PRODUCTION_COHORT_SOURCE__", sourceCommit],
  ]) {
    assert.equal(probeSource.split(marker).length, 2);
    probeSource = probeSource.replace(marker, replacement);
  }
  const parent = join(root, "local/public-host-cohort");
  const parentInfo = await lstat(parent);
  assert(
    parentInfo.isDirectory() &&
      parentInfo.uid === process.getuid() &&
      (parentInfo.mode & 0o777) === 0o700,
  );
  assert.equal(await realpath(parent), parent);
  const directory = join(parent, `observer-${randomUUID()}`);
  await privateDirectory(directory);
  await privateFile(
    join(directory, "HostRemoteAuthentication.swift"),
    originals[0],
  );
  await privateFile(
    join(directory, "ProductionHostProbe.swift"),
    Buffer.from(probeSource),
  );
  const executable = join(directory, "ProductionHostProbe");
  await runOwnedJourneyCommand(
    "xcrun",
    [
      "swiftc",
      "-swift-version",
      "6",
      "-parse-as-library",
      "-target",
      "arm64-apple-macosx14.0",
      join(directory, "HostRemoteAuthentication.swift"),
      join(directory, "ProductionHostProbe.swift"),
      "-o",
      executable,
    ],
    { cwd: root, env: environment, stdio: "inherit", timeoutMs: 180000 },
  );
  current();
  assert.deepEqual(
    await readFile(join(directory, "HostRemoteAuthentication.swift")),
    originals[0],
  );
  assert.equal(
    await readFile(join(directory, "ProductionHostProbe.swift"), "utf8"),
    probeSource,
  );
  const pin = await boundedProductionFile(executable, 16777216, true);
  const requirePin = async () =>
    assert.deepEqual(
      await boundedProductionFile(executable, 16777216, true),
      pin,
    );
  const call = async (args, bytes, timeoutMs = 10000) => {
    assert(Number.isInteger(timeoutMs) && timeoutMs > 0 && timeoutMs <= 10000);
    const deadline = performance.now() + timeoutMs;
    current();
    await verified.revalidate();
    await requirePin();
    const token = randomUUID();
    const input = join(directory, `request-${token}.json`);
    const output = join(directory, `response-${token}.json`);
    await privateFile(input, bytes ?? Buffer.alloc(0));
    const inputHandle = await open(
      input,
      constants.O_RDONLY | constants.O_NOFOLLOW,
    );
    const outputHandle = await open(
      output,
      constants.O_WRONLY |
        constants.O_CREAT |
        constants.O_EXCL |
        constants.O_NOFOLLOW,
      0o600,
    );
    try {
      const remaining = Math.floor(deadline - performance.now());
      assert(remaining > 0);
      await runOwnedJourneyCommand(executable, args, {
        cwd: root,
        env: environment,
        stdio: [inputHandle.fd, outputHandle.fd, "inherit"],
        timeoutMs: remaining,
      });
    } finally {
      await inputHandle.close();
      await outputHandle.close();
    }
    await requirePin();
    const { bytes: result } = await boundedProductionFile(output, 65536);
    await rm(input);
    await rm(output);
    return JSON.parse(result);
  };
  const producer = await call(["producer"]);
  assert.equal(Number(producer.pid), process.pid);
  assert.match(producer.generation, /^[0-9]+:[0-9]+$/);
  assert.equal(producer.executable, await realpath(process.execPath));
  assert.match(producer.codeHash, /^[a-f0-9]{40}$/);
  assert(Array.isArray(roles) && roles.length > 0 && roles.length <= 14);
  const scope = canonical({
    sourceCommit,
    producerPID: process.pid,
    producerGeneration: producer.generation,
    producerExecutable: producer.executable,
    producerCodeHash: producer.codeHash,
    uid: process.getuid(),
    accountHome,
    roles,
  });
  const envelope = {
    payload: scope.toString("base64"),
    signature: sign(null, scope, keys.privateKey).toString("base64"),
  };
  const captured = new Map();
  const key = (row) => `${row.role}:${row.pid}:${row.generation}`;
  const inspect = (operation, observed = [], timeoutMs = 10000) =>
    call([], canonical({ operation, scope: envelope, observed }), timeoutMs);
  const snapshot = async () => {
    const rows = await inspect("snapshot");
    assert(Array.isArray(rows) && rows.length <= 12);
    for (const row of rows) {
      validatedIdentity(row, roles);
      assert(row.running);
      captured.set(key(row), Object.freeze({ ...row }));
    }
    assert(captured.size <= 24);
    return rows;
  };
  const owned = (rows) =>
    rows.map((row) => {
      validatedIdentity(row, roles);
      assert.deepEqual(captured.get(key(row)), row);
      return row;
    });
  const observe = async (rows, deadline) => {
    const expected = owned(rows);
    return observeProductionHistory(
      expected,
      (batch, timeoutMs) => inspect("observe", batch, timeoutMs),
      deadline,
    );
  };
  const cli = async (operation, rows) => {
    assert(
      ["install", "enable", "info", "update", "disable"].includes(operation),
    );
    const hosts = owned(rows).filter(
      (row) => row.role === "host" && row.running,
    );
    assert.equal(hosts.length, 1);
    assert((await observe(hosts))[0].running);
    const token = randomUUID();
    const output = join(directory, `cli-${token}.json`);
    const handle = await open(
      output,
      constants.O_WRONLY |
        constants.O_CREAT |
        constants.O_EXCL |
        constants.O_NOFOLLOW,
      0o600,
    );
    try {
      await runOwnedJourneyCommand(
        "/Applications/Edith.app/Contents/MacOS/Edith",
        ["extensions", operation, "keepAwake", "--json"],
        {
          cwd: root,
          env: environment,
          stdio: ["ignore", handle.fd, "inherit"],
          timeoutMs: 120000,
        },
      );
    } finally {
      await handle.close();
    }
    assert((await observe(hosts))[0].running);
    const { bytes } = await boundedProductionFile(output, 65536);
    const info = JSON.parse(bytes.toString());
    assert.deepEqual(
      Object.keys(info).sort(),
      [
        "id",
        "title",
        "installed",
        "removalPending",
        "disablePending",
        "compatible",
        "enabled",
        "running",
        "processIdentifier",
        "state",
        "version",
        "availableVersion",
        "updateAvailable",
        "offline",
      ].sort(),
    );
    assert.equal(info.id, "keepAwake");
    for (const field of [
      "installed",
      "removalPending",
      "disablePending",
      "compatible",
      "enabled",
      "running",
      "updateAvailable",
      "offline",
    ])
      assert.equal(typeof info[field], "boolean");
    if (info.running) {
      assert(
        Number.isInteger(info.processIdentifier) && info.processIdentifier > 1,
      );
      const actual = await snapshot();
      const engines = actual.filter(
        (row) => row.role === "engine" && row.pid === info.processIdentifier,
      );
      assert.equal(engines.length, 1);
      assert((await observe(engines))[0].running);
    } else assert.equal(info.processIdentifier, null);
    await rm(output);
    return Object.freeze(info);
  };
  return Object.freeze({
    cli,
    snapshot,
    observe,
    state: (rows) => inspect("state", owned(rows)),
    assertions: (rows) => inspect("assertions", owned(rows)),
    quit: (row) => inspect("quit", owned([row])),
    action: async (action, rows) => {
      assert(actions.has(action));
      const expected = owned(rows);
      return validateProductionActionResult(
        action,
        await inspect(action, expected),
        expected,
      );
    },
    sourceSHA256: digest(originals[1]),
    identitySourceSHA256: digest(originals[0]),
    executableSHA256: pin.sha256,
  });
}
