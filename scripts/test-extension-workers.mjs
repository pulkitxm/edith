import assert from "node:assert/strict";
import { execFileSync, spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { closeSync, openSync, readFileSync } from "node:fs";
import {
  copyFile,
  cp,
  lstat,
  mkdir,
  mkdtemp,
  readFile,
  realpath,
  rm,
} from "node:fs/promises";
import { isAbsolute, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { requireRegularTree } from "./build-contained-host-runtime.mjs";
import { validateWorkerLifecycleScope } from "./extension-worker-proof.mjs";
import { lifecycleHarnessSignalFailure } from "./lifecycle-harness-diagnostics.mjs";

export const inertFixtureWorkers = new Set([
  "focusDim",
  "hinge",
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
  "notchShelf",
  "usage",
  "herdr",
  "machines",
  "attention",
  "companion",
  "codeStats",
]);

export const supportedFixtureWorkers = new Set([
  "focusDim",
  "hinge",
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
  "socialManager",
]);

export function validateWorkerFixtureSelection(definitions, requested) {
  const workers = definitions.filter((entry) => entry.contractVersion === 1);
  assert.equal(
    workers.length,
    supportedFixtureWorkers.size,
    "Worker manifest inventory startup rejected",
  );
  assert.deepEqual(
    new Set(workers.map(({ id }) => id)),
    supportedFixtureWorkers,
    "Worker manifest inventory startup rejected",
  );
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
    surfaceContractVersion === 1 && !["music", "notchShelf"].includes(id),
  );
  assert.equal(
    result.inertFeatureDeclineValidated,
    ["music", "notchShelf"].includes(id),
  );
  assert.equal(result.notchMetadataValidated, id === "notchShelf");
  assert.equal(result.studioDataValidated, false);
  assert.equal(result.studioMetadataValidated, id === "studio");
}

export function validateWorkerLifecycleResult(
  result,
  { id, surfaceContractVersion, headlessCLI },
) {
  assert(supportedFixtureWorkers.has(id), `Unknown fixture owner ${id}`);
  assert([0, 1].includes(surfaceContractVersion ?? 0));
  assert.equal(typeof headlessCLI, "boolean");
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
  assert.equal(result.machinesDataValidated, id === "machines");
  assert.equal(result.codeStatsDataValidated, id === "codeStats");
  assert.equal(result.systemCleaningValidated, id === "system");
}

export function validatePrivilegedWorkerLifecycleResult(privileged) {
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
  assert.equal(privileged.lifecycleScope, "synthetic-restoration-callback");
  assert.equal(privileged.shippingPrivilegedRoleExecuted, false);
}

export function workerFixtureHome(root, id) {
  assert.equal(resolve(root), root);
  assert(supportedFixtureWorkers.has(id));
  return join(root, `${id}-home`);
}

export function workerFixtureEnvironment(home, hostIdentifier) {
  assert.equal(resolve(home), home);
  const environment = {
    PATH: "/usr/bin:/bin:/usr/sbin:/sbin",
    HOME: home,
    CFFIXED_USER_HOME: home,
    TMPDIR: join(home, "tmp"),
    SHELL: "/bin/sh",
    LANG: "C",
    LC_ALL: "C",
    USER: "synthetic",
    LOGNAME: "synthetic",
    XDG_CONFIG_HOME: join(home, ".config"),
    XDG_CACHE_HOME: join(home, ".cache"),
    EDITH_EXTENSION_FIXTURE_HOME: home,
  };
  if (hostIdentifier !== undefined) {
    assert.match(
      hostIdentifier,
      /^com\.pulkit\.edith\.tests\.worker-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i,
    );
    environment.EDITH_EXTENSION_TEST_HOST_IDENTIFIER = hostIdentifier;
  }
  return environment;
}

export function parseWorkerFixtureArguments(arguments_) {
  const requested = [];
  const flags = new Set();
  let cameraFixtureHost;
  for (let index = 0; index < arguments_.length; index++) {
    const value = arguments_[index];
    if (
      ["--retain-packages", "--headless-cli", "--camera-fixture-host"].includes(
        value,
      )
    ) {
      assert(!flags.has(value), `Duplicate fixture option ${value}`);
      flags.add(value);
      if (value === "--camera-fixture-host") {
        cameraFixtureHost = arguments_[++index];
        assert(
          cameraFixtureHost && !cameraFixtureHost.startsWith("--"),
          "Missing Camera fixture host",
        );
        assert(
          isAbsolute(cameraFixtureHost) &&
            resolve(cameraFixtureHost) === cameraFixtureHost,
          "Camera fixture host must be an absolute canonical path",
        );
      }
    } else {
      assert(!value.startsWith("-"), `Unknown fixture option ${value}`);
      assert(!requested.includes(value), `Duplicate fixture owner ${value}`);
      requested.push(value);
    }
  }
  if (cameraFixtureHost !== undefined)
    assert.deepEqual(
      requested,
      ["virtualCamera"],
      "Camera fixture host is Camera-only",
    );
  if (flags.has("--headless-cli"))
    assert.deepEqual(
      requested,
      ["database"],
      "Headless CLI proof is Database-only",
    );
  return {
    requested,
    retainPackages: flags.has("--retain-packages"),
    headlessCLI: flags.has("--headless-cli"),
    cameraFixtureHost,
  };
}

export async function validateCameraFixtureHost(
  path,
  {
    readMetadata = (file) =>
      JSON.parse(
        execFileSync("/usr/bin/plutil", ["-convert", "json", "-o", "-", file], {
          encoding: "utf8",
          stdio: "pipe",
        }),
      ),
    inspectArchitecture = (file) =>
      execFileSync("/usr/bin/lipo", ["-archs", file], {
        encoding: "utf8",
        stdio: "pipe",
      }).trim(),
    verifySignature = (app) =>
      execFileSync(
        "/usr/bin/codesign",
        ["--verify", "--deep", "--strict", app],
        { stdio: "pipe" },
      ),
  } = {},
) {
  assert(
    isAbsolute(path) && resolve(path) === path,
    "Camera fixture host must be an absolute canonical path",
  );
  assert.equal(
    await realpath(path),
    path,
    "Camera fixture host must not traverse symlinks",
  );
  assert(
    path.endsWith(".app") && (await lstat(path)).isDirectory(),
    "Camera fixture host must be an app directory",
  );
  await requireRegularTree(path);
  const required = [
    "Contents/Info.plist",
    "Contents/MacOS/Edith",
    "Contents/Resources/AppIcon.icns",
    "Contents/Resources/index.json",
    "Contents/Resources/EdithHost_EdithHost.bundle/MarketplaceArtwork.lzma",
    "Contents/Frameworks/Sparkle.framework/Sparkle",
    "Contents/Extensions/ExtensionUI.appextensionpoints",
  ];
  for (const relative of required) {
    const entry = await lstat(join(path, relative));
    assert(
      entry.isFile() && entry.size > 0,
      `Camera fixture host is missing a regular resource ${relative}`,
    );
  }
  const executable = join(path, "Contents/MacOS/Edith");
  assert(
    (await lstat(executable)).mode & 0o111,
    "Camera fixture host executable is not executable",
  );
  assert.equal(
    await inspectArchitecture(executable),
    "arm64",
    "Camera fixture host must contain the arm64 executable",
  );
  const metadata = await readMetadata(join(path, "Contents/Info.plist"));
  assert.match(
    metadata.CFBundleIdentifier ?? "",
    /^com\.pulkit\.edith\.tests\.worker-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i,
  );
  assert.equal(metadata.CFBundleExecutable, "Edith");
  assert.equal(metadata.CFBundlePackageType, "APPL");
  assert(
    (await lstat(join(path, "Contents/Resources/index.json"))).size <=
      128 * 1_024,
    "Camera fixture host index is oversized",
  );
  const index = JSON.parse(
    await readFile(join(path, "Contents/Resources/index.json"), "utf8"),
  );
  assert(
    Array.isArray(index) &&
      index.length === 40 &&
      new Set(index.map((entry) => entry.id)).size === 40 &&
      index.some((entry) => entry.id === "virtualCamera"),
    "Camera fixture host must have the complete current extension index",
  );
  assert.deepEqual(
    new Set(index.map((entry) => entry.id)),
    supportedFixtureWorkers,
    "Camera fixture host index does not match the admitted owners",
  );
  await verifySignature(path);
  return { sourceApp: path, fixtureIdentifier: metadata.CFBundleIdentifier };
}

export function fixtureSupportScopes(definition) {
  return Object.keys(definition.roles ?? {}).flatMap((role) => {
    const product =
      definition.supportProducts &&
      Object.hasOwn(definition.supportProducts, role)
        ? definition.supportProducts[role]
        : definition.supportProduct;
    return product ? [{ product, scope: `${definition.id}_${role}` }] : [];
  });
}

export async function prepareFixtureSupport(
  definition,
  { root = process.cwd(), environment = process.env } = {},
) {
  const { buildExtensionSupport } = await import(
    "./build-extension-support.mjs"
  );
  const { prepareNativeSupport } = await import(
    "./prepare-extension-native-support.mjs"
  );
  const build = (supportRoot, product, scope) =>
    buildExtensionSupport(supportRoot, product, scope, environment);
  if (definition.nativePackage) prepareNativeSupport(root, definition, build);
  for (const { product, scope } of fixtureSupportScopes(definition))
    build(root, product, scope);
}

export function fixturePackageBuilds({ id, releases, sourceApp }) {
  return [
    ...["1.0.0", "1.1.0"].map((version) => ({
      id,
      version,
      output: join(releases, version),
      containedHostApp: sourceApp,
    })),
    ...(id === "machines"
      ? [
          {
            id: "usage",
            version: "1.0.0",
            output: join(releases, "usage-peer", "1.0.0"),
          },
        ]
      : []),
  ];
}

export function fixturePackageEnvironment(
  { version, output, containedHostApp },
  environment = process.env,
) {
  const result = {
    ...environment,
    EXTENSION_VERSION: version,
    EXTENSION_OUTPUT: output,
  };
  delete result.EXTENSION_RELEASE_TAG;
  if (containedHostApp !== undefined)
    result.EXTENSION_CONTAINING_HOST_APP = containedHostApp;
  return result;
}

export function fixturePackageRecord(log, { id, version }) {
  const lines = log.trimEnd().split("\n");
  const record = JSON.parse(lines.at(-1));
  assert.equal(record.id, id, `Fixture package ${id} reported another id`);
  assert.equal(
    record.version,
    version,
    `Fixture package ${id} ${version} reported another version`,
  );
  return { record, output: lines.slice(0, -1).join("\n") };
}

export function startFixturePackageBuild(
  build,
  {
    logDirectory,
    environment = process.env,
    command = process.execPath,
    script = fileURLToPath(
      new URL("./build-extension-package.mjs", import.meta.url),
    ),
  },
) {
  const log = join(logDirectory, `${build.id}-${build.version}-build.log`);
  const descriptor = openSync(log, "wx", 0o600);
  let child;
  try {
    child = spawn(command, [script, build.id, "--development"], {
      env: fixturePackageEnvironment(build, environment),
      stdio: ["ignore", descriptor, "inherit"],
    });
  } finally {
    closeSync(descriptor);
  }
  return new Promise((resolvePromise, reject) => {
    child.once("error", reject);
    child.once("close", (code, signal) => {
      const text = readFileSync(log, "utf8");
      if (code !== 0) {
        if (text)
          process.stdout.write(text.endsWith("\n") ? text : `${text}\n`);
        reject(
          new Error(
            `Fixture package ${build.id} ${build.version} failed (${signal ?? `exit ${code}`})`,
          ),
        );
        return;
      }
      try {
        const { record, output } = fixturePackageRecord(text, build);
        if (output) process.stdout.write(`${output}\n`);
        resolvePromise(record);
      } catch (error) {
        reject(error);
      }
    });
  });
}

export async function awaitFixturePackageBuilds(builds) {
  const results = await Promise.allSettled(builds);
  const failure = results.find(({ status }) => status === "rejected");
  if (failure) throw failure.reason;
  return results.map(({ value }) => value);
}

async function run() {
  const definitions = JSON.parse(
    await readFile("Extensions/manifest.json", "utf8"),
  );
  const { requested, retainPackages, headlessCLI, cameraFixtureHost } =
    parseWorkerFixtureArguments(process.argv.slice(2));
  const suppliedCameraHost =
    cameraFixtureHost === undefined
      ? undefined
      : await validateCameraFixtureHost(cameraFixtureHost);
  validateWorkerFixtureSelection(definitions, requested);
  await mkdir(resolve("local"), { recursive: true });
  const root = await realpath(
    await mkdtemp(resolve("local/extension-worker-fixture-")),
  );
  try {
    const workers = definitions.filter((entry) => entry.contractVersion === 1);
    for (const id of requested)
      assert(
        workers.some((entry) => entry.id === id),
        `Unknown worker extension ${id}`,
      );
    for (const definition of workers.filter(
      (entry) => requested.length === 0 || requested.includes(entry.id),
    )) {
      const { id, surfaceContractVersion, systemExtensionCarrier } = definition;
      const releases = join(root, id);
      await mkdir(releases);
      let sourceApp = resolve("local/minimal-host/Edith.app");
      let fixtureIdentifier;
      if (id === "virtualCamera" && suppliedCameraHost) {
        ({ sourceApp, fixtureIdentifier } = suppliedCameraHost);
      } else if (id === "virtualCamera") {
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
      const logDirectory = join(root, `${id}-build-logs`);
      await mkdir(logDirectory, { mode: 0o700 });
      const builds = fixturePackageBuilds({ id, releases, sourceApp });
      const independent = builds
        .filter((build) => build.id !== id)
        .map((build) => startFixturePackageBuild(build, { logDirectory }));
      try {
        await prepareFixtureSupport(definition);
      } catch (error) {
        await Promise.allSettled(independent);
        throw error;
      }
      await awaitFixturePackageBuilds([
        ...independent,
        ...builds
          .filter((build) => build.id === id)
          .map((build) => startFixturePackageBuild(build, { logDirectory })),
      ]);
      for (const version of ["1.0.0", "1.1.0"]) {
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
      const fixtureRoot = join(root, `${id}-host`);
      await mkdir(fixtureRoot, { mode: 0o700 });
      const fixtureHome = workerFixtureHome(fixtureRoot, id);
      await mkdir(fixtureHome, { mode: 0o700 });
      await mkdir(join(fixtureHome, "tmp"), { mode: 0o700 });
      let harnessOutput;
      try {
        harnessOutput = execFileSync(
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
            env: workerFixtureEnvironment(fixtureHome, fixtureIdentifier),
          },
        );
      } catch (error) {
        const failure = lifecycleHarnessSignalFailure(
          error,
          process.env.GITHUB_SHA,
        );
        if (failure)
          process.stderr.write(
            `${JSON.stringify({ lifecycleHarnessFailure: failure })}\n`,
          );
        throw error;
      }
      const result = JSON.parse(harnessOutput.trim());
      validateWorkerLifecycleResult(result, {
        id,
        surfaceContractVersion,
        headlessCLI,
      });
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
        validatePrivilegedWorkerLifecycleResult(privileged);
        result.privilegedWorkerLifetimeValidated = true;
        result.privilegedShippingPayloadValidated = true;
        result.privilegedShippingRoleExecuted = false;
      }
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
