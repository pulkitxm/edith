import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import {
  catalogAssetURL,
  catalogReleaseURL,
  catalogRepository,
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

export async function verifyCurrentMain({ target, releaseTag, fetchMetadata }) {
  if (
    !/^[a-f0-9]{40}$/.test(target) ||
    !/^v[0-9]+\.[0-9]+\.[0-9]+$/.test(releaseTag)
  )
    throw new Error("Invalid release source identity");
  const read = async (path) => {
    const response = await fetchMetadata(
      `https://api.github.com/repos/${catalogRepository}/${path}`,
    );
    if (response.status !== 200)
      throw new Error(`Cannot verify current main: HTTP ${response.status}`);
    const data = await response.text();
    if (Buffer.byteLength(data) > 1024 ** 2)
      throw new Error("Current main response exceeds its limit");
    return JSON.parse(data);
  };
  const reference = await read("git/ref/heads/main");
  if (
    reference.ref !== "refs/heads/main" ||
    reference.object?.type !== "commit" ||
    !/^[a-f0-9]{40}$/.test(reference.object.sha)
  )
    throw new Error("Invalid current main reference");
  if (reference.object.sha === target) return;
  const commit = await read(`commits/${reference.object.sha}`);
  if (
    commit.sha !== reference.object.sha ||
    commit.parents?.length !== 1 ||
    commit.parents[0].sha !== target ||
    commit.commit?.message.split("\n")[0] !== `Release ${releaseTag} [skip ci]`
  )
    throw new Error(
      "App publication superseded: main moved after the release build",
    );
}

export async function waitForPackages({
  expected,
  url,
  publicKey,
  timeout = 120 * 60_000,
  interval = 15_000,
  fetchCatalog = fetch,
  sleep = (duration) => new Promise((done) => setTimeout(done, duration)),
  now = Date.now,
  verifySource = async () => {},
}) {
  if (
    !Number.isSafeInteger(timeout) ||
    timeout < 0 ||
    timeout > 120 * 60_000 ||
    !Number.isSafeInteger(interval) ||
    interval < 1 ||
    interval > 60_000
  )
    throw new Error("Invalid catalog readiness deadline");
  const deadline = now() + timeout;
  let missing = expected;
  while (true) {
    await verifySource();
    let response = await fetchCatalog(url ?? catalogReleaseURL, {
      signal: AbortSignal.timeout(15_000),
      headers: { "Cache-Control": "no-cache" },
    });
    let release;
    if (!url && response.status === 200) {
      const metadata = await response.text();
      if (Buffer.byteLength(metadata) > 3 * 1024 ** 2)
        throw new Error("Catalog release exceeds its limit");
      release = JSON.parse(metadata);
      if (
        !release ||
        release.tag_name !== catalogTag ||
        typeof release.draft !== "boolean" ||
        !Array.isArray(release.assets)
      )
        throw new Error("Invalid catalog release");
      if (release.draft) response = { status: 404 };
    }
    if (response.status === 200) {
      let data;
      let pointer;
      if (url) data = Buffer.from(await response.text());
      else {
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
      if (missing.length === 0) {
        await verifySource();
        return catalog.revision;
      }
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
  const fetchMetadata = (url, options = {}) =>
    fetch(url, {
      ...options,
      signal: AbortSignal.timeout(15_000),
      headers: {
        "Cache-Control": "no-cache",
        ...(new URL(url).origin === "https://api.github.com" &&
        process.env.GH_TOKEN
          ? { Authorization: `Bearer ${process.env.GH_TOKEN}` }
          : {}),
      },
    });
  const target = process.env.REBUILD ? undefined : process.env.BUILT_SHA;
  const revision = await waitForPackages({
    expected: await expectedPackages(process.argv[2] ?? process.cwd()),
    publicKey: "ZmEn7Nvq56SkxwSOm7ey0kyBdFERSQgDywlDCuvxZgk=",
    fetchCatalog: fetchMetadata,
    verifySource:
      target === undefined
        ? async () => {}
        : () =>
            verifyCurrentMain({
              target,
              releaseTag: process.env.RELEASE_TAG,
              fetchMetadata,
            }),
  });
  process.stdout.write(`Compatible extension catalog verified: ${revision}\n`);
}
