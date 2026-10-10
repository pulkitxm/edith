import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import {
  catalogAssetURL,
  catalogReleaseURL,
  catalogTag,
  parseCatalogPointer,
  verifyCatalogPointerData,
} from "./extension-catalog-pointer.mjs";
import { writeHostABI } from "./extension-host-abi.mjs";
import { extensionFingerprint } from "./extension-release-plan.mjs";
import { verifiedCatalogPayload } from "./verify-extension-catalog.mjs";

export function verifyCatalog(envelope, publicKey) {
  return JSON.parse(verifiedCatalogPayload(Buffer.from(envelope), publicKey));
}

export function missingPackages(expected, catalog) {
  return expected.filter((entry) => {
    const compatible = catalog.packages.filter(
      (published) =>
        published.id === entry.id &&
        published.hostABI === entry.hostABI &&
        published.architecture === entry.architecture,
    );
    const systems = new Set([
      entry.minimumSystemVersion,
      ...compatible
        .map((published) => published.minimumSystemVersion)
        .filter((system) => system >= entry.minimumSystemVersion),
    ]);
    return [...systems].some((system) => {
      const selected = compatible
        .filter((published) => published.minimumSystemVersion <= system)
        .reduce(
          (latest, published) =>
            !latest ||
            latest.version.localeCompare(published.version, undefined, {
              numeric: true,
            }) < 0
              ? published
              : latest,
          undefined,
        );
      return selected?.sourceFingerprint !== entry.fingerprint;
    });
  });
}

export async function expectedPackages(root) {
  await writeHostABI(root);
  const definitions = JSON.parse(
    await readFile(resolve(root, "Extensions/manifest.json"), "utf8"),
  );
  return Promise.all(
    definitions.map(async (entry) => ({
      id: entry.id,
      hostABI: entry.hostABI,
      architecture: "arm64",
      minimumSystemVersion: entry.minimumSystemVersion,
      fingerprint: await extensionFingerprint(root, entry, definitions),
    })),
  );
}

export async function waitForPackages({
  expected,
  url,
  publicKey,
  timeout = 600_000,
  interval = 15_000,
  fetchCatalog = fetch,
  sleep = (duration) => new Promise((done) => setTimeout(done, duration)),
  now = Date.now,
}) {
  const deadline = now() + timeout;
  let missing = expected;
  while (true) {
    const response = await fetchCatalog(url ?? catalogReleaseURL, {
      signal: AbortSignal.timeout(15_000),
      headers: { "Cache-Control": "no-cache" },
    });
    if (response.status === 200) {
      let data;
      let pointer;
      if (url) data = Buffer.from(await response.text());
      else {
        const metadata = await response.text();
        if (Buffer.byteLength(metadata) > 3 * 1024 ** 2)
          throw new Error("Catalog release exceeds its limit");
        const release = JSON.parse(metadata);
        if (
          release.tag_name !== catalogTag ||
          release.draft !== false ||
          !Array.isArray(release.assets)
        )
          throw new Error("Invalid catalog release");
        pointer = parseCatalogPointer(release.body);
        const assets = release.assets.filter(
          (asset) => asset.name === pointer.assetName,
        );
        if (assets.length !== 1 || assets[0].size !== pointer.bytes)
          throw new Error("Invalid catalog pointer asset");
        const asset = await fetchCatalog(catalogAssetURL(pointer), {
          signal: AbortSignal.timeout(15_000),
          headers: { "Cache-Control": "no-cache" },
        });
        if (asset.status !== 200)
          throw new Error(`Cannot verify catalog asset: HTTP ${asset.status}`);
        data = Buffer.from(await asset.arrayBuffer());
        verifyCatalogPointerData(data, pointer);
      }
      const catalog = verifyCatalog(data, publicKey);
      if (pointer && pointer.revision !== catalog.revision)
        throw new Error("Catalog pointer revision mismatch");
      missing = missingPackages(expected, catalog);
      if (missing.length === 0) return catalog.revision;
    } else if (response.status !== 404) {
      throw new Error(
        `Cannot verify extension catalog: HTTP ${response.status}`,
      );
    }
    if (now() >= deadline)
      throw new Error(
        `App publication blocked: extensions not published: ${missing.map(({ id }) => id).join(", ")}`,
      );
    await sleep(Math.min(interval, Math.max(0, deadline - now())));
  }
}

if (
  process.argv[1] &&
  resolve(process.argv[1]) === fileURLToPath(import.meta.url)
) {
  const revision = await waitForPackages({
    expected: await expectedPackages(process.argv[2] ?? process.cwd()),
    publicKey: "ZmEn7Nvq56SkxwSOm7ey0kyBdFERSQgDywlDCuvxZgk=",
  });
  process.stdout.write(`Compatible extension catalog verified: ${revision}\n`);
}
