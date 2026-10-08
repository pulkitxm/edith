import { createHash } from "node:crypto";
import { readdir, readFile, writeFile } from "node:fs/promises";
import { resolve } from "node:path";

export async function hostABI(root = process.cwd()) {
  const files = [];
  async function visit(path) {
    for (const entry of await readdir(resolve(root, path), {
      withFileTypes: true,
    })) {
      const child = `${path}/${entry.name}`;
      if (entry.isDirectory()) await visit(child);
      else if (
        entry.name.endsWith(".swift") &&
        entry.name !== "MarketplaceConfiguration.swift"
      )
        files.push(child);
    }
  }
  for (const module of [
    "EdithCore",
    "EdithKit",
    "EdithShared",
    "EdithCameraSupport",
    "EdithLidAwakeSupport",
  ])
    await visit(`Packages/Edith/Sources/${module}`);
  await visit("Packages/ExtensionMarketplace/Sources/ExtensionMarketplace");
  files.push(
    "Packages/Edith/Package.swift",
    "scripts/link-shared-framework.py",
    "scripts/extension-host-build.mjs",
  );
  const hash = createHash("sha256");
  for (const file of files.sort()) {
    const bytes = await readFile(resolve(root, file));
    hash.update(`${file}\0${bytes.length}\0`).update(bytes);
  }
  return `host-${hash.digest("hex").slice(0, 24)}`;
}

if (import.meta.main) {
  const abi = await hostABI();
  const configuration =
    "Packages/ExtensionMarketplace/Sources/ExtensionMarketplace/MarketplaceConfiguration.swift";
  const source = await readFile(configuration, "utf8");
  const manifestPath = "Extensions/manifest.json";
  const manifest = JSON.parse(await readFile(manifestPath, "utf8"));
  if (process.argv.includes("--write")) {
    await writeFile(
      configuration,
      source.replace(
        /public static let hostABI = "[^"]+"/,
        `public static let hostABI = "${abi}"`,
      ),
    );
    for (const entry of manifest) entry.hostABI = abi;
    await writeFile(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`);
  } else if (
    !source.includes(`public static let hostABI = "${abi}"`) ||
    manifest.some((entry) => entry.hostABI !== abi)
  ) {
    throw new Error(
      "Host contract changed. Run bun scripts/extension-host-abi.mjs --write before committing.",
    );
  }
  process.stdout.write(`${abi}\n`);
}
