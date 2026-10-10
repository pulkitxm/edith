import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { createHash, generateKeyPairSync, sign } from "node:crypto";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { mergeExtensionCatalog } from "./extension-publish.mjs";

const directory = await mkdtemp(join(tmpdir(), "extension-retained-catalog-"));
const harness =
  process.env.EXTENSION_CATALOG_SELECTION_HARNESS ??
  "Packages/ExtensionMarketplace/.build/debug/MarketplaceHarness";
try {
  const definitions = JSON.parse(
    await readFile("Extensions/manifest.json", "utf8"),
  );
  assert.equal(definitions.length, 39);
  const record = (definition, generation, contract = {}) => ({
    id: definition.id,
    version: `1.0.${generation}`,
    hostABI: "edith-host-2",
    architecture: "arm64",
    minimumSystemVersion: 14,
    downloadBytes: 1,
    installedBytes: 1,
    sha256: "a".repeat(64),
    sourceFingerprint: createHash("sha256")
      .update(`${definition.id}-${generation}`)
      .digest("hex"),
    dependencies: definition.dependencies,
    downloadURL: `https://github.com/pulkitxm/edith/releases/download/synthetic/${definition.id}.zip`,
    ...contract,
  });
  let catalog = { schemaVersion: 1, revision: 0, packages: [] };
  for (let generation = 0; generation < 32; generation++) {
    catalog = mergeExtensionCatalog(
      catalog,
      definitions.map((definition) => record(definition, generation)),
      generation + 1,
    );
  }
  assert.equal(catalog.packages.length, 78);
  const { privateKey, publicKey } = generateKeyPairSync("ed25519");
  const encodedKey = Buffer.from(
    publicKey.export({ format: "jwk" }).x,
    "base64url",
  ).toString("base64");
  const path = join(directory, "catalog.json");
  const seal = async (value) => {
    const payload = Buffer.from(JSON.stringify(value));
    const envelope = {
      payload: payload.toString("base64"),
      signature: sign(null, payload, privateKey).toString("base64"),
    };
    await writeFile(path, JSON.stringify(envelope));
    return envelope;
  };
  const select = (id, abi = "edith-host-2", architecture = "arm64", os = 14) =>
    JSON.parse(
      execFileSync(
        resolve(harness),
        [
          "verify-catalog-selection",
          path,
          encodedKey,
          id,
          abi,
          architecture,
          String(os),
        ],
        { encoding: "utf8", stdio: "pipe" },
      ),
    );
  await seal(catalog);
  for (const { id } of definitions) {
    assert.equal(select(id).find((entry) => entry.id === id).version, "1.0.31");
    assert.equal(
      catalog.packages.filter((entry) => entry.id === id).at(-1).version,
      "1.0.30",
    );
  }
  const compatible = [];
  const calendar = definitions.find(({ id }) => id === "calendar");
  for (const hostABI of ["edith-host-1", "edith-host-2"]) {
    for (const architecture of ["arm64", "x86_64"]) {
      for (let generation = 0; generation < 9; generation++)
        compatible.push(
          record(calendar, generation, {
            hostABI,
            architecture,
            minimumSystemVersion: generation < 5 ? 14 : 26,
            dependencies: [],
          }),
        );
    }
  }
  catalog = mergeExtensionCatalog(
    { schemaVersion: 1, revision: 0, packages: [] },
    compatible,
    1,
  );
  const envelope = await seal(catalog);
  for (const abi of ["edith-host-1", "edith-host-2"]) {
    for (const architecture of ["arm64", "x86_64"]) {
      assert.equal(
        select("calendar", abi, architecture, 14)[0].version,
        "1.0.4",
      );
      assert.equal(
        select("calendar", abi, architecture, 26)[0].version,
        "1.0.8",
      );
    }
  }
  envelope.payload = Buffer.from(
    JSON.stringify({ ...catalog, revision: 2 }),
  ).toString("base64");
  await writeFile(path, JSON.stringify(envelope));
  const rejected = spawnSync(
    resolve(harness),
    [
      "verify-catalog-selection",
      path,
      encodedKey,
      "calendar",
      "edith-host-2",
      "arm64",
      "14",
    ],
    { stdio: "pipe" },
  );
  assert.notEqual(rejected.status, 0);
  process.stdout.write(
    `${JSON.stringify({ independentExtensions: 39, releaseGenerations: 32, retainedPackages: 78, nativeCurrentSelections: 39, nativeOSContractArchitectureSelections: 8, rollbackVersionsRetained: true, tamperedSignatureRejected: true })}\n`,
  );
} finally {
  await rm(directory, { recursive: true, force: true });
}
