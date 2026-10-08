import { createHash } from "node:crypto";
import { readdir, readFile, writeFile } from "node:fs/promises";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";

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
    "Packages/ExtensionMarketplace/Package.swift",
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

export async function writeHostABI(root = process.cwd()) {
  const abi = await hostABI(root);
  const configuration = resolve(
    root,
    "Packages/ExtensionMarketplace/Sources/ExtensionMarketplace/MarketplaceConfiguration.swift",
  );
  const source = await readFile(configuration, "utf8");
  const manifestPath = resolve(root, "Extensions/manifest.json");
  const manifest = JSON.parse(await readFile(manifestPath, "utf8"));
  const nextSource = source.replace(
    /public static let hostABI = "[^"]+"/,
    `public static let hostABI = "${abi}"`,
  );
  if (
    source === nextSource &&
    !source.includes(`public static let hostABI = "${abi}"`)
  )
    throw new Error("Missing host ABI declaration");
  if (source !== nextSource) await writeFile(configuration, nextSource);
  if (manifest.some((entry) => entry.hostABI !== abi)) {
    for (const entry of manifest) entry.hostABI = abi;
    await writeFile(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`);
  }
  return abi;
}

if (
  process.argv[1] &&
  resolve(process.argv[1]) === fileURLToPath(import.meta.url)
) {
  const root = resolve(process.argv[3] ?? process.cwd());
  const abi = await hostABI(root);
  const source = await readFile(
    resolve(
      root,
      "Packages/ExtensionMarketplace/Sources/ExtensionMarketplace/MarketplaceConfiguration.swift",
    ),
    "utf8",
  );
  const manifest = JSON.parse(
    await readFile(resolve(root, "Extensions/manifest.json"), "utf8"),
  );
  if (process.argv.includes("--write")) await writeHostABI(root);
  else if (
    !source.includes(`public static let hostABI = "${abi}"`) ||
    manifest.some((entry) => entry.hostABI !== abi)
  ) {
    throw new Error(
      "Host contract changed. Run bun scripts/extension-host-abi.mjs --write before committing.",
    );
  }
  process.stdout.write(`${abi}\n`);
}
