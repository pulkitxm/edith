import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import {
  chmod,
  mkdir,
  mkdtemp,
  readFile,
  realpath,
  rm,
  stat,
  symlink,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import {
  inertFixtureWorkers,
  parseWorkerFixtureArguments,
  supportedFixtureWorkers,
  validateCameraFixtureHost,
  validateWorkerFixtureProof,
  validateWorkerFixtureSelection,
  validateWorkerLifecycleResult,
  validatePrivilegedWorkerLifecycleResult,
  workerFixtureEnvironment,
  workerFixtureHome,
} from "./test-extension-workers.mjs";

const definitions = JSON.parse(
  await readFile("Extensions/manifest.json", "utf8"),
);
const workers = definitions.filter((entry) => entry.contractVersion === 1);

test("all39 declared workers are admitted before any fixture build", () => {
  assert.equal(workers.length, 39);
  assert.deepEqual(validateWorkerFixtureSelection(definitions, []), workers);
  for (const requested of [[], ["futureWorker"], ["music", "futureWorker"]])
    assert.throws(
      () =>
        validateWorkerFixtureSelection(
          [...definitions, { id: "futureWorker", contractVersion: 1 }],
          requested,
        ),
      /startup rejected/,
    );
  assert.throws(
    () => validateWorkerFixtureSelection(definitions, ["unknown"]),
    /Unknown worker/,
  );
});

test("all nineteen strict inert owners and conditional owners remain selectable", () => {
  assert.equal(inertFixtureWorkers.size, 19);
  for (const worker of workers)
    assert.deepEqual(validateWorkerFixtureSelection(definitions, [worker.id]), [
      worker,
    ]);
  assert.deepEqual(
    validateWorkerFixtureSelection(definitions, ["calendar", "music"]),
    ["calendar", "music"].map((id) =>
      workers.find((worker) => worker.id === id),
    ),
  );
});

test("launcher and native harness have the same fail-closed boundary", async () => {
  const source = await readFile(
    "Packages/EdithHost/Tests/LifecycleHarness/WorkerLifecycleFixture.swift",
    "utf8",
  );
  const inert = source.match(/static let inertIDs[\s\S]*?= \[([\s\S]*?)\]/)[1];
  assert.deepEqual(
    new Set([...inert.matchAll(/"([^"]+)"/g)].map((match) => match[1])),
    inertFixtureWorkers,
    parseWorkerFixtureArguments,
    validateCameraFixtureHost,
  );
  const admission = await readFile(
    "Extensions/fixtureSupport/WorkerFixtureAdmission.swift",
    "utf8",
  );
  const roleOwners = ["helperIDs", "appIDs"].flatMap((name) => {
    const owners = admission.match(
      new RegExp(String.raw`let ${name}: Set<String> = \[([\s\S]*?)\]`),
    )[1];
    return [...owners.matchAll(/"([^"]+)"/g)].map((match) => match[1]);
  });
  assert.deepEqual(new Set(roleOwners), inertFixtureWorkers);
  const appOwners = [
    ...admission
      .match(/let appIDs: Set<String> = \[([\s\S]*?)\]/)[1]
      .matchAll(/"([^"]+)"/g),
  ].map((match) => match[1]);
  const issuedAppOwners = [
    ...source
      .match(
        /let role =\s*\[([\s\S]*?)\]\.contains\(selection.extensionID\)/,
      )[1]
      .matchAll(/"([^"]+)"/g),
  ].map((match) => match[1]);
  assert.deepEqual(new Set(issuedAppOwners), new Set(appOwners));
  for (const owner of [
    "usage",
    "herdr",
    "machines",
    "attention",
    "companion",
    "codeStats",
  ])
    assert(appOwners.includes(owner));
  const supported = source.match(
    /static let supportedIDs[\s\S]*?= \[([\s\S]*?)\]/,
  )[1];
  assert.deepEqual(
    new Set([...supported.matchAll(/"([^"]+)"/g)].map((match) => match[1])),
    supportedFixtureWorkers,
  );
  const harness = await readFile(
    "Packages/EdithHost/Tests/LifecycleHarness/Harness.swift",
    "utf8",
  );
  assert(
    harness.indexOf("requireSupported(extensionID)") <
      harness.indexOf("copyItem(at: sourceApp"),
  );
});

test("inert proof never promotes unavailable features or metadata to media coverage", () => {
  const music = {
    surfaceDataValidated: false,
    inertFeatureDeclineValidated: true,
    studioDataValidated: false,
    studioMetadataValidated: false,
    notchMetadataValidated: false,
  };
  const studio = {
    surfaceDataValidated: true,
    inertFeatureDeclineValidated: false,
    studioDataValidated: false,
    studioMetadataValidated: true,
    notchMetadataValidated: false,
  };
  const notch = { ...music, notchMetadataValidated: true };
  validateWorkerFixtureProof(notch, {
    id: "notchShelf",
    surfaceContractVersion: 1,
  });
  validateWorkerFixtureProof(music, { id: "music", surfaceContractVersion: 1 });
  validateWorkerFixtureProof(studio, {
    id: "studio",
    surfaceContractVersion: 1,
  });
  for (const [id, proof, field] of [
    ["music", music, "surfaceDataValidated"],
    ["music", music, "inertFeatureDeclineValidated"],
    ["studio", studio, "studioDataValidated"],
    ["studio", studio, "studioMetadataValidated"],
    ["notchShelf", notch, "notchMetadataValidated"],
    ["notchShelf", notch, "surfaceDataValidated"],
    ["notchShelf", notch, "inertFeatureDeclineValidated"],
  ])
    assert.throws(() =>
      validateWorkerFixtureProof(
        { ...proof, [field]: !proof[field] },
        { id, surfaceContractVersion: 1 },
      ),
    );
  assert.throws(() =>
    validateWorkerFixtureProof(music, {
      id: "futureWorker",
      surfaceContractVersion: 1,
    }),
  );
});

test("native fixture homes separate the launcher home from the root and Calendar marker home", () => {
  for (const owner of workers.map(({ id }) => id)) {
    const home = workerFixtureHome("/synthetic/fixture", owner);
    assert.equal(home, join("/synthetic/fixture", `${owner}-home`));
    assert.notEqual(home, "/synthetic/fixture");
    if (owner === "calendar")
      assert.notEqual(home, "/synthetic/fixture/synthetic-data");
    const environment = workerFixtureEnvironment(home);
    assert.equal(environment.HOME, home);
    assert.equal(environment.CFFIXED_USER_HOME, home);
    assert.equal(environment.TMPDIR, join(home, "tmp"));
  }
  assert.throws(() => workerFixtureHome("relative", "calendar"));
  assert.throws(() => workerFixtureHome("/synthetic/fixture", "futureWorker"));
});

test("fixture subprocesses inherit only owned homes and closed environment", async () => {
  const home = await realpath(
    await mkdtemp(join(tmpdir(), "edith-fixture-env-")),
  );
  try {
    await mkdir(join(home, "tmp"), { mode: 0o700 });
    const identifier =
      "com.pulkit.edith.tests.worker-20000000-0000-0000-0000-000000000001";
    const old = process.env.EDITH_FIXTURE_UNRELATED_SECRET;
    process.env.EDITH_FIXTURE_UNRELATED_SECRET = "synthetic-must-not-inherit";
    try {
      const environment = workerFixtureEnvironment(home, identifier);
      const output = JSON.parse(
        execFileSync(
          process.execPath,
          [
            "-e",
            "process.stdout.write(JSON.stringify({home:process.env.HOME,fixedHome:process.env.CFFIXED_USER_HOME,tmp:process.env.TMPDIR,path:process.env.PATH,ssh:process.env.SSH_AUTH_SOCK??null,secret:process.env.EDITH_FIXTURE_UNRELATED_SECRET??null,defaults:process.env.EDITH_SHARED_DEFAULTS_SUITE??null,fixture:process.env.EDITH_EXTENSION_FIXTURE_HOME,identifier:process.env.EDITH_EXTENSION_TEST_HOST_IDENTIFIER}))",
          ],
          { encoding: "utf8", env: environment },
        ),
      );
      assert.deepEqual(output, {
        home,
        fixedHome: home,
        tmp: join(home, "tmp"),
        path: "/usr/bin:/bin:/usr/sbin:/sbin",
        ssh: null,
        secret: null,
        defaults: null,
        fixture: home,
        identifier,
      });
      const temporary = await stat(environment.TMPDIR);
      assert(temporary.isDirectory());
      assert.equal(temporary.uid, process.getuid());
      assert.equal(temporary.mode & 0o777, 0o700);
      assert.equal(environment.XDG_CONFIG_HOME, join(home, ".config"));
      assert.equal(environment.XDG_CACHE_HOME, join(home, ".cache"));
      assert.equal(
        workerFixtureEnvironment(home).EDITH_EXTENSION_TEST_HOST_IDENTIFIER,
        undefined,
      );
      assert.throws(() => workerFixtureEnvironment("relative-home"));
      assert.throws(() => workerFixtureEnvironment(home, "com.pulkit.edith"));
      assert.throws(() =>
        workerFixtureEnvironment(home, "com.pulkit.edith.tests.worker-invalid"),
      );
    } finally {
      if (old === undefined) delete process.env.EDITH_FIXTURE_UNRELATED_SECRET;
      else process.env.EDITH_FIXTURE_UNRELATED_SECRET = old;
    }
  } finally {
    await rm(home, { recursive: true, force: true });
  }
});

test("Camera tracked host arguments are exact and never select other owners", () => {
  const app = "/private/tmp/synthetic/Fixture.app";
  assert.deepEqual(
    parseWorkerFixtureArguments([
      "virtualCamera",
      "--retain-packages",
      "--camera-fixture-host",
      app,
    ]),
    {
      requested: ["virtualCamera"],
      retainPackages: true,
      headlessCLI: false,
      cameraFixtureHost: app,
    },
  );
  assert.deepEqual(parseWorkerFixtureArguments([]).requested, []);
  assert.equal(
    parseWorkerFixtureArguments(["virtualCamera"]).cameraFixtureHost,
    undefined,
  );
  assert.equal(
    parseWorkerFixtureArguments(["database", "--headless-cli"]).headlessCLI,
    true,
  );
  for (const arguments_ of [
    ["--camera-fixture-host", app],
    ["music", "--camera-fixture-host", app],
    ["virtualCamera", "music", "--camera-fixture-host", app],
    ["virtualCamera", "--camera-fixture-host"],
    ["virtualCamera", "--camera-fixture-host", "relative.app"],
    ["virtualCamera", "--camera-fixture-host", "/private/tmp/../Fixture.app"],
    [
      "virtualCamera",
      "--camera-fixture-host",
      app,
      "--camera-fixture-host",
      app,
    ],
    ["virtualCamera", "--camera-fixture-host", app, app],
    ["virtualCamera", "--retain-packages", "--retain-packages"],
    ["virtualCamera", "virtualCamera"],
    ["virtualCamera", "--unknown"],
    ["virtualCamera", "--headless-cli"],
  ])
    assert.throws(() => parseWorkerFixtureArguments(arguments_));
});

async function syntheticCameraHost(run) {
  const root = await realpath(
    await mkdtemp(join(tmpdir(), "edith-camera-host-")),
  );
  const app = join(root, "Fixture.app");
  const files = [
    "Contents/Info.plist",
    "Contents/MacOS/Edith",
    "Contents/Resources/AppIcon.icns",
    "Contents/Resources/index.json",
    "Contents/Resources/EdithHost_EdithHost.bundle/MarketplaceArtwork.lzma",
    "Contents/Frameworks/Sparkle.framework/Sparkle",
    "Contents/Extensions/ExtensionUI.appextensionpoints",
  ];
  for (const relative of files) {
    const path = join(app, relative);
    await mkdir(join(path, ".."), { recursive: true });
    await writeFile(
      path,
      relative.endsWith("index.json")
        ? JSON.stringify(workers.map(({ id }) => ({ id })))
        : "synthetic",
    );
  }
  await chmod(join(app, "Contents/MacOS/Edith"), 0o700);
  const metadata = {
    CFBundleIdentifier:
      "com.pulkit.edith.tests.worker-20000000-0000-0000-0000-000000000001",
    CFBundleExecutable: "Edith",
    CFBundlePackageType: "APPL",
  };
  const dependencies = {
    readMetadata: () => metadata,
    inspectArchitecture: () => "arm64",
    verifySignature: () => {},
  };
  try {
    await run({ root, app, metadata, dependencies });
  } finally {
    await rm(root, { recursive: true, force: true });
  }
}

test("tracked Camera host admission preserves the caller's app and identity", async () => {
  await syntheticCameraHost(async ({ app, metadata, dependencies }) => {
    const before = await readFile(join(app, "Contents/Info.plist"));
    let verified;
    const result = await validateCameraFixtureHost(app, {
      ...dependencies,
      verifySignature: (path) => {
        verified = path;
      },
    });
    assert.deepEqual(result, {
      sourceApp: app,
      fixtureIdentifier: metadata.CFBundleIdentifier,
    });
    assert.equal(verified, app);
    assert.deepEqual(await readFile(join(app, "Contents/Info.plist")), before);
  });
});

test("tracked Camera host rejects foreign identities, executables and signatures", async () => {
  await syntheticCameraHost(async ({ app, metadata, dependencies }) => {
    for (const change of [
      { CFBundleIdentifier: "com.pulkit.edith" },
      {
        CFBundleIdentifier:
          "com.pulkit.edith.tests.camera-build-20000000-0000-0000-0000-000000000001",
      },
      { CFBundleIdentifier: "com.pulkit.edith.tests.worker-invalid" },
      { CFBundleExecutable: "Other" },
      { CFBundlePackageType: "BNDL" },
    ])
      await assert.rejects(
        validateCameraFixtureHost(app, {
          ...dependencies,
          readMetadata: () => ({ ...metadata, ...change }),
        }),
      );
    await assert.rejects(
      validateCameraFixtureHost(app, {
        ...dependencies,
        inspectArchitecture: () => "x86_64",
      }),
    );
    await assert.rejects(
      validateCameraFixtureHost(app, {
        ...dependencies,
        verifySignature: () => {
          throw new Error("synthetic bad signature");
        },
      }),
    );
  });
});

test("tracked Camera host rejects missing resources, symlink trees and malformed index", async () => {
  for (const mode of [
    "root-link",
    "parent-link",
    "resource-link",
    "missing",
    "empty",
    "index",
    "not-executable",
    "index-oversize",
    "foreign-index",
  ]) {
    await syntheticCameraHost(async ({ root, app, dependencies }) => {
      let path = app;
      if (mode === "root-link") {
        path = join(root, "Alias.app");
        await symlink(app, path);
      } else if (mode === "parent-link") {
        const alias = join(root, "alias");
        await symlink(root, alias);
        path = join(alias, "Fixture.app");
      } else if (mode === "resource-link") {
        const icon = join(app, "Contents/Resources/AppIcon.icns");
        await rm(icon);
        await symlink(join(app, "Contents/Info.plist"), icon);
      } else if (mode === "missing")
        await rm(
          join(
            app,
            "Contents/Resources/EdithHost_EdithHost.bundle/MarketplaceArtwork.lzma",
          ),
        );
      else if (mode === "empty")
        await writeFile(join(app, "Contents/Resources/AppIcon.icns"), "");
      else if (mode === "index")
        await writeFile(join(app, "Contents/Resources/index.json"), "[]");
      else if (mode === "index-oversize")
        await writeFile(
          join(app, "Contents/Resources/index.json"),
          " ".repeat(131_073),
        );
      else if (mode === "foreign-index")
        await writeFile(
          join(app, "Contents/Resources/index.json"),
          JSON.stringify(
            workers.map(({ id }, index) => ({
              id: index === 0 ? "foreign" : id,
            })),
          ),
        );
      else await chmod(join(app, "Contents/MacOS/Edith"), 0o600);
      let verified = false;
      await assert.rejects(
        validateCameraFixtureHost(path, {
          ...dependencies,
          verifySignature: () => {
            verified = true;
          },
        }),
      );
      assert.equal(verified, false);
    });
  }
});

function lifecycleResult(worker, headlessCLI = false) {
  const { id, surfaceContractVersion } = worker;
  return {
    downloadedBundle: true,
    updateWithoutAppRestart: true,
    restoreAfterAppUpdate: true,
    freshHostSessionRestored: true,
    pendingDisableRecoveryValidated: true,
    removedPayloads: true,
    isolatedSupportTypes: true,
    surfaceLayoutRestored: true,
    engineLifecycleValidated: true,
    managedNativeViewValidated: false,
    nativeWindow: false,
    headlessCLI,
    headlessLifecycle: true,
    disabledProcesses: 0,
    surfaceDataValidated:
      surfaceContractVersion === 1 && !["music", "notchShelf"].includes(id),
    inertFeatureDeclineValidated: ["music", "notchShelf"].includes(id),
    notchMetadataValidated: id === "notchShelf",
    studioDataValidated: false,
    studioMetadataValidated: id === "studio",
    clipboardDataValidated: id === "clipboard",
    latexDataValidated: id === "latex",
    companionDataValidated: id === "companion",
    terminalDataValidated: id === "terminal",
    audioMixerDataValidated: id === "audioMixer",
    usageDataValidated: id === "usage",
    usageHookLifecycleValidated: id === "usage",
    cameraDataValidated: id === "virtualCamera",
    databaseDataValidated: id === "database",
    calendarFixtureLifecycleValidated: id === "calendar",
    agentActivityValidated: id === "herdr",
    machinesDataValidated: id === "machines",
    codeStatsDataValidated: id === "codeStats",
    systemCleaningValidated: id === "system",
  };
}

test("lifecycle result rejects every missing or falsified original observation for all39", () => {
  for (const worker of workers) {
    const result = lifecycleResult(worker);
    const options = { ...worker, headlessCLI: false };
    validateWorkerLifecycleResult(result, options);
    for (const [field, value] of Object.entries(result)) {
      const missing = { ...result };
      delete missing[field];
      assert.throws(
        () => validateWorkerLifecycleResult(missing, options),
        `${worker.id}: missing ${field}`,
      );
      for (const incorrect of [
        null,
        typeof value === "boolean" ? !value : 1,
        String(value),
      ])
        assert.throws(
          () =>
            validateWorkerLifecycleResult(
              { ...result, [field]: incorrect },
              options,
            ),
          `${worker.id}: falsified ${field}`,
        );
    }
  }
});

test("lifecycle result preserves Database CLI and refuses native UI promotion", () => {
  const worker = workers.find(({ id }) => id === "database");
  const options = { ...worker, headlessCLI: true };
  const result = lifecycleResult(worker, true);
  validateWorkerLifecycleResult(result, options);
  assert.throws(() =>
    validateWorkerLifecycleResult(result, { ...options, headlessCLI: false }),
  );
  for (const field of ["managedNativeViewValidated", "nativeWindow"])
    assert.throws(() =>
      validateWorkerLifecycleResult({ ...result, [field]: true }, options),
    );
  assert.throws(() =>
    validateWorkerLifecycleResult(result, { ...options, id: "futureWorker" }),
  );
});

test("privileged lifecycle rejects every dropped observation and shipping execution claim", () => {
  const result = {
    signedPayload: true,
    sameExecutable: true,
    isolatedPrivilegedWorkers: true,
    restoredBeforeExit: true,
    connectionLossExited: true,
    disabledProcesses: 0,
    productionSystemEffects: 0,
    lifecycleScope: "synthetic-restoration-callback",
    shippingPrivilegedRoleExecuted: false,
  };
  validatePrivilegedWorkerLifecycleResult(result);
  for (const [field, value] of Object.entries(result)) {
    const missing = { ...result };
    delete missing[field];
    assert.throws(
      () => validatePrivilegedWorkerLifecycleResult(missing),
      `missing ${field}`,
    );
    for (const incorrect of [
      null,
      typeof value === "boolean"
        ? !value
        : typeof value === "number"
          ? 1
          : "shipping",
    ])
      assert.throws(
        () =>
          validatePrivilegedWorkerLifecycleResult({
            ...result,
            [field]: incorrect,
          }),
        `falsified ${field}`,
      );
  }
});

test("full worker inventory rejects unselected foreign, missing and duplicate owners before selection", () => {
  const requested = ["music"];
  const tampered = [
    [...definitions, { id: "futureWorker", contractVersion: 1 }],
    definitions.filter(({ id }) => id !== "usage"),
    definitions.map((entry) =>
      entry.id === "usage" ? { ...entry, id: "futureWorker" } : entry,
    ),
    definitions.map((entry) =>
      entry.id === "usage" ? { ...entry, id: "music" } : entry,
    ),
    definitions.map((entry) =>
      entry.id === "usage" ? { ...entry, contractVersion: 2 } : entry,
    ),
    [...definitions, definitions.find(({ id }) => id === "usage")],
  ];
  for (const manifest of tampered)
    for (const selection of [[], requested])
      assert.throws(
        () => validateWorkerFixtureSelection(manifest, selection),
        /startup rejected/,
      );
  assert.deepEqual(
    validateWorkerFixtureSelection([...definitions].reverse(), requested),
    [definitions.find(({ id }) => id === "music")],
  );
});
