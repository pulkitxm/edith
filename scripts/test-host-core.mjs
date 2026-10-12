import assert from "node:assert/strict";
import { execFileSync, spawn } from "node:child_process";
import { existsSync } from "node:fs";
import {
  copyFile,
  cp,
  mkdir,
  mkdtemp,
  readFile,
  rm,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { setTimeout as sleep } from "node:timers/promises";

const developer =
  process.env.DEVELOPER_DIR ?? "/Applications/Xcode.app/Contents/Developer";
const run = (command, args, options = {}) =>
  execFileSync(command, args, {
    maxBuffer: 1_048_576,
    timeout: 60000,
    ...options,
  });
run(
  "swift",
  [
    "build",
    "--package-path",
    "Packages/EdithHost",
    "--build-system",
    "native",
    "--jobs",
    "1",
    "--product",
    "EdithHost",
    "-Xswiftc",
    "-D",
    "-Xswiftc",
    "EDITH_CLI_FIXTURE",
    "-Xswiftc",
    "-plugin-path",
    "-Xswiftc",
    `${developer}/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins`,
  ],
  { stdio: "inherit", timeout: 600000 },
);
const products = run(
  "swift",
  [
    "build",
    "--package-path",
    "Packages/EdithHost",
    "--build-system",
    "native",
    "--show-bin-path",
  ],
  { encoding: "utf8" },
).trim();
const fixture = await mkdtemp(join(tmpdir(), "edith-core-fixture-"));
const app = join(fixture, "Edith.app");
const binary = join(app, "Contents/MacOS/Edith");
const identifier = `com.pulkit.edith.tests.core-${crypto.randomUUID()}`;
let owner;
let corePID;
const alive = (pid) => {
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    if (error.code === "ESRCH") return false;
    throw error;
  }
};
async function until(predicate, timeout = 10000) {
  const deadline = Date.now() + timeout;
  while (!(await predicate())) {
    assert(Date.now() < deadline, "Core fixture state timed out");
    await sleep(25);
  }
}
try {
  await mkdir(join(app, "Contents/MacOS"), { recursive: true, mode: 0o700 });
  await mkdir(join(app, "Contents/Resources"), { mode: 0o700 });
  await mkdir(join(app, "Contents/Frameworks"), { mode: 0o700 });
  await copyFile(join(products, "EdithHost"), binary);
  await copyFile(
    "Packages/EdithHost/Sources/EdithHostCore/Resources/index.json",
    join(app, "Contents/Resources/index.json"),
  );
  await cp(
    join(products, "Sparkle.framework"),
    join(app, "Contents/Frameworks/Sparkle.framework"),
    {
      recursive: true,
      verbatimSymlinks: true,
    },
  );
  await writeFile(
    join(app, "Contents/Info.plist"),
    JSON.stringify({
      CFBundleIdentifier: identifier,
      CFBundleExecutable: "Edith",
      CFBundlePackageType: "APPL",
      CFBundleName: "Core Fixture",
      NSPrincipalClass: "NSApplication",
    }),
  );
  run("plutil", ["-convert", "xml1", join(app, "Contents/Info.plist")]);
  run("install_name_tool", [
    "-add_rpath",
    "@executable_path/../Frameworks",
    binary,
  ]);
  run("codesign", ["--force", "--deep", "--sign", "-", app]);
  run("codesign", ["--verify", "--deep", "--strict", app]);
  for (const mode of ["normal", "owner-exit"]) {
    const directory = join(fixture, mode);
    await mkdir(directory, { mode: 0o700 });
    owner = spawn(binary, ["--extension-core-fixture", directory, mode], {
      detached: true,
      stdio: ["ignore", "pipe", "pipe"],
    });
    let output = "";
    for (const pipe of [owner.stdout, owner.stderr])
      pipe.on("data", (data) => {
        output = (output + data.toString()).slice(-32768);
      });
    const exited = new Promise((resolveExit, reject) => {
      owner.once("error", reject);
      owner.once("exit", (code, signal) => resolveExit({ code, signal }));
    });
    await until(async () => {
      if (owner.exitCode !== null) {
        const result = existsSync(join(directory, "result.json"))
          ? await readFile(join(directory, "result.json"), "utf8")
          : "No result";
        assert.fail(
          `Core fixture stopped before readiness: ${result} ${output}`,
        );
      }
      return existsSync(join(directory, "ready.json"));
    }, 45000);
    const ready = JSON.parse(
      await readFile(join(directory, "ready.json"), "utf8"),
    );
    assert.equal(ready.privateDataBytes ?? ready.measuredBytes, 71);
    assert.equal(ready.ownerPID, owner.pid);
    assert.equal(ready.processGroup, ready.corePID);
    assert.notEqual(ready.corePID, owner.pid);
    corePID = ready.corePID;
    if (mode === "owner-exit") owner.kill("SIGKILL");
    const deadline = new AbortController();
    let outcome;
    try {
      outcome = await Promise.race([
        exited,
        sleep(45000, undefined, { signal: deadline.signal }).then(() => {
          throw new Error("Core fixture did not finish");
        }),
      ]);
    } finally {
      deadline.abort();
    }
    assert.equal(
      mode === "normal" ? outcome.code : outcome.signal,
      mode === "normal" ? 0 : "SIGKILL",
    );
    if (mode === "normal") {
      const result = JSON.parse(
        await readFile(join(directory, "result.json"), "utf8"),
      );
      for (const key of [
        "passed",
        "restartRetainedTasks",
        "stoppedProcesses",
        "concurrentStatus",
        "settingsExport",
        "settingsRestore",
        "queuedCancellation",
      ]) {
        assert.equal(result[key], true, key);
      }
    }
    await until(() => !alive(corePID));
    owner = undefined;
    corePID = undefined;
  }
  console.log(
    "HostCore: signed settings export/restore, concurrent status, queued cancellation, journal restart, normal shutdown, and owner-exit cleanup passed",
  );
} finally {
  owner?.kill("SIGKILL");
  if (owner) await until(() => !alive(owner.pid)).catch(() => {});
  if (corePID) await until(() => !alive(corePID)).catch(() => {});
  try {
    run("defaults", ["delete", identifier], { stdio: "ignore" });
  } catch {}
  await rm(fixture, { recursive: true, force: true });
}
