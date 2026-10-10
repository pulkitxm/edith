import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { cp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { join, resolve } from "node:path";
import { pathToFileURL } from "node:url";
import {
  fixtureNavigationOverlay,
  fixturePermissionOverlay,
  fixturePresenterOverlay,
  originalShellFixtureOverlay,
} from "./source-overlay.mjs";

assert.deepEqual(process.argv.slice(2), ["--build-only"]);
const output = resolve("local/hosted-original-shell");
const packageDirectory = join(output, "HostPackage");
await mkdir(output, { recursive: true });
await mkdir(packageDirectory, { recursive: true });
await rm(join(packageDirectory, "Sources"), { recursive: true, force: true });
await rm(join(packageDirectory, "Tests"), { recursive: true, force: true });
await cp("Packages/EdithHost/Sources", join(packageDirectory, "Sources"), {
  recursive: true,
});
await cp("Packages/EdithHost/Tests", join(packageDirectory, "Tests"), {
  recursive: true,
});
let manifest = await readFile("Packages/EdithHost/Package.swift", "utf8");
for (const dependency of ["ExtensionMarketplace", "ExtensionSupport"])
  manifest = manifest.replace(
    `.package(path: "../${dependency}")`,
    `.package(path: ${JSON.stringify(resolve("Packages", dependency))})`,
  );
await writeFile(join(packageDirectory, "Package.swift"), manifest);
const sources = join(packageDirectory, "Sources/EdithHost");
const sha256 = (data) => createHash("sha256").update(data).digest("hex");
const overlays = {};
for (const [name, transform] of [
  ["HostApplication.swift", originalShellFixtureOverlay],
  ["HostWorkspace.swift", fixtureNavigationOverlay],
  ["HostPermissions.swift", fixturePermissionOverlay],
  ["HostRemoteContentPresenter.swift", fixturePresenterOverlay],
]) {
  const path = join(sources, name);
  const original = await readFile(path, "utf8");
  const transformed = transform(original);
  await writeFile(path, transformed);
  overlays[name] = {
    originalSHA256: sha256(original),
    fixtureSHA256: sha256(transformed),
  };
}
for (const name of ["HostGUIFixture.swift", "HostGUIJourneyServices.swift"])
  await cp(
    join("Tests/HostedOriginalShell/FixtureSources", name),
    join(sources, name),
  );
await cp(
  "Tests/HostedOriginalShell/Sources/JourneyContract/JourneyContract.swift",
  join(sources, "JourneyContract.swift"),
);
let builder = await readFile("scripts/build-minimal-host.mjs", "utf8");
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
    '  "-Xswiftc",\n  "-DEDITH_GUI_FIXTURE",\n  "--product",\n',
  ],
]) {
  assert.equal(builder.split(before).length, 2);
  builder = builder.replace(before, after);
}
const builderPath = join(output, "build-host.mjs");
await writeFile(builderPath, builder);
execFileSync(process.execPath, [builderPath], { stdio: "inherit" });
const receipt = {
  schema: 1,
  sourceCommit: execFileSync("git", ["rev-parse", "HEAD"], {
    encoding: "utf8",
  }).trim(),
  frozenHost: join(output, "frozen/Edith.app"),
  fixtureExecutableSHA256: sha256(
    await readFile(join(output, "frozen/Edith.app/Contents/MacOS/Edith")),
  ),
  overlays,
  productionExecutableUnchangedProof: false,
  fixtureQualification:
    "Original shell and controls with isolated marketplace, workflow and permission dependencies",
};
await writeFile(
  join(output, "build-receipt.json"),
  JSON.stringify(receipt, null, 2),
);
