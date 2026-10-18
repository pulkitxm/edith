import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdir, writeFile } from "node:fs/promises";
import { join, resolve } from "node:path";
import { relocateHostedHostManifest } from "./hosted-host-manifest.mjs";
import {
  reviewed,
  source,
  withRepository,
} from "./hosted-host-manifest-fixture.mjs";

assert.equal(process.platform, "darwin");
assert.equal(process.argv.length, 2);
await withRepository(async (root) => {
  const declarations = source.match(/\.package\(path: "[^"]+"\)/g);
  assert.equal(declarations.length, 3);
  const manifest = `// swift-tools-version:6.0\nimport PackageDescription\nlet package = Package(name: "RelocatedHost", dependencies: [${declarations.join(",")}])\n`;
  const host = join(root, "local/hosted-original-shell/HostPackage");
  await mkdir(host, { recursive: true, mode: 0o700 });
  const describe = () =>
    execFileSync(
      "/usr/bin/xcrun",
      [
        "swift",
        "package",
        "--package-path",
        host,
        "--jobs",
        "1",
        "show-dependencies",
        "--format",
        "json",
      ],
      { timeout: 60_000, maxBuffer: 262_144, stdio: "pipe" },
    );
  let incomplete = manifest;
  for (const [original, path] of reviewed.slice(0, 2))
    incomplete = incomplete.replace(
      `.package(path: ${JSON.stringify(original)})`,
      `.package(path: ${JSON.stringify(join(root, path))})`,
    );
  await writeFile(join(host, "Package.swift"), incomplete, { mode: 0o600 });
  let rejected;
  try {
    describe();
  } catch (error) {
    rejected = error;
  }
  assert.equal(rejected?.status, 1);
  assert(
    rejected?.stderr
      .toString()
      .includes(join(root, "local/Extensions/fixtureSupport")),
  );
  await writeFile(
    join(host, "Package.swift"),
    await relocateHostedHostManifest(manifest, root),
  );
  const graph = JSON.parse(describe());
  assert.deepEqual(
    graph.dependencies.map(({ path }) => resolve(path)).sort(),
    reviewed.map(([, path]) => join(root, path)).sort(),
  );
  assert(
    graph.dependencies.every(({ dependencies }) => dependencies.length === 0),
  );
});
console.log(
  JSON.stringify({
    schema: 1,
    category: "hosted-host-dependency-relocation-validated",
    reviewedLocalDependencies: 3,
    priorOmissionRejected: true,
    coldSwiftGraphValidated: true,
    productExecuted: false,
    networkDependencies: 0,
  }),
);
