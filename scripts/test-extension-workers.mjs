import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import {
  copyFile,
  cp,
  mkdir,
  mkdtemp,
  readFile,
  realpath,
  rm,
} from "node:fs/promises";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { buildExtensionPackage } from "./build-extension-package.mjs";
import { validateWorkerLifecycleScope } from "./extension-worker-proof.mjs";

export const inertFixtureWorkers = new Set([
  "focusDim",
  "windowSweaters",
  "micMute",
  "keystrokeHighlight",
  "presenter",
  "colorPicker",
  "systemStats",
  "emoji",
  "music",
  "plugins",
  "studio",
]);

export const supportedFixtureWorkers = new Set([
  "focusDim",
  "windowSweaters",
  "micMute",
  "keystrokeHighlight",
  "presenter",
  "colorPicker",
  "systemStats",
  "emoji",
  "music",
  "plugins",
  "studio",

  "keepAwake",
  "audioMixer",
  "homebrew",
  "calendar",
  "jev",
  "system",
  "timeLapse",
  "cleaner",
  "appMaintenance",
  "blitztree",
  "notchShelf",
  "clipboard",
  "docs",
  "latex",
  "companion",
  "terminal",
  "usage",
  "bifrost",
  "lidAwake",
  "attention",
  "machines",
  "downloads",
  "seoAudit",
  "virtualCamera",
  "codeStats",
  "herdr",
  "quinjet",
  "database",
]);

export function validateWorkerFixtureSelection(definitions, requested) {
  const workers = definitions.filter((entry) => entry.contractVersion === 1);
  const selected =
    requested.length === 0
      ? workers
      : requested.map((id) => {
          const entry = workers.find((worker) => worker.id === id);
          assert(entry, `Unknown worker extension ${id}`);
          return entry;
        });
  for (const { id } of selected)
    assert(
      supportedFixtureWorkers.has(id),
      `Worker ${id} has no admitted inert fixture on this parent; startup rejected`,
    );
  return selected;
}

export function validateWorkerFixtureProof(
  result,
  { id, surfaceContractVersion },
) {
  assert(supportedFixtureWorkers.has(id), `Unknown fixture owner ${id}`);
  assert.equal(
    result.surfaceDataValidated,
    surfaceContractVersion === 1 && id !== "music",
  );
  assert.equal(result.inertFeatureDeclineValidated, id === "music");
  assert.equal(result.studioDataValidated, false);
  assert.equal(result.studioMetadataValidated, id === "studio");
}

async function run() {
  const definitions = JSON.parse(
    await readFile("Extensions/manifest.json", "utf8"),
  );
  const requested = process.argv
    .slice(2)
    .filter(
      (value) => !["--retain-packages", "--headless-cli"].includes(value),
    );
  validateWorkerFixtureSelection(definitions, requested);
  await mkdir(resolve("local"), { recursive: true });
  const root = await realpath(
    await mkdtemp(resolve("local/extension-worker-fixture-")),
  );
  try {
    const retainPackages = process.argv.includes("--retain-packages");
    const headlessCLI = process.argv.includes("--headless-cli");
    if (headlessCLI)
      assert.deepEqual(
        requested,
        ["database"],
        "Headless CLI proof is Database-only",
      );

    const workers = definitions.filter((entry) => entry.contractVersion === 1);
    for (const id of requested)
      assert(
        workers.some((entry) => entry.id === id),
        `Unknown worker extension ${id}`,
      );
    for (const {
      id,
      surfaceContractVersion,
      systemExtensionCarrier,
    } of workers.filter(
      (entry) => requested.length === 0 || requested.includes(entry.id),
    )) {
      const releases = join(root, id);
      await mkdir(releases);
      let sourceApp = resolve("local/minimal-host/Edith.app");
      let fixtureIdentifier;
      if (id === "virtualCamera") {
        fixtureIdentifier = `com.pulkit.edith.tests.worker-${crypto.randomUUID()}`;
        sourceApp = join(root, `${id}-frozen-host`, "Edith.app");
        await cp(resolve("local/minimal-host/Edith.app"), sourceApp, {
          recursive: true,
        });
        execFileSync("/usr/libexec/PlistBuddy", [
          "-c",
          `Set :CFBundleIdentifier ${fixtureIdentifier}`,
          join(sourceApp, "Contents/Info.plist"),
        ]);
        execFileSync("codesign", ["--force", "--sign", "-", sourceApp]);
      }
      for (const version of ["1.0.0", "1.1.0"]) {
        await buildExtensionPackage({
          id,
          output: join(releases, version),
          development: true,
          version,
          containedHostApp: sourceApp,
        });
        if (id === "virtualCamera") {
          const provenance = JSON.parse(
            await readFile(
              join(releases, version, `${id}.carrier-provenance.json`),
              "utf8",
            ),
          );
          const original = createHash("sha256")
            .update(await readFile(join(sourceApp, "Contents/MacOS/Edith")))
            .digest("hex");
          assert.equal(provenance.hostIdentifier, fixtureIdentifier);
          assert.equal(provenance.version, version);
          assert.deepEqual(
            provenance.roles.map(({ role }) => role).sort(),
            systemExtensionCarrier.transport === "obs"
              ? ["cameraCarrier"]
              : ["cameraCarrier", "cameraProvider"],
          );
          for (const role of provenance.roles) {
            assert.equal(role.executableBeforeSigningSHA256, original);
            assert.match(role.executableAfterSigningSHA256, /^[0-9a-f]{64}$/);
          }
        }
      }
      if (id === "machines") {
        await buildExtensionPackage({
          id: "usage",
          output: join(releases, "usage-peer", "1.0.0"),
          development: true,
          version: "1.0.0",
        });
      }
      const fixtureRoot = join(root, `${id}-host`);
      await mkdir(fixtureRoot, { mode: 0o700 });
      const fixtureHome =
        id === "calendar" ? fixtureRoot : join(fixtureRoot, `${id}-home`);
      if (fixtureHome !== fixtureRoot)
        await mkdir(fixtureHome, { mode: 0o700 });
      const result = JSON.parse(
        execFileSync(
          resolve(
            process.env.EXTENSION_LIFECYCLE_HARNESS ??
              "Packages/EdithHost/.build/debug/HostLifecycleHarness",
          ),
          [
            join(root, `${id}-host`),
            sourceApp,
            releases,
            id,
            surfaceContractVersion === 1 ? "1" : "0",
            ...(headlessCLI ? ["--headless-cli"] : []),
          ],
          {
            encoding: "utf8",
            timeout: 90_000,
            env: {
              ...process.env,
              EDITH_EXTENSION_FIXTURE_HOME: fixtureHome,
              ...(fixtureIdentifier
                ? {
                    EDITH_EXTENSION_TEST_HOST_IDENTIFIER: fixtureIdentifier,
                  }
                : {}),
            },
          },
        ).trim(),
      );
      for (const key of [
        "downloadedBundle",
        "updateWithoutAppRestart",
        "restoreAfterAppUpdate",
        "freshHostSessionRestored",
        "pendingDisableRecoveryValidated",
        "removedPayloads",
        "isolatedSupportTypes",
        "surfaceLayoutRestored",
      ])
        assert.equal(result[key], true);
      validateWorkerLifecycleScope(result);
      assert.equal(result.headlessCLI, headlessCLI);
      assert.equal(result.headlessLifecycle, true);
      assert.equal(result.disabledProcesses, 0);
      validateWorkerFixtureProof(result, { id, surfaceContractVersion });
      assert.equal(result.clipboardDataValidated, id === "clipboard");
      assert.equal(result.latexDataValidated, id === "latex");
      assert.equal(result.companionDataValidated, id === "companion");
      assert.equal(result.terminalDataValidated, id === "terminal");

      assert.equal(result.audioMixerDataValidated, id === "audioMixer");
      assert.equal(result.usageDataValidated, id === "usage");
      assert.equal(result.usageHookLifecycleValidated, id === "usage");
      assert.equal(result.cameraDataValidated, id === "virtualCamera");
      assert.equal(result.databaseDataValidated, id === "database");
      assert.equal(result.calendarFixtureLifecycleValidated, id === "calendar");
      assert.equal(result.agentActivityValidated, id === "herdr");
      if (id === "lidAwake") {
        const privileged = JSON.parse(
          execFileSync(
            "python3",
            [
              "scripts/test-privileged-extension-worker.py",
              "--app",
              resolve("local/minimal-host/Edith.app"),
              "--package",
              join(releases, "1.0.0", `${id}.zip`),
            ],
            { encoding: "utf8", timeout: 60_000 },
          ).trim(),
        );
        for (const key of [
          "signedPayload",
          "sameExecutable",
          "isolatedPrivilegedWorkers",
          "restoredBeforeExit",
          "connectionLossExited",
        ])
          assert.equal(privileged[key], true);
        assert.equal(privileged.disabledProcesses, 0);
        assert.equal(privileged.productionSystemEffects, 0);
        result.privilegedRuntimeValidated = true;
      }
      assert.equal(result.machinesDataValidated, id === "machines");
      assert.equal(result.codeStatsDataValidated, id === "codeStats");
      if (retainPackages) {
        const output = resolve("dist/extensions");
        await mkdir(output, { recursive: true });
        for (const suffix of [
          "zip",
          "json",
          "zip.sha256",
          ...(id === "virtualCamera" ? ["carrier-provenance.json"] : []),
        ])
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
}

if (resolve(process.argv[1] ?? "") === resolve(fileURLToPath(import.meta.url)))
  await run();
