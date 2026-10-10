import { execFileSync } from "node:child_process";
import { copyFile, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { resolve } from "node:path";
import {
  downloadReleaseAsset,
  releaseAssetMatchesFile,
  releaseFileDigest,
} from "./release-asset-read.mjs";
import {
  preflightReleaseAsset,
  uploadReleaseAsset,
} from "./release-asset-upload.mjs";
import {
  maximumCatalogPackages,
  validateCatalog,
  verifiedCatalogPayload,
} from "./verify-extension-catalog.mjs";

export function mergeExtensionCatalog(previous, records, revision) {
  if (!Number.isSafeInteger(revision) || revision <= previous.revision)
    throw new Error("Catalog revision must increase");
  const packages = [...previous.packages];
  for (const record of records) {
    const identity = (candidate) =>
      candidate.id === record.id &&
      candidate.hostABI === record.hostABI &&
      candidate.architecture === record.architecture &&
      candidate.version === record.version;
    const existing = packages.find(identity);
    if (existing && existing.sha256 !== record.sha256)
      throw new Error("Published package versions are immutable");
    if (!existing) packages.push(record);
  }
  const tiers = new Map();
  for (const record of packages) {
    const key = JSON.stringify([
      record.id,
      record.hostABI,
      record.architecture,
      record.minimumSystemVersion,
    ]);
    if (!tiers.has(key)) tiers.set(key, []);
    tiers.get(key).push(record);
  }
  const retained = [...tiers.values()].flatMap((versions) =>
    versions
      .sort((a, b) =>
        b.version.localeCompare(a.version, undefined, { numeric: true }),
      )
      .slice(0, 2),
  );
  if (retained.length > maximumCatalogPackages)
    throw new Error(
      "Catalog cannot preserve compatible rollback versions within its package limit",
    );
  const catalog = { schemaVersion: 1, revision, packages: retained };
  validateCatalog(catalog);
  return catalog;
}

function gh(...args) {
  return execFileSync("gh", args, { encoding: "utf8" });
}

function mutate(...args) {
  const result = JSON.parse(
    execFileSync("pukbot", [...args, "--json"], { encoding: "utf8" }),
  );
  if (result.workflowUrl) {
    const url = new URL(result.workflowUrl);
    const parts = url.pathname.split("/").filter(Boolean);
    gh(
      "run",
      "watch",
      parts.at(-1),
      "--repo",
      `${parts[0]}/${parts[1]}`,
      "--exit-status",
    );
  }
  return result;
}

function release(repository, tag) {
  try {
    return JSON.parse(
      gh("api", `repos/${repository}/releases/tags/${encodeURIComponent(tag)}`),
    );
  } catch (error) {
    if (String(error.stderr).includes("404")) return undefined;
    throw error;
  }
}

async function upload(repository, releaseID, tag, file, name) {
  await uploadReleaseAsset({ repository, releaseID, tag, file, name });
}

export async function restorePublishedExtension({
  repository,
  record,
  entry,
  publishedRecord,
  publishedArchive,
  recordPath,
  zip,
  downloadAsset = downloadReleaseAsset,
}) {
  const { data } = await downloadAsset({ repository, asset: publishedRecord });
  const published = JSON.parse(data.toString("utf8"));
  if (
    published.id !== record.id ||
    published.hostABI !== record.hostABI ||
    published.architecture !== record.architecture ||
    published.version !== entry.version ||
    published.sourceFingerprint !== entry.fingerprint
  )
    throw new Error("Existing release does not match the source plan");
  const temporary = await mkdtemp(resolve(tmpdir(), "edith-release-asset-"));
  try {
    const archive = resolve(temporary, "package.zip");
    await downloadAsset({
      repository,
      asset: publishedArchive,
      expectedBytes: published.downloadBytes,
      expectedSHA256: published.sha256,
      maximumBytes: 512 * 1024 ** 2,
      destination: archive,
    });
    await copyFile(archive, zip);
    await writeFile(recordPath, data);
    return published;
  } finally {
    await rm(temporary, { recursive: true, force: true });
  }
}

export async function publishExtensions({
  directory,
  repository,
  target,
  catalogTag,
  publicKey,
}) {
  if (!publicKey || !process.env.EXTENSION_CATALOG_PRIVATE_KEY)
    throw new Error(
      "Catalog signing credentials are required before publication",
    );
  const old = JSON.parse(
    await readFile(resolve(directory, "previous.json"), "utf8"),
  );
  const { include } = JSON.parse(
    await readFile(resolve(directory, "plan.json"), "utf8"),
  );
  if (include.length === 0) return { published: [], revision: old.revision };
  for (const entry of include) {
    for (const suffix of ["zip", "json"]) {
      preflightReleaseAsset({
        repository,
        file: resolve(directory, `${entry.id}.${suffix}`),
      });
    }
  }
  const records = [];
  for (const entry of include) {
    const recordPath = resolve(directory, `${entry.id}.json`);
    let record = JSON.parse(await readFile(recordPath, "utf8"));
    const zip = resolve(directory, `${entry.id}.zip`);
    const digest = await releaseFileDigest(zip);
    if (
      record.sourceFingerprint !== entry.fingerprint ||
      record.version !== entry.version ||
      record.downloadBytes !== digest.size ||
      record.sha256 !== digest.sha256
    )
      throw new Error("Build output does not match the release plan");
    let item = release(repository, entry.tag);
    if (!item) {
      mutate(
        "release",
        "create",
        "--repo",
        repository,
        entry.tag,
        "--target",
        target,
        "--name",
        `${entry.id} ${entry.version}`,
        "--draft",
        "--prerelease",
        "--body",
        `Independent extension package for Edith host ${record.hostABI}.`,
      );
      item = release(repository, entry.tag);
    }
    const publishedRecord = item.assets.find(
      (asset) => asset.name === `${entry.id}.json`,
    );
    const publishedArchive = item.assets.find(
      (asset) => asset.name === `${entry.id}.zip`,
    );
    if (publishedRecord && publishedArchive) {
      record = await restorePublishedExtension({
        repository,
        record,
        entry,
        publishedRecord,
        publishedArchive,
        recordPath,
        zip,
      });
    }
    for (const [file, name] of [
      [zip, `${entry.id}.zip`],
      [recordPath, `${entry.id}.json`],
    ]) {
      const existing = item.assets.find((asset) => asset.name === name);
      if (existing) {
        if (
          !(await releaseAssetMatchesFile({
            repository,
            asset: existing,
            file,
          }))
        )
          throw new Error("Immutable asset differs from build output");
      } else await upload(repository, item.id, entry.tag, file, name);
    }
    mutate(
      "release",
      "edit",
      "--repo",
      repository,
      String(item.id),
      "--draft",
      "false",
      "--make-latest",
      "false",
    );
    records.push(record);
  }
  const next = mergeExtensionCatalog(
    old,
    records,
    Math.max(Date.now(), old.revision + 1),
  );
  const payload = resolve(directory, "payload.json");
  const envelope = resolve(directory, "catalog.json");
  await writeFile(payload, JSON.stringify(next));
  execFileSync(
    "swift",
    ["scripts/extension-catalog-sign.swift", "sign", payload, envelope],
    { stdio: "inherit" },
  );
  execFileSync(
    "swift",
    [
      "scripts/extension-catalog-sign.swift",
      "verify",
      envelope,
      resolve(directory, "verified-next.json"),
      publicKey,
    ],
    { stdio: "inherit" },
  );
  verifiedCatalogPayload(await readFile(envelope), publicKey);
  let catalog = release(repository, catalogTag);
  if (!catalog) {
    mutate(
      "release",
      "create",
      "--repo",
      repository,
      catalogTag,
      "--target",
      target,
      "--name",
      "Edith extension catalog",
      "--prerelease",
      "--body",
      "Signed extension catalog used by Edith.",
    );
    catalog = release(repository, catalogTag);
  }
  const candidate = `catalog-${next.revision}.json`;
  await upload(repository, catalog.id, catalogTag, envelope, candidate);
  catalog = release(repository, catalogTag);
  const priorAsset = catalog.assets.find(
    (asset) => asset.name === "catalog.json",
  );
  const nextAsset = catalog.assets.find((asset) => asset.name === candidate);
  if (!nextAsset) throw new Error("Catalog upload did not finish");
  if (priorAsset)
    gh(
      "api",
      "--method",
      "PATCH",
      `repos/${repository}/releases/assets/${priorAsset.id}`,
      "-f",
      `name=catalog-${old.revision}.json`,
    );
  try {
    gh(
      "api",
      "--method",
      "PATCH",
      `repos/${repository}/releases/assets/${nextAsset.id}`,
      "-f",
      "name=catalog.json",
    );
  } catch (error) {
    if (priorAsset)
      gh(
        "api",
        "--method",
        "PATCH",
        `repos/${repository}/releases/assets/${priorAsset.id}`,
        "-f",
        "name=catalog.json",
      );
    throw error;
  }
  return {
    published: records.map(({ id, version }) => ({ id, version })),
    revision: next.revision,
  };
}

if (import.meta.main) {
  const result = await publishExtensions({
    directory: process.env.EXTENSION_OUTPUT ?? "dist/extensions",
    repository: process.env.GITHUB_REPOSITORY ?? "pulkitxm/edith",
    target:
      process.env.GITHUB_SHA ??
      execFileSync("git", ["rev-parse", "HEAD"], { encoding: "utf8" }).trim(),
    catalogTag: process.env.EXTENSION_CATALOG_TAG ?? "extension-catalog-v1",
    publicKey: process.env.EXTENSION_CATALOG_PUBLIC_KEY,
  });
  process.stdout.write(`${JSON.stringify(result)}\n`);
}
