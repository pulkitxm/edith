import { expect, test } from "bun:test";
import { chmod, rm, symlink } from "node:fs/promises";
import { join } from "node:path";
import { relocateHostedHostManifest } from "./hosted-host-manifest.mjs";
import {
  reviewed,
  source,
  withRepository,
} from "./hosted-host-manifest-fixture.mjs";

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
      `${source}.package(name: "Unreviewed", path: "../Other")`,
      `${source}.package(url: "https://example.invalid/other", exact: "1.0.0")`,
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

test("noncanonical roots, writable directories and symlinked dependencies are rejected", async () => {
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
