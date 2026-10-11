import assert from "node:assert/strict";
import { lstat, realpath } from "node:fs/promises";
import { join, resolve } from "node:path";

const dependencies = [
  ["../ExtensionMarketplace", "Packages/ExtensionMarketplace"],
  ["../ExtensionSupport", "Packages/ExtensionSupport"],
  ["../../Extensions/fixtureSupport", "Extensions/fixtureSupport"],
];

async function ownedDirectory(path) {
  const info = await lstat(path);
  assert(info.isDirectory());
  assert.equal(info.uid, process.getuid());
  assert.equal(info.mode & 0o022, 0);
  assert.equal(await realpath(path), path);
}

export async function relocateHostedHostManifest(manifest, root) {
  assert.equal(typeof manifest, "string");
  assert(manifest.length > 0 && Buffer.byteLength(manifest) <= 131_072);
  assert.equal(resolve(root), root);
  await ownedDirectory(root);
  assert.equal(
    (manifest.match(/\.package\s*\(\s*path\s*:/g) ?? []).length,
    dependencies.length,
  );
  for (const [original, relative] of dependencies) {
    const anchor = `.package(path: ${JSON.stringify(original)})`;
    assert.equal(manifest.split(anchor).length, 2);
    let path = root;
    for (const component of relative.split("/")) {
      path = join(path, component);
      await ownedDirectory(path);
    }
    const packageFile = join(path, "Package.swift");
    const info = await lstat(packageFile);
    assert(info.isFile() && info.nlink === 1);
    assert.equal(info.uid, process.getuid());
    assert.equal(info.mode & 0o022, 0);
    assert.equal(await realpath(packageFile), packageFile);
    manifest = manifest.replace(
      anchor,
      `.package(path: ${JSON.stringify(path)})`,
    );
  }
  return manifest;
}
