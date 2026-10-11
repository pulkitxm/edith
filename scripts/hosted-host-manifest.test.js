import { expect, test } from "bun:test";
import { execFileSync } from "node:child_process";
import {
  chmod,
  mkdir,
  mkdtemp,
  readFile,
  realpath,
  rm,
  symlink,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { relocateHostedHostManifest } from "./hosted-host-manifest.mjs";

const reviewed = [
  ["../ExtensionMarketplace", "Packages/ExtensionMarketplace"],
  ["../ExtensionSupport", "Packages/ExtensionSupport"],
  ["../../Extensions/fixtureSupport", "Extensions/fixtureSupport"],
];
const source = await readFile("Packages/EdithHost/Package.swift", "utf8");

async function withRepository(operation) {
  const root = await realpath(
    await mkdtemp(join(tmpdir(), "host-manifest-fixture-")),
  );
  try {
    await chmod(root, 0o700);
    for (const [, path] of reviewed) {
      const name = path.split("/").at(-1);
      const module = `${name}Fixture`;
      await mkdir(join(root, path), { recursive: true, mode: 0o700 });
      await mkdir(join(root, path, "Sources", module), {
        recursive: true,
        mode: 0o700,
      });
      await writeFile(
        join(root, path, "Sources", module, "Fixture.swift"),
        "public enum Fixture {}\n",
        { mode: 0o600 },
      );
      await writeFile(
        join(root, path, "Package.swift"),
        `// swift-tools-version:6.0\nimport PackageDescription\nlet package = Package(name: ${JSON.stringify(name)}, products: [.library(name: ${JSON.stringify(module)}, targets: [${JSON.stringify(module)}])], targets: [.target(name: ${JSON.stringify(module)})])\n`,
        { mode: 0o600 },
      );
    }
    await operation(root);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
}

test("relocation preserves the Host graph while rebasing every reviewed local dependency", async () => {
  await withRepository(async (root) => {
    let expected = source;
    for (const [original, path] of reviewed)
      expected = expected.replace(
        `.package(path: ${JSON.stringify(original)})`,
        `.package(path: ${JSON.stringify(join(root, path))})`,
      );
    expect(await relocateHostedHostManifest(source, root)).toBe(expected);
    expect(expected).toContain(
      '.product(name: "WorkerFixtureSupport", package: "fixtureSupport")',
    );
    expect(expected).toContain(
      '.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.6")',
    );
  });
});

test("changed, missing, duplicate and additional local dependencies fail closed", async () => {
  await withRepository(async (root) => {
    const fixture = '.package(path: "../../Extensions/fixtureSupport")';
    for (const manifest of [
      source.replace(fixture, ""),
      source.replace(fixture, '.package(path: "/outside/fixtureSupport")'),
      source.replace(fixture, '.package(path: "../../Extensions/other")'),
      `${source}${fixture}`,
      `${source}.package(path: "../Unreviewed")`,
      source.replace(
        fixture,
        '.package( path: "../../Extensions/fixtureSupport")',
      ),
    ])
      await expect(
        relocateHostedHostManifest(manifest, root),
      ).rejects.toThrow();
  });
});

test("unowned path forms, writable directories and symlinked dependencies are rejected", async () => {
  await withRepository(async (root) => {
    await expect(
      relocateHostedHostManifest(source, `${root}/..`),
    ).rejects.toThrow();
    await chmod(root, 0o777);
    await expect(relocateHostedHostManifest(source, root)).rejects.toThrow();
    await chmod(root, 0o700);
    const path = join(root, "Extensions/fixtureSupport");
    await rm(path, { recursive: true });
    await symlink(join(root, "Packages/ExtensionSupport"), path);
    await expect(relocateHostedHostManifest(source, root)).rejects.toThrow();
  });
});

test("symlinked ancestors and package manifests cannot enter the relocated graph", async () => {
  await withRepository(async (root) => {
    const extensions = join(root, "Extensions");
    await rm(extensions, { recursive: true });
    await symlink(join(root, "Packages"), extensions);
    await expect(relocateHostedHostManifest(source, root)).rejects.toThrow();
  });
  await withRepository(async (root) => {
    const path = join(root, "Extensions/fixtureSupport/Package.swift");
    await rm(path);
    await symlink(join(root, "Packages/ExtensionSupport/Package.swift"), path);
    await expect(relocateHostedHostManifest(source, root)).rejects.toThrow();
  });
});

test("a cold relocated Swift package graph resolves all reviewed dependencies without network or product execution", async () => {
  await withRepository(async (root) => {
    const declarations = source.match(/\.package\(path: "[^"]+"\)/g);
    expect(declarations).toHaveLength(3);
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
    expect(rejected?.status).toBe(1);
    expect(rejected?.stderr.toString()).toContain(
      join(root, "local/Extensions/fixtureSupport"),
    );
    await writeFile(
      join(host, "Package.swift"),
      await relocateHostedHostManifest(manifest, root),
    );
    const graph = JSON.parse(describe());
    expect(graph.dependencies.map(({ path }) => resolve(path)).sort()).toEqual(
      reviewed.map(([, path]) => join(root, path)).sort(),
    );
    expect(
      graph.dependencies.every(({ dependencies }) => dependencies.length === 0),
    ).toBe(true);
  });
}, 90_000);
