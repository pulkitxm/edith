import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { cp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { join, resolve } from "node:path";
import { pathToFileURL } from "node:url";
import { extensionFingerprint } from "../extension-release-plan.mjs";
import { loadManagedViewReview } from "./contract.mjs";
import {
  managedContextOverlay,
  managedFixtureOverlay,
} from "./source-overlay.mjs";

assert.deepEqual(process.argv.slice(2), ["--build-only"]);
const root = resolve(process.cwd());
await loadManagedViewReview(root);
const definitions = JSON.parse(
  await readFile(join(root, "Extensions/manifest.json"), "utf8"),
);
const fingerprints = {};
for (const id of ["plugins", "studio"])
  fingerprints[id] = await extensionFingerprint(
    root,
    definitions.find((item) => item.id === id),
    definitions,
  );
const sourceCommit = execFileSync("git", ["rev-parse", "HEAD"], {
  encoding: "utf8",
}).trim();
assert.match(sourceCommit, /^[a-f0-9]{40}$/);
const output = join(root, "local/hosted-managed-views");
const packageDirectory = join(output, "HostPackage");
await mkdir(packageDirectory, { recursive: true });
for (const directory of ["Sources", "Tests"]) {
  await rm(join(packageDirectory, directory), { recursive: true, force: true });
  await cp(
    join(root, "Packages/EdithHost", directory),
    join(packageDirectory, directory),
    { recursive: true },
  );
}
let manifest = await readFile(
  join(root, "Packages/EdithHost/Package.swift"),
  "utf8",
);
for (const dependency of ["ExtensionMarketplace", "ExtensionSupport"]) {
  const anchor = `.package(path: "../${dependency}")`;
  assert.equal(manifest.split(anchor).length, 2);
  manifest = manifest.replace(
    anchor,
    `.package(path: ${JSON.stringify(join(root, "Packages", dependency))})`,
  );
}
await writeFile(join(packageDirectory, "Package.swift"), manifest);
const sources = join(packageDirectory, "Sources/EdithHost");
const digest = (bytes) => createHash("sha256").update(bytes).digest("hex");
const overlays = {};
for (const [name, transform] of [
  ["HostRemoteFixture.swift", managedFixtureOverlay],
  [
    "HostRemoteApplication.swift",
    (source) => managedContextOverlay(source, sourceCommit, fingerprints),
  ],
]) {
  const path = join(sources, name);
  const original = await readFile(path, "utf8");
  const changed = transform(original);
  await writeFile(path, changed);
  overlays[name] = {
    originalSHA256: digest(original),
    fixtureSHA256: digest(changed),
  };
}
const additions = {};
for (const [name, source] of [
  [
    "WorkerLifecycleFixture.swift",
    "Packages/EdithHost/Tests/LifecycleHarness/WorkerLifecycleFixture.swift",
  ],
  [
    "HostedManagedViewRoute.swift",
    "Tests/HostedManagedViews/Sources/ManagedViewContract/HostedManagedViewRoute.swift",
  ],
  [
    "HostedManagedViewRoute+Package.swift",
    "Tests/HostedManagedViews/FixtureSources/HostedManagedViewRoute+Package.swift",
  ],
]) {
  const bytes = await readFile(join(root, source));
  await writeFile(join(sources, name), bytes);
  additions[name] = { source, sha256: digest(bytes) };
}
let builder = await readFile(
  join(root, "scripts/build-minimal-host.mjs"),
  "utf8",
);
for (const [before, after] of [
  [
    '"./build-extension-ui-carrier.mjs"',
    JSON.stringify(
      pathToFileURL(join(root, "scripts/build-extension-ui-carrier.mjs")).href,
    ),
  ],
  ['resolve(root, "Packages/EdithHost")', JSON.stringify(packageDirectory)],
  [
    'resolve(root, "local/minimal-host/Edith.app")',
    JSON.stringify(join(output, "frozen/Edith.app")),
  ],
  [
    '  "--product",\n',
    '  "-Xswiftc",\n  "-DEDITH_CLI_FIXTURE",\n  "--product",\n',
  ],
]) {
  assert.equal(builder.split(before).length, 2);
  builder = builder.replace(before, after);
}
const builderPath = join(output, "build-host.mjs");
await writeFile(builderPath, builder);
execFileSync(process.execPath, [builderPath], {
  stdio: "inherit",
  env: { ...process.env, EXTENSION_SWIFT_JOBS: "1" },
});
const app = join(output, "frozen/Edith.app");
await writeFile(
  join(output, "host-build-receipt.json"),
  JSON.stringify(
    {
      schema: 1,
      sourceCommit,
      app,
      executableSHA256: digest(
        await readFile(join(app, "Contents/MacOS/Edith")),
      ),
      overlays,
      additions,
      fingerprints,
      productionExecutableUnchangedProof: false,
      qualification:
        "Test-only synthetic managed scene context and current closed engine fixture issuer",
    },
    null,
    2,
  ),
);
