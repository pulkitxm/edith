import { execFileSync } from "node:child_process";
import { copyFile, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, resolve } from "node:path";
import { isDeepStrictEqual } from "node:util";
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
  maximumEnvelopeBytes,
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
  return execFileSync("gh", args, {
    encoding: "utf8",
    timeout: args[0] === "api" ? 60_000 : undefined,
    maxBuffer: 4 * 1024 ** 2,
  });
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

export async function verifiedPublicationState({
  ref,
  target,
  previous,
  publicKey,
  readMain,
  readCatalog,
}) {
  if (ref !== "refs/heads/main" || !/^[a-f0-9]{40}$/.test(target ?? ""))
    throw new Error(
      "Extension publication requires the approved main ref and commit",
    );
  validateCatalog(previous);
  if ((await readMain()) !== target)
    throw new Error("Extension publication superseded: main changed");
  const current = await readCatalog();
  if (current?.asset) {
    const trusted = JSON.parse(verifiedCatalogPayload(current.data, publicKey));
    if (!isDeepStrictEqual(trusted, previous))
      throw new Error(
        "Extension publication superseded: trusted catalog changed",
      );
  } else if (
    previous.revision !== 0 ||
    previous.packages.length !== 0 ||
    (current?.release && current.release.draft !== true)
  ) {
    throw new Error(
      "Extension publication blocked: trusted catalog pointer missing",
    );
  }
  if ((await readMain()) !== target)
    throw new Error("Extension publication superseded: main changed");
  return current;
}

export async function readPublicationCatalog(
  repository,
  tag,
  { loadRelease = release, downloadAsset = downloadReleaseAsset } = {},
) {
  const item = loadRelease(repository, tag);
  if (!item) return undefined;
  const asset = item.assets.find((entry) => entry.name === "catalog.json");
  if (!asset) return { release: item };
  const directory = await mkdtemp(resolve(tmpdir(), "edith-release-catalog-"));
  try {
    const destination = resolve(directory, "catalog.json");
    await downloadAsset({
      repository,
      asset,
      maximumBytes: maximumEnvelopeBytes,
      destination,
    });
    const data = await readFile(destination);
    if (data.length > maximumEnvelopeBytes)
      throw new Error("Catalog envelope exceeds its limit");
    return { release: item, asset, data };
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
}

export async function publicationPlanningState({
  repository,
  catalogTag,
  publicKey,
  readCatalog = () => readPublicationCatalog(repository, catalogTag),
}) {
  const current = await readCatalog();
  if (current?.asset)
    return {
      catalog: JSON.parse(verifiedCatalogPayload(current.data, publicKey)),
      draft: current.release.draft === true,
    };
  if (current?.release && current.release.draft !== true)
    throw new Error("Published catalog pointer missing");
  return {
    catalog: { schemaVersion: 1, revision: 0, packages: [] },
    draft: false,
  };
}

export async function publicationPlanCatalog(options) {
  return (await publicationPlanningState(options)).catalog;
}

export async function finalizeDraftCatalog({ verifyState, publish }) {
  const current = await verifyState();
  if (current?.release?.draft !== true || !current.asset) return false;
  await publish(current.release.id);
  return true;
}

export async function promoteExtensionCatalog({
  candidate,
  verifyState,
  rename,
}) {
  const current = await verifyState();
  const nextAsset = current?.release?.assets.find(
    (asset) => asset.name === candidate,
  );
  if (!nextAsset) throw new Error("Catalog upload did not finish");
  const priorAsset = current.asset;
  if (priorAsset)
    await rename(priorAsset.id, `catalog-${current.catalogRevision}.json`);
  try {
    await rename(nextAsset.id, "catalog.json");
  } catch (error) {
    if (priorAsset) await rename(priorAsset.id, "catalog.json");
    throw error;
  }
}

export async function publishExtensions({
  directory,
  repository,
  target,
  ref,
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
  const verifyState = async () => {
    const current = await verifiedPublicationState({
      ref,
      target,
      previous: old,
      publicKey,
      readMain: async () =>
        JSON.parse(gh("api", `repos/${repository}/git/ref/heads/main`)).object
          .sha,
      readCatalog: () => readPublicationCatalog(repository, catalogTag),
    });
    return current ? { ...current, catalogRevision: old.revision } : undefined;
  };
  await verifyState();
  const publishDraft = async (id) =>
    mutate(
      "release",
      "edit",
      "--repo",
      repository,
      String(id),
      "--draft",
      "false",
      "--make-latest",
      "false",
    );
  if (include.length === 0) {
    await finalizeDraftCatalog({ verifyState, publish: publishDraft });
    return { published: [], revision: old.revision };
  }
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
      "--draft",
      "--prerelease",
      "--body",
      "Signed extension catalog used by Edith.",
    );
    catalog = release(repository, catalogTag);
  }
  const candidate = `catalog-${next.revision}.json`;
  await upload(repository, catalog.id, catalogTag, envelope, candidate);
  await promoteExtensionCatalog({
    candidate,
    verifyState,
    rename: async (id, name) =>
      gh(
        "api",
        "--method",
        "PATCH",
        `repos/${repository}/releases/assets/${id}`,
        "-f",
        `name=${name}`,
      ),
  });
  if (catalog.draft)
    await finalizeDraftCatalog({
      verifyState: () =>
        verifiedPublicationState({
          ref,
          target,
          previous: next,
          publicKey,
          readMain: async () =>
            JSON.parse(gh("api", `repos/${repository}/git/ref/heads/main`))
              .object.sha,
          readCatalog: () => readPublicationCatalog(repository, catalogTag),
        }),
      publish: publishDraft,
    });
  return {
    published: records.map(({ id, version }) => ({ id, version })),
    revision: next.revision,
  };
}

if (import.meta.main) {
  const repository = process.env.GITHUB_REPOSITORY ?? "pulkitxm/edith";
  const catalogTag =
    process.env.EXTENSION_CATALOG_TAG ?? "extension-catalog-v1";
  const publicKey = process.env.EXTENSION_CATALOG_PUBLIC_KEY;
  if (process.argv[2] === "--read-catalog") {
    if (process.argv.length !== 4)
      throw new Error("Supply the verified catalog output file");
    const state = await publicationPlanningState({
      repository,
      catalogTag,
      publicKey,
    });
    const output = resolve(process.argv[3]);
    await writeFile(output, JSON.stringify(state.catalog));
    await writeFile(
      resolve(dirname(output), "previous-state.json"),
      JSON.stringify({ draft: state.draft }),
    );
    process.stdout.write(
      `Verified catalog revision: ${state.catalog.revision}\n`,
    );
  } else {
    if (process.argv.length !== 2)
      throw new Error("Invalid publication arguments");
    const result = await publishExtensions({
      directory: process.env.EXTENSION_OUTPUT ?? "dist/extensions",
      repository,
      target:
        process.env.GITHUB_SHA ??
        execFileSync("git", ["rev-parse", "HEAD"], { encoding: "utf8" }).trim(),
      ref: process.env.GITHUB_REF,
      catalogTag,
      publicKey,
    });
    process.stdout.write(`${JSON.stringify(result)}\n`);
  }
}
