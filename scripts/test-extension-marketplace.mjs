import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { buildExtensionPackage } from "./build-extension-package.mjs";

const root = await mkdtemp(join(tmpdir(), "extension-lifecycle-"));
try {
  const records = [];
  const downloads = {};
  for (const version of ["1.0.0", "1.1.0"]) {
    const output = join(root, version);
    const record = await buildExtensionPackage({
      id: "keepAwake",
      output,
      development: true,
      version,
      tagOverride: `extensions/fixtures/keepAwake/${version}`,
    });
    records.push(record);
    downloads[record.downloadURL] = join(output, "keepAwake.zip");
  }
  const privateKey = join(root, "key");
  const publicKey = execFileSync(
    "swift",
    ["scripts/extension-catalog-sign.swift", "generate-key", privateKey],
    { encoding: "utf8" },
  ).trim();
  const environment = {
    ...process.env,
    EXTENSION_CATALOG_PRIVATE_KEY: (await readFile(privateKey, "utf8")).trim(),
    EXTENSION_FIXTURE_DOWNLOADS: join(root, "downloads.json"),
  };
  await writeFile(
    environment.EXTENSION_FIXTURE_DOWNLOADS,
    JSON.stringify(downloads),
  );
  const catalogs = [];
  for (const revision of [1, 2]) {
    const payload = join(root, `payload-${revision}.json`);
    const catalog = join(root, `catalog-${revision}.json`);
    await writeFile(
      payload,
      JSON.stringify({
        schemaVersion: 1,
        revision,
        packages: records.slice(0, revision),
      }),
    );
    execFileSync(
      "swift",
      ["scripts/extension-catalog-sign.swift", "sign", payload, catalog],
      { env: environment },
    );
    catalogs.push(catalog);
  }
  const binary = resolve(
    "Packages/ExtensionMarketplace/.build/debug/MarketplaceHarness",
  );
  const store = join(root, "installed");
  function run(operation, catalog) {
    const output = execFileSync(
      binary,
      [operation, store, `file://${catalog}`, publicKey],
      { env: environment, encoding: "utf8" },
    );
    return JSON.parse(output.trim().split("\n").at(-1));
  }
  const installed = run("install", catalogs[0]);
  assert.equal(installed.loadedVersion, "1.0.0");
  assert.equal(installed.activeAfterStop, false);
  const updated = run("update", catalogs[1]);
  assert.equal(updated.loadedVersion, "1.0.0");
  assert.equal(updated.installedVersion, "1.1.0");
  assert.equal(updated.restartRequired, true);
  const restarted = run("inspect", catalogs[1]);
  assert.equal(restarted.loadedVersion, "1.1.0");
  assert.equal(restarted.restartRequired, false);
  run("queue-remove", catalogs[1]);
  const removed = run("remove", catalogs[1]);
  assert.equal(removed.removed, true);
  assert.deepEqual(
    JSON.parse(await readFile(join(store, "installed.json"), "utf8")),
    [],
  );
  process.stdout.write(
    `${JSON.stringify({ install: "passed", updateInUse: "passed", restart: "passed", stop: "passed", deferredRemoval: "passed", signedUICarrier: "passed", packages: records.map(({ id, version, downloadBytes, installedBytes }) => ({ id, version, downloadBytes, installedBytes })) }, null, 2)}\n`,
  );
} finally {
  await rm(root, { recursive: true, force: true });
}
