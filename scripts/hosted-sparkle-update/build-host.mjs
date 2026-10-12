import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import {
  cp,
  lstat,
  mkdir,
  readFile,
  realpath,
  rm,
  writeFile,
} from "node:fs/promises";
import { join, resolve } from "node:path";
import { pathToFileURL } from "node:url";
import { relocateHostedHostManifest } from "../hosted-host-manifest.mjs";
import {
  fixtureNavigationOverlay,
  fixturePermissionOverlay,
  fixturePresenterOverlay,
  originalShellFixtureOverlay,
} from "../hosted-original-shell/source-overlay.mjs";
import {
  readSparkleImplementation,
  sparkleChildEnvironment,
  sparkleExecutableIdentity,
  verifySparkleImplementationCopy,
} from "./implementations.mjs";
import {
  sparkleEntryOverlay,
  sparkleUpdaterOverlay,
} from "./source-overlay.mjs";

export function requireCleanSparkleSources(
  execute = execFileSync,
  environment,
) {
  assert.equal(
    execute(
      "git",
      [
        "status",
        "--porcelain",
        "--untracked-files=all",
        "--",
        "Packages",
        "Extensions",
        "scripts",
        "Tests",
      ],
      { encoding: "utf8", env: environment },
    ),
    "",
    "Reviewed fixture inputs must be committed and unchanged before compilation",
  );
}

export async function compileSparkleImplementation({
  packageDirectory,
  implementation,
  sourceCommit,
  builderPath,
  environment,
  execute = execFileSync,
}) {
  const childEnvironment = sparkleChildEnvironment(environment);
  const verify = async () => {
    requireCleanSparkleSources(execute, childEnvironment);
    assert.equal(
      execute("git", ["rev-parse", "HEAD"], {
        encoding: "utf8",
        env: childEnvironment,
      }).trim(),
      sourceCommit,
    );
    await verifySparkleImplementationCopy(packageDirectory, implementation);
  };
  await verify();
  execute(process.execPath, [builderPath], {
    stdio: "inherit",
    env: { ...childEnvironment, EXTENSION_SWIFT_JOBS: "1" },
  });
  await verify();
}

export async function buildSparkleHost({
  sourceCommit,
  issuerPublicKey,
  signingRequirement,
  generation,
  environment,
  execute = execFileSync,
}) {
  const childEnvironment = sparkleChildEnvironment(environment);
  const childExecute = execute;
  execute = (command, arguments_, options = {}) =>
    childExecute(command, arguments_, { ...options, env: childEnvironment });
  requireCleanSparkleSources(execute);
  const root = await realpath(process.cwd());
  assert(
    typeof sourceCommit === "string" &&
      sourceCommit.length === 40 &&
      /^[a-f0-9]{40}$/.test(sourceCommit),
  );
  assert.equal(
    execute("git", ["rev-parse", "HEAD"], { encoding: "utf8" }).trim(),
    sourceCommit,
  );
  const implementation = readSparkleImplementation(
    generation,
    sourceCommit,
    execute,
  );
  const sharedOutput = resolve("local/hosted-sparkle-update");
  const output = join(sharedOutput, generation);
  const packageDirectory = join(output, "HostPackage");
  for (const path of [
    join(root, "local"),
    sharedOutput,
    output,
    packageDirectory,
  ]) {
    await mkdir(path, { recursive: false, mode: 0o700 }).catch((error) => {
      assert.equal(error.code, "EEXIST");
    });
    const info = await lstat(path);
    assert(
      info.isDirectory() &&
        !info.isSymbolicLink() &&
        info.uid === process.getuid() &&
        (info.mode & 0o022) === 0,
    );
    assert.equal(await realpath(path), path);
  }
  const committed = (path) =>
    execute("git", ["show", `HEAD:${path}`], { encoding: "utf8" });
  const readPinned = async (path) => {
    const source = await readFile(path, "utf8");
    assert.equal(
      source,
      committed(path),
      "Fixture input differs from the declared source commit",
    );
    return source;
  };
  for (const name of ["Sources", "Tests"]) {
    await rm(join(packageDirectory, name), { recursive: true, force: true });
    await cp(join("Packages/EdithHost", name), join(packageDirectory, name), {
      recursive: true,
    });
  }
  await writeFile(
    join(packageDirectory, "Package.swift"),
    await relocateHostedHostManifest(
      await readPinned("Packages/EdithHost/Package.swift"),
      root,
    ),
  );
  for (const [path, bytes] of Object.entries(implementation.sources)) {
    await writeFile(
      join(packageDirectory, path.slice("Packages/EdithHost/".length)),
      bytes,
    );
  }
  const sources = join(packageDirectory, "Sources/EdithHost");
  const hash = (data) => createHash("sha256").update(data).digest("hex");
  const overlays = {};
  const pins = { sourceCommit, issuerPublicKey, signingRequirement };
  for (const [name, transform] of [
    ["HostApplication.swift", originalShellFixtureOverlay],
    ["HostWorkspace.swift", fixtureNavigationOverlay],
    ["HostPermissions.swift", fixturePermissionOverlay],
    ["HostRemoteContentPresenter.swift", fixturePresenterOverlay],
    ["HostEntry.swift", (source) => sparkleEntryOverlay(source, pins)],
    ["HostUpdater.swift", sparkleUpdaterOverlay],
  ]) {
    const path = join(sources, name);
    const original = await readFile(path, "utf8");
    assert.equal(
      original,
      execute(
        "git",
        ["show", `HEAD:Packages/EdithHost/Sources/EdithHost/${name}`],
        { encoding: "utf8" },
      ),
    );
    const transformed = transform(original);
    await writeFile(path, transformed);
    overlays[name] = {
      originalSHA256: hash(original),
      fixtureSHA256: hash(transformed),
    };
  }
  const additions = {};
  for (const path of [
    "Tests/HostedOriginalShell/FixtureSources/HostGUIFixture.swift",
    "Tests/HostedOriginalShell/FixtureSources/HostGUIJourneyServices.swift",
    "Tests/HostedOriginalShell/Sources/JourneyContract/JourneyContract.swift",
    "Tests/HostedOriginalShell/Sources/JourneyContract/JourneyPackageDirectory.swift",
    "Tests/HostedSparkleUpdate/Sources/SparkleFixtureContract/SparkleFixtureContract.swift",
    "Tests/HostedSparkleUpdate/FixtureSources/HostSparkleBootstrap.swift",
  ]) {
    const name = path.split("/").at(-1);
    const source = await readPinned(path);
    await writeFile(join(sources, name), source);
    additions[path] = hash(source);
  }
  let builder = await readPinned("scripts/build-minimal-host.mjs");
  for (const [before, after] of [
    [
      '"./build-extension-ui-carrier.mjs"',
      JSON.stringify(
        pathToFileURL(resolve("scripts/build-extension-ui-carrier.mjs")).href,
      ),
    ],
    ['resolve(root, "Packages/EdithHost")', JSON.stringify(packageDirectory)],
    [
      'resolve(root, "local/minimal-host/Edith.app")',
      JSON.stringify(join(output, "frozen/Edith.app")),
    ],
    [
      '  "--product",\n',
      '  "-Xswiftc",\n  "-DEDITH_GUI_FIXTURE",\n  "-Xswiftc",\n  "-DEDITH_HOSTED_SPARKLE_FIXTURE",\n  "--product",\n',
    ],
  ]) {
    assert.equal(builder.split(before).length, 2);
    builder = builder.replace(before, after);
  }
  const builderPath = join(output, "build-host.mjs");
  await writeFile(builderPath, builder);
  await compileSparkleImplementation({
    packageDirectory,
    implementation,
    sourceCommit,
    builderPath,
    environment,
    execute: childExecute,
  });
  const receipt = {
    schema: 1,
    sourceCommit,
    frozenHost: join(output, "frozen/Edith.app"),
    fixtureExecutableSHA256: hash(
      await readFile(join(output, "frozen/Edith.app/Contents/MacOS/Edith")),
    ),
    overlays,
    additions,
    issuerPublicKey,
    implementation: {
      sourceCommit: implementation.sourceCommit,
      sources: implementation.metadata,
      normalizedUnsignedSHA256: sparkleExecutableIdentity(
        root,
        join(output, "frozen/Edith.app"),
        environment,
        execute,
      ).normalizedUnsignedSHA256,
    },
    signingRequirementSHA256: hash(signingRequirement),
    productionExecutableUnchangedProof: false,
    actualSparkleInstallValidated: false,
  };
  await writeFile(
    join(output, "build-receipt.json"),
    JSON.stringify(receipt, null, 2),
    { mode: 0o600 },
  );
  return receipt;
}
