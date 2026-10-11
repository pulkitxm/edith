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
  sparkleEntryOverlay,
  sparkleUpdaterOverlay,
} from "./source-overlay.mjs";

export function requireCleanSparkleSources(execute = execFileSync) {
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
      { encoding: "utf8" },
    ),
    "",
    "Reviewed fixture inputs must be committed and unchanged before compilation",
  );
}

export async function buildSparkleHost({
  sourceCommit,
  issuerPublicKey,
  signingRequirement,
  execute = execFileSync,
}) {
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
  const output = resolve("local/hosted-sparkle-update");
  const packageDirectory = join(output, "HostPackage");
  for (const path of [join(root, "local"), output, packageDirectory]) {
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
  execute(process.execPath, [builderPath], {
    stdio: "inherit",
    env: { ...process.env, EXTENSION_SWIFT_JOBS: "1" },
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
