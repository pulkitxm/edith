import assert from "node:assert/strict";
import { execFileSync, spawn } from "node:child_process";
import { createHash, generateKeyPairSync, sign } from "node:crypto";
import { existsSync } from "node:fs";
import {
  copyFile,
  cp,
  mkdir,
  mkdtemp,
  readFile,
  realpath,
  rm,
  symlink,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { setTimeout as sleep } from "node:timers/promises";
import {
  buildExtensionSupport,
  rewriteSupportImports,
} from "./build-extension-support.mjs";
import { buildExtensionUICarrier } from "./build-extension-ui-carrier.mjs";

const fixture = await mkdtemp(join(tmpdir(), "edith-cli-fixture-"));
const app = join(fixture, "Edith.app");
const identifier = `com.pulkit.edith.tests.cli-${crypto.randomUUID()}`;
let host;
let identityRoot;
let coreFixturePID;
const home = join(fixture, "Home");
const environment = {
  ...process.env,
  EDITH_CLI_FIXTURE_HOME: home,
  EDITH_CORE_CLI_FIXTURE: "1",
  EDITH_EXTENSION_FIXTURE_HOME: home,
};
const clients = new Set();
const run = (command, args, options = {}) =>
  execFileSync(command, args, { stdio: "pipe", ...options });
const ed = join(app, "Contents/MacOS/ed");
async function command(args, expected = 0, input, options = {}) {
  const result = await new Promise((resolveResult, reject) => {
    const child = spawn(ed, args, {
      stdio: ["pipe", "pipe", "pipe"],
      env: environment,
      ...options,
    });
    clients.add(child);
    const stdout = [];
    const stderr = [];
    const timer = setTimeout(() => {
      child.kill("SIGKILL");
      reject(new Error(`Command hung: ${args.join(" ")}`));
    }, 45000);
    child.stdout.on("data", (data) => {
      stdout.push(data);
    });
    child.stderr.on("data", (data) => {
      stderr.push(data);
    });
    child.on("error", reject);
    child.stdin.on("error", (error) => {
      if (error.code !== "EPIPE") reject(error);
    });
    child.on("close", (code) => {
      clearTimeout(timer);
      clients.delete(child);
      resolveResult({
        code,
        ...(options.rawBytes
          ? {
              stdoutData: Buffer.concat(stdout),
              stderrData: Buffer.concat(stderr),
            }
          : {}),
        stdout: Buffer.concat(stdout).toString("utf8"),
        stderr: Buffer.concat(stderr).toString("utf8"),
      });
    });
    child.stdin.end(input);
  });
  assert.equal(
    result.code,
    expected,
    JSON.stringify({
      args,
      code: result.code,
      stdoutBytes: Buffer.byteLength(result.stdout),
      stderrBytes: Buffer.byteLength(result.stderr),
      stdout: result.stdout.slice(0, 2048),
      stderr: result.stderr.slice(0, 2048),
    }),
  );
  if (args[0] === "calendar" || options.rawResult || options.rawBytes)
    return result;
  if (expected !== 0) {
    assert.equal(result.stdout, "");
    assert.match(result.stderr, /^error: /);
    assert(result.stderr.endsWith("\n"));
    return result;
  }
  assert.equal(result.stderr, "");
  return args.includes("--help") ||
    args.includes("--raw") ||
    args[0] === "--version" ||
    options.plain
    ? result.stdout
    : JSON.parse(result.stdout);
}
async function liveCLI(args) {
  const child = spawn(ed, args, {
    stdio: ["pipe", "pipe", "pipe"],
    env: environment,
  });
  clients.add(child);
  const stdout = [],
    stderr = [];
  child.stdout.on("data", (data) => stdout.push(data));
  child.stderr.on("data", (data) => stderr.push(data));
  child.stdin.on("error", (error) => {
    if (error.code !== "EPIPE") throw error;
  });
  const closed = new Promise((resolveClosed, reject) => {
    child.on("error", reject);
    child.on("close", (code) => {
      clients.delete(child);
      resolveClosed(code);
    });
  });
  return {
    child,
    stdout: () => Buffer.concat(stdout),
    stderr: () => Buffer.concat(stderr),
    finish: async (input) => {
      child.stdin.end(input);
      const code = await Promise.race([
        closed,
        sleep(10000).then(() => {
          throw new Error("Live CLI EOF did not finish");
        }),
      ]);
      assert.equal(code, 0, Buffer.concat(stderr).toString());
    },
  };
}
async function until(predicate) {
  const deadline = Date.now() + 10000;
  while (!(await predicate())) {
    assert(
      Date.now() < deadline,
      `Fixture state timed out: ${predicate.toString()}`,
    );
    await sleep(25);
  }
}
async function mcpClient() {
  const child = spawn(ed, ["mcp"], {
    stdio: ["pipe", "pipe", "pipe"],
    env: environment,
  });
  clients.add(child);
  const pending = new Map();
  const responses = [];
  let sequence = 0;
  let buffered = "";
  let errors = "";
  child.stdout.setEncoding("utf8");
  child.stdout.on("data", (text) => {
    buffered += text;
    let newline = buffered.indexOf("\n");
    while (newline >= 0) {
      const response = JSON.parse(buffered.slice(0, newline));
      buffered = buffered.slice(newline + 1);
      newline = buffered.indexOf("\n");
      responses.push(response);
      const waiting = pending.get(response.id);
      if (waiting) {
        clearTimeout(waiting.timer);
        pending.delete(response.id);
        waiting.resolve(response);
      }
    }
  });
  child.stderr.on("data", (data) => {
    errors += data;
  });
  child.on("close", () => {
    clients.delete(child);
    for (const waiting of pending.values()) {
      clearTimeout(waiting.timer);
      waiting.reject(
        new Error(`MCP closed unexpectedly: ${child.exitCode} ${errors}`),
      );
    }
    pending.clear();
  });
  const send = (value) => child.stdin.write(`${JSON.stringify(value)}\n`);
  const call = (method, params = {}) =>
    new Promise((resolveReply, reject) => {
      const id = ++sequence;
      const timer = setTimeout(() => {
        pending.delete(id);
        reject(new Error(`MCP request timed out: ${method}`));
      }, 10000);
      pending.set(id, { resolve: resolveReply, reject, timer });
      send({ jsonrpc: "2.0", id, method, params });
    });
  const initialized = await call("initialize", {
    protocolVersion: "2025-11-25",
    capabilities: {},
    clientInfo: { name: "synthetic-cli-fixture", version: "1" },
  });
  assert.equal(initialized.result.protocolVersion, "2025-11-25");
  assert.equal(initialized.result.serverInfo.name, "edith");
  send({ jsonrpc: "2.0", method: "notifications/initialized" });
  return {
    call,
    send,
    responses,
    cancel: async () => {
      child.kill("SIGTERM");
      await until(() => child.exitCode !== null || child.signalCode !== null);
      assert.equal(child.exitCode, 130, errors);
    },
    close: async () => {
      child.stdin.end();
      await until(() => child.exitCode !== null);
      assert.equal(child.exitCode, 0, errors);
      assert.equal(errors, "");
      assert.equal(buffered, "");
    },
  };
}
function children() {
  return run("ps", ["-axo", "pid=,ppid=,comm="], { encoding: "utf8" })
    .split("\n")
    .filter((line) => Number(line.trim().split(/\s+/)[1]) === host.pid);
}
function extensionChildren() {
  return children().filter(
    (line) => Number(line.trim().split(/\s+/)[0]) !== coreFixturePID,
  );
}

try {
  await cp(resolve("local/minimal-host/Edith.app"), app, { recursive: true });
  await copyFile(
    "Resources/ed-launcher",
    join(app, "Contents/Resources/ed-launcher"),
  );
  run("chmod", ["755", join(app, "Contents/Resources/ed-launcher")]);
  await copyFile("Resources/ed-launcher", ed);
  run("chmod", ["755", ed]);
  run("codesign", ["--force", "--sign", "-", ed]);
  run("python3", [
    "-c",
    "import plistlib,sys; p=sys.argv[1]; d=plistlib.load(open(p,'rb')); d['CFBundleIdentifier']=sys.argv[2]; plistlib.dump(d,open(p,'wb'))",
    join(app, "Contents/Info.plist"),
    identifier,
  ]);
  run("codesign", ["--force", "--sign", "-", app]);
  run("codesign", ["--verify", "--deep", "--strict", app]);
  const developer =
    process.env.DEVELOPER_DIR ?? "/Applications/Xcode.app/Contents/Developer";
  const build = [
    "build",
    "--package-path",
    "Packages/EdithHost",
    "--build-system",
    "native",
    "--configuration",
    "release",
    "--jobs",
    "1",
    "--product",
    "EdithHost",
    "-Xswiftc",
    "-Osize",
    "-Xswiftc",
    "-D",
    "-Xswiftc",
    "EDITH_CLI_FIXTURE",
    "-Xswiftc",
    "-plugin-path",
    "-Xswiftc",
    `${developer}/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins`,
  ];
  execFileSync("swift", build, { stdio: "inherit" });
  const productsPath = run(
    "swift",
    [
      "build",
      "--package-path",
      "Packages/EdithHost",
      "--build-system",
      "native",
      "--configuration",
      "release",
      "--show-bin-path",
    ],
    { encoding: "utf8" },
  ).trim();
  const binary = join(app, "Contents/MacOS/Edith");
  await copyFile(join(productsPath, "EdithHost"), binary);
  await cp(
    join(productsPath, "EdithHost_EdithHost.bundle"),
    join(app, "Contents/Resources/EdithHost_EdithHost.bundle"),
    { recursive: true, verbatimSymlinks: true },
  );
  const links = run("otool", ["-L", binary], { encoding: "utf8" });
  for (const line of links.split("\n").slice(1)) {
    const dependency = line.trim().split(" ")[0];
    if (dependency.endsWith("/Sparkle.framework/Versions/B/Sparkle"))
      run("install_name_tool", [
        "-change",
        dependency,
        "@rpath/Sparkle.framework/Sparkle",
        binary,
      ]);
  }
  run("install_name_tool", [
    "-add_rpath",
    "@executable_path/../Frameworks",
    binary,
  ]);
  run("install_name_tool", [
    "-add_rpath",
    "@executable_path/../../../../Frameworks",
    binary,
  ]);
  run("strip", ["-rSTx", binary]);
  run("codesign", ["--force", "--sign", "-", app]);
  run("codesign", ["--verify", "--deep", "--strict", app]);
  await mkdir(home, { recursive: true });
  assert.match(await command(["--help"]), /ed extensions ls/);
  assert.match((await command(["--version"])).trim(), /^0\.\d+\.\d+$/);
  await command(["unrecognized"], 2);
  await command(["extensions", "ls"], 4);
  const unavailable = await command(["calendar", "ls"], 4);
  assert.match(unavailable.stderr, /^error: Edith is not running/);
  await command(["--extension-worker"], 2);
  const boundedMCP = await command(
    ["mcp"],
    1,
    `${" ".repeat(512 * 1024 + 1)}\n`,
  );
  assert.equal(boundedMCP.stderr, "error: MCP input exceeds 512 KiB.\n");
  const sdkSource = resolve(
    process.env.EDITH_CLI_FIXTURE_SDK_ROOT ?? process.cwd(),
  );
  assert(
    existsSync(
      join(
        sdkSource,
        "Packages/ExtensionSupport/Sources/EdithExtensionCommands/ExtensionCLIInput.swift",
      ),
    ),
    "Verified shared CLI live-input SDK is required for signed proof",
  );
  const sdkFixture = resolve("local/host-cli-sdk-fixture");
  await mkdir(sdkFixture, { recursive: true });
  await rm(join(sdkFixture, "Packages"), { force: true });
  await rm(join(sdkFixture, "scripts"), { force: true });
  await symlink(join(sdkSource, "Packages"), join(sdkFixture, "Packages"));
  await symlink(resolve("scripts"), join(sdkFixture, "scripts"));
  const support = new Map();
  const { publicKey, privateKey } = generateKeyPairSync("ed25519");
  await writeFile(
    join(fixture, "public.key"),
    publicKey.export({ type: "spki", format: "der" }).subarray(-32),
  );
  const packages = [];
  for (const { id, version, role } of [
    { id: "keepAwake", version: "1.0.0", role: "helper" },
    { id: "keepAwake", version: "1.1.0", role: "helper" },
    { id: "calendar", version: "1.0.0", role: "app" },
  ]) {
    if (!support.has(id)) {
      support.set(
        id,
        buildExtensionSupport(
          sdkFixture,
          ["EdithExtensionArchive", "EdithExtensionCommands"],
          `${id}_${role}_CLIFixture`,
        ),
      );
    }
    const products = support.get(id);
    const payload = join(fixture, `${id}-${version}`, id);
    const bundle = join(payload, `${role}.bundle`);
    const contents = join(bundle, "Contents");
    await mkdir(join(contents, "MacOS"), { recursive: true });
    const source = join(fixture, `Runtime-${id}-${version}.swift`);
    await writeFile(
      source,
      rewriteSupportImports(
        (
          await readFile(
            "Packages/EdithHost/Tests/CLIFixture/Runtime.swift",
            "utf8",
          )
        )
          .replace("VERSION", version)
          .replaceAll("keepAwake", id)
          .replace('"role": "helper"', `"role": "${role}"`),
        products.modules,
      ),
    );
    run("xcrun", [
      "swiftc",
      "-emit-library",
      "-parse-as-library",
      "-Osize",
      "-swift-version",
      "5",
      "-module-name",
      "EdithCLIFixture",
      "-target",
      "arm64-apple-macos14.0",
      source,
      "-I",
      join(products.products, "Modules"),
      "-I",
      products.products,
      "-L",
      products.products,
      `-l${products.product}`,
      "-Xlinker",
      "-dead_strip",
      "-Xlinker",
      "-install_name",
      "-Xlinker",
      "@rpath/EdithCLIFixture",
      "-o",
      join(contents, "MacOS/Runtime"),
    ]);
    const info = {
      CFBundleIdentifier: `com.pulkit.edith.extensions.${id}.${role}`,
      CFBundleExecutable: "Runtime",
      CFBundlePackageType: "BNDL",
      CFBundleShortVersionString: version,
      EdithHostABI: "edith-host-2",
    };
    run("python3", [
      "-c",
      "import json,plistlib,sys; plistlib.dump(json.loads(sys.argv[1]),open(sys.argv[2],'wb'))",
      JSON.stringify(info),
      join(contents, "Info.plist"),
    ]);
    run("codesign", ["--force", "--sign", "-", bundle]);
    await writeFile(
      join(payload, "package.json"),
      JSON.stringify({
        id,
        version,
        hostABI: "edith-host-2",
        architecture: "arm64",
        dependencies: [],
      }),
    );
    await buildExtensionUICarrier({
      hostApp: app,
      payloadDirectory: payload,
      id,
      version,
      hostABI: "edith-host-2",
      development: true,
    });
    const archive = join(fixture, `${id}-${version}.zip`);
    const installedBytes = Number(
      run(
        "python3",
        [
          "-c",
          "import pathlib,sys,zipfile; r=pathlib.Path(sys.argv[1]); fs=sorted(p for p in r.rglob('*') if p.is_file()); z=zipfile.ZipFile(sys.argv[2],'w',zipfile.ZIP_DEFLATED); [z.write(p,p.relative_to(r.parent)) for p in fs]; z.close(); print(sum(p.stat().st_size for p in fs))",
          payload,
          archive,
        ],
        { encoding: "utf8" },
      ),
    );
    const bytes = await readFile(archive);
    packages.push({
      id,
      version,
      hostABI: "edith-host-2",
      architecture: "arm64",
      minimumSystemVersion: 14,
      dependencies: [],
      downloadURL: `https://github.com/pulkitxm/edith/releases/download/${id}-${version}/${id}.zip`,
      sha256: createHash("sha256").update(bytes).digest("hex"),
      downloadBytes: bytes.length,
      installedBytes,
    });
  }
  async function catalog(revision, count) {
    const payload = Buffer.from(
      JSON.stringify({
        schemaVersion: 1,
        revision,
        packages: packages.filter(
          (item, index) => item.id === "calendar" || index < count,
        ),
      }),
    );
    await writeFile(
      join(fixture, "catalog.json"),
      JSON.stringify({
        payload: payload.toString("base64"),
        signature: sign(null, payload, privateKey).toString("base64"),
      }),
    );
  }
  await catalog(1, 1);
  host = spawn(join(app, "Contents/MacOS/Edith"), ["--cli-fixture", fixture], {
    stdio: ["ignore", "ignore", "pipe"],
    env: environment,
  });
  let hostError = "";
  host.stderr.on("data", (data) => {
    hostError += data;
  });
  await until(() => {
    assert(host.exitCode === null, hostError);
    return existsSync(join(fixture, "ready.json"));
  });
  const ready = JSON.parse(await readFile(join(fixture, "ready.json"), "utf8"));
  identityRoot = ready.root;

  await until(() => existsSync(join(fixture, "core-ready.json")));
  const coreReady = JSON.parse(
    await readFile(join(fixture, "core-ready.json"), "utf8"),
  );
  assert.equal(coreReady.owner, host.pid);
  assert(
    coreReady.pid > 1 && coreReady.pid !== host.pid,
    JSON.stringify(coreReady),
  );
  coreFixturePID = coreReady.pid;
  const coreStatus = await command(["agent", "status", "--json"]);
  assert.equal(coreStatus.pid, coreFixturePID);
  assert.equal(coreStatus.state, "enabled");
  assert(coreStatus.residentBytes > 0);
  assert.equal(coreStatus.store, join(identityRoot, "Core/agent.json"));
  assert.equal(coreStatus.schemaVersion, 1);
  assert.equal(coreStatus.protocolVersion, 1);
  assert.deepEqual(
    Object.keys(coreStatus).sort(),
    [
      "state",
      "build",
      "pid",
      "uptimeSeconds",
      "residentBytes",
      "cpuPercent",
      "subscribers",
      "store",
      "schemaVersion",
      "protocolVersion",
    ].sort(),
  );
  const originalStatusText = await command(["agent", "status"], 0, undefined, {
    rawResult: true,
  });
  assert.equal(originalStatusText.stderr, "");
  assert.match(originalStatusText.stdout, /^FIELD\s+VALUE\nstate\s+Enabled\n/);
  assert(originalStatusText.stdout.endsWith("\n"));
  const initialJobs = await command(["agent", "jobs", "--json"]);
  assert.deepEqual(
    initialJobs.map((job) => job.id),
    ["backup.sync", "backup.restore", "storage.inspect"],
  );
  assert(
    initialJobs.every((job) => job.runCount === 0 && job.phase === "idle"),
  );
  const queued = await command(
    ["agent", "run", "storage.inspect"],
    0,
    undefined,
    { rawResult: true },
  );
  assert.deepEqual(queued, {
    code: 0,
    stdout: "queued storage.inspect\n",
    stderr: "",
  });
  await until(async () => {
    const jobs = await command(["agent", "jobs", "--json"]);
    return (
      jobs.find((job) => job.id === "storage.inspect").runCount === 1 &&
      jobs.every((job) => job.phase !== "running")
    );
  });
  const ownedEvents = await command(["agent", "events", "--json"]);
  assert(
    ownedEvents.some(
      (event) =>
        event.name === "storage.inspect" && event.message === "Completed.",
    ),
  );
  assert(ownedEvents.every((event) => typeof event.date === "string"));
  const ownedLogs = await command(["agent", "logs", "--last", "10m", "--json"]);
  assert(
    ownedLogs.some((line) => line.includes("storage.inspect: Completed.")),
  );
  await command(["agent", "run"], 2);
  const unknownJob = await command(["agent", "run", "unknown-owned-job"], 3);
  assert.equal(
    unknownJob.stderr,
    "error: The background job is unavailable: unknown-owned-job\nhint: Choose a job from ed agent jobs.\n",
  );
  const commandDirectory = join(fixture, "CommandDirectory");
  await mkdir(commandDirectory);
  const taskBytes = await command(
    [
      "agent",
      "tasks",
      "exec",
      "--timeout",
      "5",
      "--",
      "/bin/sh",
      "-c",
      "printf 'out\\000tail'; printf 'err\\377' >&2; printf '%s' \"$SYNTHETIC_COMMAND\"; /bin/pwd; exit 7",
    ],
    7,
    undefined,
    {
      rawBytes: true,
      cwd: commandDirectory,
      env: { ...environment, SYNTHETIC_COMMAND: "owned" },
    },
  );
  assert.deepEqual(
    taskBytes.stdoutData,
    Buffer.concat([
      Buffer.from([111, 117, 116, 0, 116, 97, 105, 108]),
      Buffer.from(`owned${await realpath(commandDirectory)}\n`),
    ]),
  );
  assert.deepEqual(taskBytes.stderrData, Buffer.from([101, 114, 114, 255]));
  const taskJSON = await command(
    [
      "agent",
      "tasks",
      "exec",
      "--json",
      "--",
      "/bin/sh",
      "-c",
      "printf 'json'; printf 'error' >&2; exit 9",
    ],
    9,
    undefined,
    { rawResult: true, cwd: commandDirectory },
  );
  const exactTaskResult = JSON.parse(taskJSON.stdout);
  assert.equal(taskJSON.stderr, "");
  assert.equal(exactTaskResult.terminationStatus, 9);
  assert.equal(
    Buffer.from(exactTaskResult.standardOutputData, "base64").toString(),
    "json",
  );
  assert.equal(
    Buffer.from(exactTaskResult.standardErrorData, "base64").toString(),
    "error",
  );
  const detachedTask = await command(
    [
      "agent",
      "tasks",
      "exec",
      "--detach",
      "--json",
      "--",
      "/bin/sh",
      "-c",
      "echo $$ > detached-pid; exec /bin/sleep 120",
    ],
    0,
    undefined,
    { cwd: commandDirectory },
  );
  await until(async () => existsSync(join(commandDirectory, "detached-pid")));
  const detachedTaskPID = Number(
    (await readFile(join(commandDirectory, "detached-pid"), "utf8")).trim(),
  );
  assert(detachedTaskPID > 1 && detachedTaskPID !== coreFixturePID);
  assert(
    (await command(["agent", "tasks", "ls", "--json"])).some(
      (task) =>
        task.id === detachedTask.id &&
        !["succeeded", "failed", "cancelled", "interrupted"].includes(
          task.state,
        ),
    ),
  );
  await command(["agent", "tasks", "cancel", detachedTask.id, "--json"]);
  await until(
    async () =>
      (await command(["agent", "tasks", "inspect", detachedTask.id, "--json"]))
        .snapshot.state === "cancelled",
  );
  assert.throws(() => process.kill(detachedTaskPID, 0), /ESRCH/);
  const callerTask = await liveCLI([
    "agent",
    "tasks",
    "exec",
    "--",
    "/bin/sh",
    "-c",
    `echo $$ > '${join(commandDirectory, "caller-pid")}'; exec /bin/sleep 120`,
  ]);
  await until(async () => existsSync(join(commandDirectory, "caller-pid")));
  const callerTaskPID = Number(
    (await readFile(join(commandDirectory, "caller-pid"), "utf8")).trim(),
  );
  callerTask.child.kill("SIGINT");
  await until(async () => callerTask.child.exitCode !== null);
  assert.equal(callerTask.child.exitCode, 130);
  assert.throws(() => process.kill(callerTaskPID, 0), /ESRCH/);
  const addedSchedule = await command([
    "agent",
    "schedule",
    "add",
    "owned",
    "--every",
    "60s",
    "--cwd",
    commandDirectory,
    "--json",
    "--",
    "/bin/sh",
    "-c",
    "echo $$ > schedule-pid; exec /bin/sleep 120",
  ]);
  assert.equal(addedSchedule.definition.name, "owned");
  await command(["agent", "schedule", "disable", "owned", "--json"]);
  const enabledSchedule = await command([
    "agent",
    "schedule",
    "enable",
    "owned",
    "--json",
  ]);
  const scheduledTask = await command([
    "agent",
    "schedule",
    "run",
    "owned",
    "--json",
  ]);
  await until(async () => existsSync(join(commandDirectory, "schedule-pid")));
  const scheduledTaskPID = Number(
    (await readFile(join(commandDirectory, "schedule-pid"), "utf8")).trim(),
  );
  const scheduledState = (
    await command(["agent", "schedule", "ls", "--json"])
  )[0];
  assert.equal(scheduledState.nextRunAt, enabledSchedule.nextRunAt);
  assert.equal(
    (await command(["agent", "schedule", "rm", "owned", "--json"])).removed,
    true,
  );
  process.kill(scheduledTaskPID, 0);
  await command(["agent", "tasks", "cancel", scheduledTask.id, "--json"]);
  await until(
    async () =>
      (await command(["agent", "tasks", "inspect", scheduledTask.id, "--json"]))
        .snapshot.state === "cancelled",
  );
  assert.throws(() => process.kill(scheduledTaskPID, 0), /ESRCH/);
  await command([
    "agent",
    "schedule",
    "add",
    "retained",
    "--cron",
    "0 * * * *",
    "--json",
    "--",
    "/usr/bin/printf",
    "scheduled",
  ]);
  const retainedGenericTaskID = detachedTask.id;
  await writeFile(join(fixture, "power-request"), "synthetic-owned-test");
  await command(["agent", "jobs", "--json"]);
  const powerProof = JSON.parse(
    await readFile(join(fixture, "power-proof.json"), "utf8"),
  );
  assert.deepEqual(powerProof, {
    pid: coreFixturePID,
    initialPause: false,
    persistedPause: true,
    beforeRuns: 0,
    pausedRuns: 0,
    resumedRuns: 1,
    pausedPID: coreFixturePID,
    resumedPID: coreFixturePID,
    exported: true,
    cloudFileExists: true,
    readyAfter: true,
  });
  assert.equal(
    (await command(["config", "get", "agentPauseAmbientOnBattery", "--json"]))
      .value,
    false,
  );
  process.kill(coreFixturePID, "SIGSTOP");
  try {
    assert.deepEqual(
      await command(["agent", "run", "storage.inspect", "--json"]),
      { queued: "storage.inspect" },
    );
    const cancelled = await command(
      ["agent", "cancel", "storage.inspect"],
      0,
      undefined,
      { rawResult: true },
    );
    assert.deepEqual(cancelled, {
      code: 0,
      stdout: "cancellation requested for storage.inspect\n",
      stderr: "",
    });
  } finally {
    process.kill(coreFixturePID, "SIGCONT");
  }
  await until(async () => {
    const jobs = await command(["agent", "jobs", "--json"]);
    return (
      jobs.find((job) => job.id === "storage.inspect").runCount === 1 &&
      jobs.every((job) => job.phase !== "running")
    );
  });
  const stoppedCorePID = coreFixturePID;
  const restarting = await command(["agent", "restart"], 0, undefined, {
    rawResult: true,
  });
  assert.deepEqual(restarting, {
    code: 0,
    stdout: "background agent restarting\n",
    stderr: "",
  });
  const restartedStatus = await command(["agent", "status", "--json"]);
  coreFixturePID = restartedStatus.pid;
  assert.notEqual(coreFixturePID, stoppedCorePID);
  assert.throws(() => process.kill(stoppedCorePID, 0), /ESRCH/);
  const retainedJobs = await command(["agent", "jobs", "--json"]);
  assert.equal(
    retainedJobs.find((job) => job.id === "storage.inspect").runCount,
    1,
  );
  assert.equal(children().length, 1);
  assert.equal(
    (
      await command([
        "agent",
        "tasks",
        "inspect",
        retainedGenericTaskID,
        "--json",
      ])
    ).snapshot.state,
    "cancelled",
  );
  assert.deepEqual(
    (await command(["agent", "schedule", "ls", "--json"])).map(
      (item) => item.definition.name,
    ),
    ["retained"],
  );
  await command(["agent", "schedule", "rm", "retained", "--json"]);
  for (const operation of ["status", "verify", "doctor"]) {
    const report = await command([
      "extensions",
      operation,
      "calendar",
      "--json",
    ]);
    assert.equal(report.verified, false);
    assert.equal(report.state.phase, "unavailable");
    assert.equal(report.state.runtimePhase, "uninstalled");
    assert(report.checks.some((check) => check.status === "failed"));
  }
  const setupUnavailable = await command(
    ["extensions", "setup", "calendar", "--dry-run", "--json"],
    4,
  );
  assert.match(setupUnavailable.stderr, /owning setup provider is unavailable/);
  assert(!existsSync(join(identityRoot, "Extensions/calendar")));
  const restoredTasks = await command(["agent", "tasks", "ls", "--json"]);
  assert(
    restoredTasks.some(
      (task) => task.id === retainedGenericTaskID && task.state === "cancelled",
    ),
  );
  const missingOwner = await command(["agent", "activity", "status"], 4);
  assert.match(
    missingOwner.stderr,
    /original agent activity provider is unavailable/,
  );

  assert.equal(ready.pid, host.pid);
  await until(() => existsSync(join(fixture, "application-state.json")));
  const applicationState = JSON.parse(
    await readFile(join(fixture, "application-state.json"), "utf8"),
  );
  assert.deepEqual(applicationState, {
    running: true,
    delegateInstalled: true,
    globalMatches: true,
    windows: 0,
    active: false,
    prohibited: true,
  });

  assert.equal(extensionChildren().length, 0);
  const version = await command(["version", "--json"]);
  assert.equal(version.appRunning, true);
  const status = await command(["status", "--json"]);
  assert.equal(status.tools.directory, join(home, "bin"));
  const installDirectory = join(fixture, "CLI Links");
  const installedCLI = await command([
    "install",
    "--directory",
    installDirectory,
    "--json",
  ]);
  assert.deepEqual(installedCLI.linked.sort(), ["ed", "edith"]);
  assert.equal(
    run(join(installDirectory, "ed"), ["--version"], {
      encoding: "utf8",
      env: environment,
    }).trim(),
    version.version,
  );
  const removedCLI = await command([
    "uninstall",
    "--directory",
    installDirectory,
    "--json",
  ]);
  assert.deepEqual(removedCLI.removed.sort(), ["ed", "edith"]);
  assert(!existsSync(join(installDirectory, "ed")));
  const completionScript = await command(["completions", "zsh"], 0, undefined, {
    plain: true,
  });
  assert.match(completionScript, /__complete/);
  assert.equal((await command(["schema"])).type, "object");
  const guide = await command(["guide"], 0, undefined, { plain: true });
  assert.match(guide, /ed config/);
  const appInfo = await command(["app", "info", "--json"]);
  assert.equal(appInfo.bundleID, identifier);
  assert.equal(appInfo.bundlePath, app);
  const diagnostics = await command(["app", "diagnostics", "--json"]);
  assert.equal(diagnostics.pid, host.pid);
  assert(Number.isInteger(diagnostics.idleWakeups));
  assert.equal(diagnostics.agent.running, false);
  const preview = await command(["app", "quit", "--json"]);
  assert.equal(preview.applied, false);
  assert.equal(host.exitCode, null);
  const permissions = await command(["permissions", "ls", "--json"]);
  assert.equal(permissions.appRunning, true);
  assert(permissions.permissions.every((item) => item.granted === false));
  assert(permissions.permissions.some((item) => item.id === "calendar"));
  assert.match(
    await command(["permissions", "ls"], 0, undefined, { plain: true }),
    /PERMISSION/,
  );
  await command(["permissions", "request", "calendar"], 1);
  const configRows = await command(["config", "ls", "--json"]);
  assert(configRows.some((item) => item.key === "mainWindowZoom"));
  const setting = await command([
    "config",
    "set",
    "mainWindowZoom",
    "1.25",
    "--json",
  ]);
  assert.equal(setting.value, 1.25);
  assert.equal(
    await command(["config", "get", "mainWindowZoom"], 0, undefined, {
      plain: true,
    }),
    "1.25\n",
  );
  const importPreview = await command(
    ["config", "import", "-", "--dry-run", "--json"],
    0,
    '{"mainWindowZoom":1.5}',
  );
  assert.deepEqual(importPreview.applied, ["mainWindowZoom"]);
  assert.equal(
    (await command(["config", "get", "mainWindowZoom", "--json"])).value,
    1.25,
  );
  const imported = await command(
    ["config", "import", "-", "--json"],
    0,
    '{"mainWindowZoom":1.5}',
  );
  assert.deepEqual(imported.applied, ["mainWindowZoom"]);
  assert.equal((await command(["config", "export"])).mainWindowZoom, 1.5);
  await command(["config", "set", "mainWindowZoom", "invalid"], 2);
  const cancelledMCP = await mcpClient();
  await cancelledMCP.cancel();
  const invalidCoreValue = await command(
    ["config", "set", "appearance", "invalid"],
    2,
  );
  assert.equal(
    invalidCoreValue.stderr,
    "error: appearance allows: system, light, dark\n",
  );
  const mcp = await mcpClient();
  const initialTools = await mcp.call("tools/list");
  assert(initialTools.result, JSON.stringify(initialTools));
  let tools = initialTools.result.tools;
  assert(tools.some((item) => item.name === "edith_config_get"));
  assert(tools.some((item) => item.name === "edith_agent_tasks_exec"));
  assert(tools.some((item) => item.name === "edith_agent_schedule_add"));
  assert(!tools.some((item) => item.name === "edith_agent_activity_hook"));
  const previewTask = await mcp.call("tools/call", {
    name: "edith_agent_tasks_exec",
    arguments: { arguments: ["--", "/usr/bin/printf", "preview"] },
  });
  assert.equal(JSON.parse(previewTask.result.content[0].text).preview, true);
  const mcpTask = await mcp.call("tools/call", {
    name: "edith_agent_tasks_exec",
    arguments: {
      arguments: [
        "--",
        "/bin/sh",
        "-c",
        "printf 'mcp'; printf 'stderr' >&2; exit 6",
      ],
      confirm: true,
    },
  });
  assert.equal(mcpTask.result.isError, true);
  const mcpTaskResult = JSON.parse(mcpTask.result.content[0].text);
  assert.equal(mcpTaskResult.terminationStatus, 6);
  assert.equal(
    Buffer.from(mcpTaskResult.standardOutputData, "base64").toString(),
    "mcp",
  );
  assert.equal(
    Buffer.from(mcpTaskResult.standardErrorData, "base64").toString(),
    "stderr",
  );
  assert(!tools.some((item) => item.name.startsWith("edith_calendar_")));
  const configTool = await mcp.call("tools/call", {
    name: "edith_config_get",
    arguments: { arguments: ["mainWindowZoom"] },
  });
  assert.equal(configTool.result.isError, false);
  assert.equal(JSON.parse(configTool.result.content[0].text).value, 1.5);
  const importedTool = await mcp.call("tools/call", {
    name: "edith_config_import",
    arguments: { arguments: ["-"], input: '{"mainWindowZoom":1.75}' },
  });
  assert.equal(importedTool.result.isError, false);
  assert.equal(
    (await command(["config", "get", "mainWindowZoom", "--json"])).value,
    1.75,
  );
  const disabled = await command(["calendar", "ls"], 4);
  assert.match(disabled.stderr, /calendar command provider is unavailable/);
  const list = await command(["extensions", "ls"]);
  assert.equal(list.length, 39);
  await command(["extensions", "info", "missing"], 1);
  let info = await command(["extensions", "install", "keepAwake"]);
  assert.equal(info.version, "1.0.0");
  assert.equal(info.running, false);
  await command(["invoke", "keepAwake", "echo"], 1);
  assert.equal(extensionChildren().length, 0);
  info = await command(["extensions", "enable", "keepAwake"]);
  assert.equal(info.running, true);
  assert.equal(extensionChildren().length, 1);
  assert.deepEqual(
    await command([
      "invoke",
      "keepAwake",
      "echo",
      "--json",
      '{"value":"synthetic"}',
    ]),
    { value: "synthetic" },
  );
  assert.deepEqual(
    await command(
      ["invoke", "keepAwake", "echo", "--json", "-"],
      0,
      '{"stdin":true}',
    ),
    { stdin: true },
  );
  await command(["invoke", "keepAwake", "missing"], 1);
  const archive = run(
    "python3",
    [
      "-c",
      "import base64,io,zipfile; b=io.BytesIO(); z=zipfile.ZipFile(b,'w'); z.writestr('fixture.txt','synthetic archive'); z.close(); print(base64.b64encode(b.getvalue()).decode())",
    ],
    { encoding: "utf8" },
  ).trim();
  assert.deepEqual(
    await command([
      "invoke",
      "keepAwake",
      "archive",
      "--json",
      JSON.stringify({ archive }),
    ]),
    { text: "synthetic archive" },
  );
  for (const value of ["", "synthetic 🌤", "first\nsecond\n"]) {
    assert.equal(
      await command([
        "invoke",
        "keepAwake",
        "echo",
        "--json",
        JSON.stringify(value),
        "--raw",
      ]),
      `${value}\n`,
    );
  }
  await command(["invoke", "keepAwake", "echo", "--raw"], 1);
  const marker = join(identityRoot, "Data/keepAwake/wait.ready");
  await command(["invoke", "keepAwake", "wait", "--timeout", "1"], 4);
  await until(() => !existsSync(marker));
  const cancelled = spawn(ed, ["invoke", "keepAwake", "wait"], {
    stdio: "ignore",
  });
  clients.add(cancelled);
  await until(() => existsSync(marker));
  cancelled.kill("SIGTERM");
  await until(() => !existsSync(marker) && cancelled.exitCode !== null);
  assert.equal(cancelled.exitCode, 130);
  clients.delete(cancelled);
  const blocking = command(["invoke", "keepAwake", "blockUI"]);
  await until(() => existsSync(join(identityRoot, "Data/keepAwake/ui.ready")));
  const start = Date.now();
  await command(["extensions", "ls"]);
  assert(Date.now() - start < 900, "Worker UI blocked host control");
  await blocking;
  await command(["extensions", "install", "calendar"]);
  await command(["calendar", "ls"], 4);
  await command(["extensions", "enable", "calendar"]);
  const terminal = await command(["calendar", "list", "--json"]);
  assert.equal(terminal.stdout, '["list","--json"]\n');
  assert.equal(terminal.stderr, "");
  const failure = await command(["calendar", "synthetic-error"], 4);
  assert.equal(failure.stdout, "");
  assert.equal(failure.stderr, "error: synthetic unavailable\n");
  const calendarState = await command(["extensions", "info", "calendar"]);
  assert(Number.isInteger(calendarState.processIdentifier));
  assert(
    extensionChildren().some(
      (line) =>
        Number(line.trim().split(/\s+/)[0]) === calendarState.processIdentifier,
    ),
  );
  const callerDirectory = join(fixture, "Caller Directory");
  await mkdir(callerDirectory);
  await writeFile(
    join(callerDirectory, "input.txt"),
    "synthetic file contents",
  );
  const contextBytes = Buffer.from([0, 255, 65, 10]);
  const contextReply = await command(
    ["calendar", "context", "input.txt", "--json"],
    0,
    contextBytes,
    { cwd: callerDirectory },
  );
  const context = JSON.parse(contextReply.stdout);
  assert.equal(context.workingDirectory, await realpath(callerDirectory));
  assert.equal(context.input, contextBytes.toString("base64"));
  assert.equal(context.interactive, false);
  assert.equal(
    await realpath(context.file),
    join(await realpath(callerDirectory), "input.txt"),
  );
  assert.equal(context.content, "synthetic file contents");
  const largeContextInput = Buffer.alloc(2 * 1024 * 1024, 120);
  const largeContextReply = await command(
    ["calendar", "context", "input.txt", "--json"],
    0,
    largeContextInput,
    { cwd: callerDirectory },
  );
  assert.equal(
    JSON.parse(largeContextReply.stdout).input,
    largeContextInput.toString("base64"),
  );
  await command(
    ["calendar", "context", "input.txt", "--json"],
    2,
    Buffer.alloc(4 * 1024 * 1024 + 1, 120),
    { cwd: callerDirectory },
  );

  const streamed = await command(["calendar", "stream"], 7);
  assert.equal(streamed.stdout, "first\0🌤\nlast\n");
  assert.equal(streamed.stderr, "synthetic diagnostic\n");
  const cliMarker = join(identityRoot, "Data/calendar/cli-wait.ready");
  const finiteInputTool = await mcp.call("tools/call", {
    name: "edith_calendar_stream_input",
    arguments: { input: "finite MCP stdin\0🌤" },
  });
  assert.equal(finiteInputTool.result.isError, false);
  assert.equal(finiteInputTool.result.content[0].text, "finite MCP stdin\0🌤");
  const liveA = await liveCLI(["calendar", "stream-input"]);
  const liveB = await liveCLI(["calendar", "stream-input"]);
  const initialA = Buffer.from([0, 255, 13, 10, 3, 4]);
  const initialB = Buffer.from("synthetic second stream\0🌤");
  liveA.child.stdin.write(initialA);
  liveB.child.stdin.write(initialB);
  await until(
    () =>
      liveA.stdout().length === initialA.length &&
      liveB.stdout().length === initialB.length,
  );
  assert.deepEqual(liveA.stdout(), initialA);
  assert.deepEqual(liveB.stdout(), initialB);
  const tailA = Buffer.alloc(32769, 255);
  await Promise.all([liveA.finish(tailA), liveB.finish(Buffer.from([255, 0]))]);
  assert.deepEqual(liveA.stdout(), Buffer.concat([initialA, tailA]));
  assert.deepEqual(
    liveB.stdout(),
    Buffer.concat([initialB, Buffer.from([255, 0])]),
  );
  assert.equal(liveA.stderr().toString(), "eof\n");
  assert.equal(liveB.stderr().toString(), "eof\n");
  const duplex = await liveCLI(["calendar", "stream-mcp"]);
  const firstFrame = {
    jsonrpc: "2.0",
    id: 1,
    method: "synthetic/first",
    params: { text: "binary\0🌤" },
  };
  const frame = Buffer.from(`${JSON.stringify(firstFrame)}\n`);
  duplex.child.stdin.write(frame.subarray(0, 9));
  await sleep(100);
  assert.equal(duplex.stdout().length, 0);
  duplex.child.stdin.write(frame.subarray(9));
  await until(() => duplex.stdout().includes(10));
  assert.deepEqual(JSON.parse(duplex.stdout().toString()), {
    jsonrpc: "2.0",
    id: 1,
    result: { method: firstFrame.method, params: firstFrame.params },
  });
  const secondFrame = {
    jsonrpc: "2.0",
    id: 2,
    method: "synthetic/second",
    params: { count: 2 },
  };
  await duplex.finish(Buffer.from(`${JSON.stringify(secondFrame)}\n`));
  const replies = duplex
    .stdout()
    .toString()
    .trim()
    .split("\n")
    .map((line) => JSON.parse(line));
  assert.equal(replies.length, 2);
  assert.deepEqual(replies[1], {
    jsonrpc: "2.0",
    id: 2,
    result: { method: secondFrame.method, params: secondFrame.params },
  });
  assert.equal(duplex.stderr().length, 0);
  const ptyProof = JSON.parse(
    run(
      "python3",
      ["Packages/EdithHost/Tests/CLIFixture/test-caller-pty.py", ed],
      { env: environment, timeout: 40000, encoding: "utf8" },
    ),
  );
  assert.deepEqual(
    ptyProof.ownedCallerPTY.map((value) => value.exitCode),
    [0, 130],
  );
  assert(
    ptyProof.ownedCallerPTY.every(
      (value) => value.exactBytes && value.resize && value.termiosRestored,
    ),
  );
  assert.equal(host.exitCode, null, hostError);
  assert.equal(host.signalCode, null, hostError);
  const streamCancelled = spawn(ed, ["calendar", "stream-wait"], {
    stdio: ["ignore", "pipe", "pipe"],
    env: environment,
  });
  clients.add(streamCancelled);
  let streamCancellationErrors = "";
  streamCancelled.stderr.on("data", (data) => {
    streamCancellationErrors += data;
  });
  await until(() => {
    assert.equal(
      streamCancelled.exitCode,
      null,
      `${streamCancellationErrors}; host pid=${host.pid} exit=${host.exitCode} signal=${host.signalCode}; ${hostError}`,
    );
    return existsSync(cliMarker);
  });
  streamCancelled.kill("SIGTERM");
  await until(
    () => streamCancelled.exitCode !== null && !existsSync(cliMarker),
  );
  clients.delete(streamCancelled);
  assert.equal(streamCancelled.exitCode, 130);
  tools = (await mcp.call("tools/list")).result.tools;
  assert(tools.some((item) => item.name === "edith_calendar_list"));
  const calendarTool = await mcp.call("tools/call", {
    name: "edith_calendar_list",
  });
  assert.equal(calendarTool.result.isError, false);
  assert.equal(calendarTool.result.content[0].text, '["list","--json"]\n');
  const failedTool = await mcp.call("tools/call", {
    name: "edith_calendar_synthetic_error",
  });
  assert.equal(failedTool.result.isError, true);
  assert.equal(
    failedTool.result.content[0].text,
    "error: synthetic unavailable\n",
  );
  mcp.send({
    jsonrpc: "2.0",
    id: 700,
    method: "tools/call",
    params: { name: "edith_calendar_wait" },
  });
  await until(() => existsSync(cliMarker));
  mcp.send({
    jsonrpc: "2.0",
    method: "notifications/cancelled",
    params: { requestId: 700 },
  });
  await until(() => !existsSync(cliMarker));
  await mcp.call("ping");
  assert(!mcp.responses.some((reply) => reply.id === 700));
  await command(["extensions", "disable", "calendar"]);
  await command(["calendar", "ls"], 4);
  tools = (await mcp.call("tools/list")).result.tools;
  assert(!tools.some((item) => item.name.startsWith("edith_calendar_")));
  const disabledTool = await mcp.call("tools/call", {
    name: "edith_calendar_list",
  });
  assert.equal(disabledTool.error.code, -32602);
  await mcp.close();
  await command(["extensions", "remove", "calendar"]);
  await until(() => extensionChildren().length === 1);
  await catalog(2, 2);
  info = await command(["extensions", "update", "keepAwake"]);
  assert.equal(info.version, "1.1.0");
  assert.equal(info.running, true);
  assert.deepEqual(await command(["invoke", "keepAwake", "echo"]), {});
  run("python3", [
    "-c",
    "import json,socket,struct,sys; s=socket.socket(socket.AF_UNIX); s.settimeout(3); s.connect(sys.argv[1]); p=json.dumps({'action':'remove','id':'keepAwake','payload':'e30=','timeout':30,'pid':int(sys.argv[2]),'executable':sys.argv[3]}).encode(); s.sendall(struct.pack('>I',len(p))+p); h=s.recv(4); d=s.recv(struct.unpack('>I',h)[0]) if len(h)==4 else b''; assert not d or json.loads(d).get('error')",
    ready.socket,
    String(host.pid),
    join(app, "Contents/MacOS/Edith"),
  ]);
  assert.equal(
    (await command(["extensions", "info", "keepAwake"])).running,
    true,
  );
  const largerInput = "x".repeat(512 * 1024);
  assert.equal(
    await command(
      ["invoke", "keepAwake", "echo", "--json", "-"],
      0,
      JSON.stringify(largerInput),
    ),
    largerInput,
  );
  await command(
    ["invoke", "keepAwake", "echo", "--json", "-"],
    2,
    `"${"x".repeat(8 * 1024 * 1024)}"`,
  );
  await rm(join(fixture, "catalog.json"));
  await rm(join(fixture, "keepAwake-1.1.0.zip"));
  await command(["extensions", "install", "colorPicker"], 1);
  info = await command(["extensions", "info", "keepAwake"]);
  assert.equal(info.running, true);
  assert.equal(info.offline, true);
  info = await command(["extensions", "disable", "keepAwake"]);
  assert.equal(info.running, false);
  assert.equal(info.enabled, false);
  await until(() => extensionChildren().length === 0);
  await command(["invoke", "keepAwake", "echo"], 1);
  info = await command(["extensions", "remove", "keepAwake"]);
  assert.equal(info.installed, false);
  assert.equal(extensionChildren().length, 0);
  await catalog(3, 2);
  await command(["extensions", "install", "calendar"]);
  await command(["extensions", "enable", "calendar"]);
  const stoppingState = await command(["extensions", "info", "calendar"]);
  const stoppingCommand = spawn(ed, ["calendar", "stream-wait"], {
    stdio: "ignore",
    env: environment,
  });
  clients.add(stoppingCommand);
  await until(() => existsSync(cliMarker));
  const quit = await command(["app", "quit", "--yes", "--json"]);
  assert.equal(quit.requested, true);
  assert.equal(quit.applied, true);
  try {
    await until(() => host.exitCode !== null || host.signalCode !== null);
  } catch (error) {
    const progress = existsSync(join(fixture, "shutdown.json"))
      ? await readFile(join(fixture, "shutdown.json"), "utf8")
      : "owned shutdown did not finish";
    const applicationState = existsSync(join(fixture, "application-state.json"))
      ? await readFile(join(fixture, "application-state.json"), "utf8")
      : "missing application state";
    throw new Error(
      `${error.message}; ${progress}; ${applicationState}; ${hostError}`,
    );
  }

  const shutdown = JSON.parse(
    await readFile(join(fixture, "shutdown.json"), "utf8"),
  );
  assert.deepEqual(shutdown, { coreStopped: true, activeWorkers: 0 });
  await until(() => stoppingCommand.exitCode !== null);
  clients.delete(stoppingCommand);
  assert.notEqual(stoppingCommand.exitCode, 0);
  assert(!existsSync(cliMarker));
  assert.equal(children().length, 0);
  assert.throws(() => process.kill(coreFixturePID, 0), /ESRCH/);
  const coreCapture = JSON.parse(
    await readFile(join(fixture, "core-callbacks.json"), "utf8"),
  );
  assert.equal(coreCapture.ownedCoreProcesses, 0);
  assert(coreCapture.callbacks.includes("shutdown"));
  assert(coreCapture.callbacks.includes("run:storage.inspect"));
  assert(coreCapture.callbacks.includes("cancel:storage.inspect:sent"));
  assert(coreCapture.callbacks.includes("restart"));
  for (const pid of coreCapture.stoppedPIDs) {
    assert.throws(() => process.kill(pid, 0), /ESRCH/);
  }
  assert.throws(
    () => process.kill(stoppingState.processIdentifier, 0),
    /ESRCH/,
  );
  assert.equal(host.exitCode, 0, hostError);
  assert(
    !hostError.includes("is implemented in both"),
    "Duplicate runtime classes loaded",
  );
  await until(() => !existsSync(ready.socket));
  await command(["extensions", "ls"], 4);
  process.stdout.write(
    `${JSON.stringify({ fixtureScope: "synthetic transport and core behavior, not feature parity", shippingEntrypoint: true, originalOwnedAgentCallbacks: true, actualAmbientBatteryPolicy: true, originalCoreGenericTasksAndSchedules: true, exactCoreCommandBytesAndExit: true, actualCommandCallerCancellation: true, persistedCoreSchedules: true, coreMCPConfirmedExecution: true, actualCoreJournalAndRestart: true, ownedQueuedCancellation: true, unhealthyReadinessExitZero: true, reservedCoreServer: true, liveProviderCatalog: true, dynamicMCP: true, callerStdinAndDirectory: true, sdkOutputStream: true, liveStdinEOF: true, concurrentInputStreams: true, bidirectionalSyntheticFraming: true, callerPTYResizeAndRestoration: true, boundedMCPInput: true, idleMCPCancellation: true, shutdownCommandExitCode: stoppingCommand.exitCode, originalPlainVersionAndErrors: true, publicLauncher: true, sameSignedExecutable: true, install: "1.0.0", update: "1.1.0", invokeJSONAndStdin: true, scopedArchiveDecoder: true, abi2Carrier: true, syntheticProviderRouting: true, exactProviderExitCodes: true, duplicateRuntimeClasses: false, timeoutAndDisconnectCancellation: true, responsiveHost: true, forgedCallerRejected: true, boundedRequests: true, offlineError: true, disabledWorkers: 0, removedPayload: true, socketCleanup: true })}\n`,
  );
} finally {
  for (const client of clients) {
    if (client.exitCode === null) client.kill("SIGTERM");
  }
  if (host && host.exitCode === null) {
    await writeFile(join(fixture, "stop"), "stop");
    await sleep(500);
    if (host.exitCode === null) host.kill("SIGTERM");
  }
  if (identityRoot) await rm(identityRoot, { recursive: true, force: true });
  await rm(fixture, { recursive: true, force: true });
}
