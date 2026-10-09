import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdir, mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { buildExtensionPackage } from "./build-extension-package.mjs";

const root = await mkdtemp(join(tmpdir(), "extension-worker-fixture-"));
try {
  const releases = join(root, "releases");
  await mkdir(releases);
  for (const version of ["1.0.0", "1.1.0"]) {
    await buildExtensionPackage({
      id: "keepAwake",
      output: join(releases, version),
      development: true,
      version,
    });
  }
  const result = JSON.parse(
    execFileSync(
      resolve("Packages/EdithHost/.build/debug/HostLifecycleHarness"),
      [root, resolve("local/minimal-host/Edith.app"), releases],
      { encoding: "utf8", timeout: 90_000 },
    ).trim(),
  );
  for (const key of [
    "downloadedBundle",
    "nativeWindow",
    "updateWithoutAppRestart",
    "restoreAfterAppUpdate",
    "removedPayloads",
  ])
    assert.equal(result[key], true);
  assert.equal(result.disabledProcesses, 0);
  process.stdout.write(`${JSON.stringify(result)}\n`);
} finally {
  await rm(root, { recursive: true, force: true });
}
