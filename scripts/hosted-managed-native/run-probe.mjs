import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { randomUUID } from "node:crypto";
import {
  mkdir,
  readdir,
  readFile,
  realpath,
  writeFile,
} from "node:fs/promises";
import { homedir } from "node:os";
import { join, resolve } from "node:path";
import { validateManagedNativeProof } from "../extension-worker-proof.mjs";
import { prepareManagedShippingData } from "../managed-shipping-fixture-data.mjs";
import { prepareHostRemoteFixture } from "../prepare-host-remote-fixture.mjs";
import { configureUITestRun, writeUIProject } from "./ui-project.mjs";

assert.equal(process.env.GITHUB_ACTIONS, "true");
assert.equal(process.env.RUNNER_OS, "macOS");
assert.equal(process.env.RUNNER_ENVIRONMENT, "github-hosted");
assert.equal(process.env.EDITH_HOSTED_MANAGED_PROBE, "1");
assert.equal(process.arch, "arm64");
const root = await realpath(process.cwd());
const output = resolve("local/hosted-managed-native");
const uuid = randomUUID();
const directory = join(
  homedir(),
  "Applications",
  `Edith Remote Fixture Hosted ${uuid}`,
);
const identifier = `com.pulkit.edith.tests.remote-${uuid}`;
const derived = join(output, "DerivedData");
const ownedExecutables = new Set([
  join(
    derived,
    "Build/Products/Debug/ManagedNativeProbe-Runner.app/Contents/MacOS/ManagedNativeProbe-Runner",
  ),
]);
let result;
let failure;
try {
  const receipt = JSON.parse(
    await readFile(join(output, "build-receipt.json"), "utf8"),
  );
  const fixture = await prepareHostRemoteFixture({
    root,
    directory,
    identifier,
    extensionID: "calendar",
    sourceHost: receipt.frozenHost,
    sourceExecutable: receipt.fixtureExecutable,
  });
  const package_ = JSON.parse(
    await readFile(join(directory, "selected-package.json"), "utf8"),
  );
  await prepareManagedShippingData({ directory, identifier, package_ });
  for (const app of [fixture.app, fixture.carrier, fixture.worker])
    ownedExecutables.add(join(app, "Contents/MacOS/Edith"));
  const variables = {
    GITHUB_ACTIONS: "true",
    RUNNER_OS: "macOS",
    RUNNER_ENVIRONMENT: "github-hosted",
    EDITH_HOSTED_MANAGED_PROBE: "1",
    EDITH_HOSTED_FIXTURE_DIRECTORY: directory,
    EDITH_PROBE_ROOT: root,
    EDITH_PROBE_BUN: process.execPath,
  };
  const project = await writeUIProject(output, variables);
  const args = [
    "-project",
    project,
    "-scheme",
    "ManagedNativeProbe",
    "-destination",
    "platform=macOS,arch=arm64",
    "-derivedDataPath",
    derived,
    "-jobs",
    "1",
    "-parallel-testing-enabled",
    "NO",
  ];
  execFileSync("xcodebuild", ["build-for-testing", ...args], {
    stdio: "inherit",
    timeout: 180_000,
  });
  const products = join(derived, "Build/Products");
  const plans = (await readdir(products)).filter((entry) =>
    entry.endsWith(".xctestrun"),
  );
  assert.equal(plans.length, 1, "Ambiguous built UI test plan");
  const plan = join(products, plans[0]);
  configureUITestRun(plan, variables);
  execFileSync(
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
      join(output, "ManagedNativeProbe.xcresult"),
    ],
    { stdio: "inherit", timeout: 300_000 },
  );
  result = JSON.parse(
    await readFile(join(directory, "hosted-probe-result.json"), "utf8"),
  );
  assert.equal(result.outcome, "passed");
  assert.equal(result.hostIdentifier, identifier);
  assert.equal(result.publicBrowserApproval, true);
  assert.equal(result.publicIdentityDiscovered, true);
  assert.equal(result.managedNativeViewValidated, true);
  const proof = JSON.parse(
    await readFile(join(directory, "result-managed-shipping.json"), "utf8"),
  );
  validateManagedNativeProof(proof, package_);
  result = {
    ...result,
    sourceCommit: receipt.sourceCommit,
    fixtureExecutableSHA256: fixture.hostExecutableSHA256,
    archiveSHA256: package_.sha256,
    productionExecutableUnchangedProof: false,
  };
} catch (error) {
  failure = error;
  result = {
    outcome: "failed",
    managedNativeViewValidated: false,
    hostIdentifier: identifier,
    reason: String(error.message).slice(0, 4096),
  };
} finally {
  const processes = () =>
    execFileSync("ps", ["-axo", "pid=,command="], { encoding: "utf8" })
      .split("\n")
      .flatMap((line) => {
        const match = /^\s*(\d+)\s+(.+)$/.exec(line);
        if (!match) return [];
        for (const executable of ownedExecutables)
          if (match[2] === executable || match[2].startsWith(`${executable} `))
            return [{ pid: Number(match[1]), command: match[2] }];
        return [];
      });
  const remainingBeforeCleanup = processes();
  for (const process_ of remainingBeforeCleanup) {
    if (
      processes().some(
        (current) =>
          current.pid === process_.pid && current.command === process_.command,
      )
    ) {
      try {
        process.kill(process_.pid, "SIGTERM");
      } catch (error) {
        if (error.code !== "ESRCH") failure ??= error;
      }
    }
  }
  const deadline = Date.now() + 5000;
  while (processes().length > 0 && Date.now() < deadline)
    await new Promise((resolve_) => setTimeout(resolve_, 100));
  for (const process_ of remainingBeforeCleanup) {
    if (
      processes().some(
        (current) =>
          current.pid === process_.pid && current.command === process_.command,
      )
    ) {
      try {
        process.kill(process_.pid, "SIGKILL");
      } catch (error) {
        if (error.code !== "ESRCH") failure ??= error;
      }
    }
  }
  await new Promise((resolve_) => setTimeout(resolve_, 100));
  const remaining = processes().length;
  if (failure || remainingBeforeCleanup.length > 0 || remaining > 0) {
    failure ??= new Error("Owned processes remained after the probe");
    result = {
      ...result,
      outcome: "failed",
      managedNativeViewValidated: false,
    };
  }
  result = {
    ...result,
    remainingOwnedProcesses: remaining,
    forcedCleanupRequired: remainingBeforeCleanup.length > 0,
  };
  await mkdir(output, { recursive: true });
  await writeFile(join(output, "result.json"), JSON.stringify(result, null, 2));
  console.log(JSON.stringify(result));
}
if (failure) process.exitCode = 1;
