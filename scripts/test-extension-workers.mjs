import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdir, mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { buildExtensionPackage } from "./build-extension-package.mjs";

const root = await mkdtemp(join(tmpdir(), "extension-worker-fixture-"));
try {
  const definitions = JSON.parse(
    await readFile("Extensions/manifest.json", "utf8"),
  );
  const requested = process.argv.slice(2);
  const workers = definitions.filter((entry) => entry.contractVersion === 1);
  for (const id of requested)
    assert(
      workers.some((entry) => entry.id === id),
      `Unknown worker extension ${id}`,
    );
  for (const { id } of workers.filter(
    (entry) => requested.length === 0 || requested.includes(entry.id),
  )) {
    const releases = join(root, id);
    await mkdir(releases);
    for (const version of ["1.0.0", "1.1.0"]) {
      await buildExtensionPackage({
        id,
        output: join(releases, version),
        development: true,
        version,
      });
    }
    await mkdir(join(root, `${id}-host`));
    const result = JSON.parse(
      execFileSync(
        resolve("Packages/EdithHost/.build/debug/HostLifecycleHarness"),
        [
          join(root, `${id}-host`),
          resolve("local/minimal-host/Edith.app"),
          releases,
          id,
        ],
        { encoding: "utf8", timeout: 90_000 },
      ).trim(),
    );
    for (const key of [
      "downloadedBundle",
      "nativeWindow",
      "updateWithoutAppRestart",
      "restoreAfterAppUpdate",
      "removedPayloads",
      "isolatedSupportTypes",
    ])
      assert.equal(result[key], true);
    assert.equal(result.disabledProcesses, 0);
    process.stdout.write(`${JSON.stringify({ id, ...result })}\n`);
  }
} finally {
  await rm(root, { recursive: true, force: true });
}
