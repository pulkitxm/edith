import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { copyFile, mkdir, mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { buildExtensionPackage } from "./build-extension-package.mjs";

const root = await mkdtemp(join(tmpdir(), "extension-worker-fixture-"));
try {
  const definitions = JSON.parse(
    await readFile("Extensions/manifest.json", "utf8"),
  );
  const retainPackages = process.argv.includes("--retain-packages");
  const requested = process.argv
    .slice(2)
    .filter((value) => value !== "--retain-packages");
  const workers = definitions.filter((entry) => entry.contractVersion === 1);
  for (const id of requested)
    assert(
      workers.some((entry) => entry.id === id),
      `Unknown worker extension ${id}`,
    );
  for (const { id, surfaceContractVersion } of workers.filter(
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
    const fixtureHome = join(root, `${id}-home`);
    await mkdir(fixtureHome);
    const result = JSON.parse(
      execFileSync(
        resolve("Packages/EdithHost/.build/debug/HostLifecycleHarness"),
        [
          join(root, `${id}-host`),
          resolve("local/minimal-host/Edith.app"),
          releases,
          id,
          surfaceContractVersion === 1 ? "1" : "0",
        ],
        {
          encoding: "utf8",
          timeout: 90_000,
          env: {
            ...process.env,
            EDITH_EXTENSION_FIXTURE_HOME: fixtureHome,
          },
        },
      ).trim(),
    );
    for (const key of [
      "downloadedBundle",
      "nativeWindow",
      "updateWithoutAppRestart",
      "restoreAfterAppUpdate",
      "freshHostSessionRestored",
      "removedPayloads",
      "isolatedSupportTypes",
      "surfaceLayoutRestored",
    ])
      assert.equal(result[key], true);
    assert.equal(result.disabledProcesses, 0);
    assert.equal(result.surfaceDataValidated, surfaceContractVersion === 1);
    assert.equal(result.clipboardDataValidated, id === "clipboard");
    assert.equal(result.latexDataValidated, id === "latex");
    assert.equal(result.companionDataValidated, id === "companion");
    assert.equal(result.terminalDataValidated, id === "terminal");
    assert.equal(result.studioDataValidated, id === "studio");
    assert.equal(result.audioMixerDataValidated, id === "audioMixer");
    assert.equal(result.usageDataValidated, id === "usage");
    if (id === "lidAwake") {
      const privileged = JSON.parse(execFileSync(
        "python3",
        ["scripts/test-privileged-extension-worker.py", "--app", resolve("local/minimal-host/Edith.app"),
          "--package", join(releases, "1.0.0", `${id}.zip`)],
        { encoding: "utf8", timeout: 60_000 },
      ).trim());
      for (const key of ["signedPayload", "sameExecutable", "isolatedPrivilegedWorkers", "restoredBeforeExit", "connectionLossExited"])
        assert.equal(privileged[key], true);
      assert.equal(privileged.disabledProcesses, 0);
      assert.equal(privileged.productionSystemEffects, 0);
      result.privilegedRuntimeValidated = true;
    }
    if (retainPackages) {
      const output = resolve("dist/extensions");
      await mkdir(output, { recursive: true });
      for (const suffix of ["zip", "json", "zip.sha256"])
        await copyFile(
          join(releases, "1.0.0", `${id}.${suffix}`),
          join(output, `${id}.${suffix}`),
        );
    }
    process.stdout.write(`${JSON.stringify({ id, ...result })}\n`);
  }
} finally {
  await rm(root, { recursive: true, force: true });
}
