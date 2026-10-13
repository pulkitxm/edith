import { test } from "bun:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import {
  lifecycleHarnessLastStage,
  lifecycleHarnessSignalFailure,
  lifecycleHarnessStages,
} from "./lifecycle-harness-diagnostics.mjs";

const pid = 512;
const source = "a".repeat(40);
const marker = (stage, changes = {}) =>
  JSON.stringify({
    lifecycleHarnessStage: stage,
    name: "HostLifecycleHarness",
    pid,
    ...changes,
  });

test("fixed native markers surround copy, signing, owners and every installer without changing operations", async () => {
  const native = await readFile(
    new URL(
      "../Packages/EdithHost/Tests/LifecycleHarness/Harness.swift",
      import.meta.url,
    ),
    "utf8",
  );
  const declared = native
    .split("private enum StartupStage: String {")[1]
    .split("}")[0]
    .match(/case ([A-Za-z]+)/g)
    .map((value) => value.slice(5));
  assert.deepEqual(declared, lifecycleHarnessStages);
  for (const [stage, operation] of [
    ["fixtureCopy", "try FileManager.default.copyItem(at: sourceApp, to: app)"],
    ["fixtureSign", "sign.waitUntilExit()"],
    ["hostIdentity", "let identity = try HostIdentity("],
    ["packageStore", "let store = ExtensionPackageStore("],
    ["peerEndpoint", "let endpoint = try ExtensionPeerEndpoint("],
    ["sessions", "let result = HostExtensionSessions("],
    ["packageInstall", "_ = try await installer.install([package],"],
  ]) {
    const begin = native.indexOf(`startupStage(.${stage}Begin)`);
    const actual = native.indexOf(operation, begin);
    const complete = native.indexOf(`startupStage(.${stage}Complete)`, actual);
    assert(begin > 0 && actual > begin && complete > actual);
  }
  assert.equal(native.match(/startupStage\(\.surfacesBegin\)/g).length, 3);
  assert.equal(native.match(/startupStage\(\.surfacesComplete\)/g).length, 3);
  assert(native.includes('"pid": getpid()'));
  assert(native.includes("FileHandle.standardError.write(bytes + Data([10]))"));
});

test("signal metadata retains only the last fixed stage from the actual failed PID", () => {
  const stderr = [
    marker("fixtureCopyBegin"),
    marker("fixtureCopyComplete"),
    "synthetic signing output",
    marker("fixtureSignBegin"),
    marker("fixtureSignComplete"),
    marker("hostIdentityBegin"),
    "",
  ].join("\n");
  const failure = lifecycleHarnessSignalFailure(
    { signal: "SIGBUS", pid, stderr: Buffer.from(stderr) },
    source,
  );
  assert.deepEqual(failure, {
    signal: "SIGBUS",
    pid,
    source,
    stage: "hostIdentityBegin",
  });
  assert(Object.isFrozen(failure));
  assert.equal(lifecycleHarnessLastStage("signing output only", pid), null);
});

test("foreign PID, name, unknown stage, fields, newline injection and invalid UTF8 cannot supply a stage", () => {
  for (const invalid of [
    marker("fixtureSignBegin", { pid: pid + 1 }),
    marker("fixtureSignBegin", { name: "OtherHarness" }),
    marker("unknown"),
    marker("fixtureSignBegin").replace('"pid":512', '"pid":513,"pid":512'),
    marker("fixtureSignBegin", { path: "/synthetic/private" }),
    marker("fixtureSignBegin\nhostIdentityComplete"),
    `${marker("fixtureSignBegin")}\n{"lifecycleHarnessStage":`,
    Buffer.concat([
      Buffer.from(marker("fixtureSignBegin")),
      Buffer.from([255]),
    ]),
  ]) {
    assert.equal(lifecycleHarnessLastStage(invalid, pid), null);
    assert.equal(
      lifecycleHarnessSignalFailure(
        { signal: "SIGBUS", pid, stderr: invalid },
        source,
      ).stage,
      null,
    );
  }
});

test("stderr, marker size and history bounds reject overflow without exposing raw output", () => {
  for (const invalid of [
    `${marker("fixtureSignBegin")}\n${"x".repeat(65536)}`,
    marker("fixtureSignBegin", { name: "x".repeat(256) }),
    Array.from({ length: 129 }, () => marker("fixtureSignBegin")).join("\n"),
  ])
    assert.equal(lifecycleHarnessLastStage(invalid, pid), null);
  assert.equal(
    lifecycleHarnessLastStage(
      Array.from({ length: 128 }, () => marker("fixtureSignBegin")).join("\n"),
      pid,
    ),
    "fixtureSignBegin",
  );
  for (const badPID of [null, 1, -1, 1.5, 2147483648])
    assert.equal(
      lifecycleHarnessLastStage(marker("fixtureSignBegin"), badPID),
      null,
    );
});

test("ordinary exits, unknown signals and malformed source never become trusted signal records", () => {
  for (const error of [
    null,
    { status: 1, pid },
    { signal: "SIGBUS\nother", pid },
    { signal: "SIGBUS", pid: 1 },
  ])
    assert.equal(lifecycleHarnessSignalFailure(error, source), null);
  for (const invalid of [undefined, "", "b".repeat(39), `${source}\n`])
    assert.equal(
      lifecycleHarnessSignalFailure({ signal: "SIGBUS", pid }, invalid).source,
      null,
    );
});

test("the invoking wrapper keeps original child options, result parser and thrown failure", async () => {
  const wrapper = await readFile(
    new URL("./test-extension-workers.mjs", import.meta.url),
    "utf8",
  );
  assert(wrapper.includes("timeout: 90_000"));
  assert(
    wrapper.includes(
      "env: workerFixtureEnvironment(fixtureHome, fixtureIdentifier)",
    ),
  );
  assert(wrapper.includes("const result = JSON.parse(harnessOutput.trim())"));
  const block = wrapper
    .split("let harnessOutput;")[1]
    .split("} catch (error) {")[1]
    .split("const result =")[0];
  assert(
    /lifecycleHarnessSignalFailure\(\s*error,\s*process\.env\.GITHUB_SHA,?\s*\)/.test(
      block,
    ),
  );
  assert(block.includes("process.stderr.write"));
  assert(block.includes("throw error;"));
  assert(!wrapper.includes("DiagnosticReports"));
});
