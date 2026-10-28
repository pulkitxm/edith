import { execFileSync, spawn } from "node:child_process";
import {
  copyFile,
  mkdtemp,
  readFile,
  rm,
  stat,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { isDeepStrictEqual } from "node:util";
import {
  catalogPointer,
  parseCatalogPointer,
  validateCatalogPointer,
  verifyCatalogPointerData,
} from "./extension-catalog-pointer.mjs";
import { extensionReleaseTag } from "./extension-release-plan.mjs";
import {
  publishExtensionAssets,
  verifyImmutableReleaseAssets,
} from "./immutable-release-assets.mjs";
import {
  downloadReleaseAsset,
  releaseFileDigest,
} from "./release-asset-read.mjs";
import {
  executeReleaseMutation,
  preflightReleaseAsset,
  uploadReleaseAsset,
} from "./release-asset-upload.mjs";

export { publishExtensionAssets } from "./immutable-release-assets.mjs";

import { withGitHubRetrySync } from "./github-retry.mjs";
import {
  listReleases,
  lookupRelease,
  releaseFromListing,
} from "./release-lookup.mjs";
import { assertShippingExtensions } from "./shipping-extension-policy.mjs";
import {
  maximumCatalogPackages,
  maximumEnvelopeBytes,
  validateCatalog,
  verifiedCatalogPayload,
} from "./verify-extension-catalog.mjs";

function publishedVersion(packages, record) {
  const existing = packages.find(
    (candidate) =>
      candidate.id === record.id &&
      candidate.hostABI === record.hostABI &&
      candidate.architecture === record.architecture &&
      candidate.version === record.version,
  );
  if (existing && !isDeepStrictEqual(existing, record))
    throw new Error("Published package versions are immutable");
  return existing;
}

export function mergeExtensionCatalog(previous, records, revision) {
  if (!Number.isSafeInteger(revision) || revision <= previous.revision)
    throw new Error("Catalog revision must increase");
  const packages = [...previous.packages];
  for (const record of records) {
    const existing = publishedVersion(packages, record);
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
  const run = () =>
    execFileSync("gh", args, {
      encoding: "utf8",
      timeout: args[0] === "api" ? 60_000 : undefined,
      maxBuffer: 4 * 1024 ** 2,
    });
  if (args[0] !== "api") return run();
  return withGitHubRetrySync(() => {
    const output = run();
    JSON.parse(output);
    return output;
  });
}

function mutate(...args) {
  return executeReleaseMutation(args);
}

function release(repository, tag) {
  return lookupRelease({ repository, tag });
}

async function upload(repository, releaseID, tag, file, name) {
  await uploadReleaseAsset({ repository, releaseID, tag, file, name });
}

export const stableCatalogAsset = "catalog.json";

export async function publishStableCatalog({
  repository,
  tag,
  file,
  readRelease = (request) => release(request.repository, request.tag),
  removeAsset = (id) =>
    execFileSync(
      "gh",
      ["api", "-X", "DELETE", `repos/${repository}/releases/assets/${id}`],
      { stdio: "ignore", timeout: 60_000 },
    ),
  uploadAsset = upload,
}) {
  const item = readRelease({ repository, tag });
  if (!item) throw new Error("Catalog release is not available");
  for (const asset of item.assets.filter(
    (entry) => entry.name === stableCatalogAsset,
  ))
    removeAsset(asset.id);
  await uploadAsset(repository, item.id, tag, file, stableCatalogAsset);
  const stable = readRelease({ repository, tag })?.assets.filter(
    (entry) => entry.name === stableCatalogAsset,
  );
  if (stable?.length !== 1 || stable[0].size !== (await stat(file)).size)
    throw new Error("Stable catalog upload did not finish");
}

export function extensionChecksum(record) {
  if (
    !/^[A-Za-z][A-Za-z0-9]*$/.test(record.id ?? "") ||
    !/^[a-f0-9]{64}$/.test(record.sha256 ?? "")
  )
    throw new Error("Invalid extension checksum identity");
  return `${record.sha256}  ${record.id}.zip\n`;
}

export async function validateExtensionChecksum(file, record) {
  const expected = extensionChecksum(record);
  if (
    (await stat(file)).size !== Buffer.byteLength(expected) ||
    (await readFile(file, "utf8")) !== expected
  )
    throw new Error("Extension checksum does not match the archive");
}

export function validateExtensionReleaseIdentity({
  repository,
  entry,
  record,
}) {
  if (
    record.id !== entry.id ||
    entry.tag !==
      extensionReleaseTag({
        id: entry.id,
        version: entry.version,
        fingerprint: entry.fingerprint,
      }) ||
    record.downloadURL !==
      `https://github.com/${repository}/releases/download/${encodeURIComponent(entry.tag)}/${entry.id}.zip`
  )
    throw new Error(
      "Extension release identity does not match the source plan",
    );
}

export async function validatedExtensionBuild({
  repository,
  directory,
  entry,
}) {
  const record = JSON.parse(
    await readFile(resolve(directory, `${entry.id}.json`), "utf8"),
  );
  validateExtensionReleaseIdentity({ repository, entry, record });
  const digest = await releaseFileDigest(resolve(directory, `${entry.id}.zip`));
  if (
    record.sourceFingerprint !== entry.fingerprint ||
    record.version !== entry.version ||
    record.downloadBytes !== digest.size ||
    record.sha256 !== digest.sha256
  )
    throw new Error("Build output does not match the release plan");
  await validateExtensionChecksum(
    resolve(directory, `${entry.id}.zip.sha256`),
    record,
  );
  return record;
}

export async function preflightExtensionBuilds({
  repository,
  directory,
  include,
  previous,
  preflightAsset = preflightReleaseAsset,
}) {
  const packages = [...previous.packages];
  for (const entry of include) {
    const record = await validatedExtensionBuild({
      repository,
      directory,
      entry,
    });
    if (!publishedVersion(packages, record)) packages.push(record);
  }
  for (const entry of include)
    for (const suffix of ["zip", "json", "zip.sha256"])
      preflightAsset({
        repository,
        file: resolve(directory, `${entry.id}.${suffix}`),
      });
}

export async function restorePublishedExtension({
  repository,
  record,
  entry,
  publishedRecord,
  publishedArchive,
  publishedChecksum,
  checksumPath,
  recordPath,
  zip,
  recordData,
  downloadAsset = downloadReleaseAsset,
}) {
  const data =
    recordData ??
    (await downloadAsset({ repository, asset: publishedRecord })).data;
  if (!Buffer.isBuffer(data) || data.length > 1024 ** 2)
    throw new Error("Invalid original extension record");
  const published = JSON.parse(data.toString("utf8"));
  validateExtensionReleaseIdentity({ repository, entry, record: published });
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
    const checksum = extensionChecksum(published);
    if (publishedChecksum) {
      const result = await downloadAsset({
        repository,
        asset: publishedChecksum,
        expectedBytes: Buffer.byteLength(checksum),
        maximumBytes: 256,
      });
      if (result.data.toString("utf8") !== checksum)
        throw new Error(
          "Published extension checksum does not match the archive",
        );
    }
    await copyFile(archive, zip);
    await writeFile(checksumPath, checksum);
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
    const trusted = trustedPublicationCatalog(current, publicKey);
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
  if (item.body == null || item.body === "") return { release: item };
  const pointer = parseCatalogPointer(item.body);
  const matches = item.assets.filter(
    (entry) => entry.name === pointer.assetName,
  );
  if (matches.length !== 1)
    throw new Error("Catalog pointer asset missing or duplicated");
  const asset = matches[0];
  if (asset.size !== pointer.bytes)
    throw new Error("Catalog pointer asset size mismatch");
  const data = await readPointerAsset(
    repository,
    asset,
    pointer,
    downloadAsset,
  );
  return { release: item, asset, data, pointer };
}

async function readPointerAsset(
  repository,
  asset,
  pointer,
  downloadAsset = downloadReleaseAsset,
) {
  const directory = await mkdtemp(resolve(tmpdir(), "edith-release-catalog-"));
  try {
    const destination = resolve(directory, "catalog.json");
    await downloadAsset({
      repository,
      asset,
      maximumBytes: maximumEnvelopeBytes,
      expectedBytes: pointer.bytes,
      expectedSHA256: pointer.sha256,
      destination,
    });
    const data = await readFile(destination);
    verifyCatalogPointerData(data, pointer);
    return data;
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
}

export function trustedPublicationCatalog(current, publicKey) {
  const catalog = JSON.parse(verifiedCatalogPayload(current.data, publicKey));
  if (!current.pointer || catalog.revision !== current.pointer.revision)
    throw new Error("Catalog pointer revision mismatch");
  verifyCatalogPointerData(current.data, current.pointer);
  return catalog;
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
      catalog: trustedPublicationCatalog(current, publicKey),
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
  pointer,
  verifyState,
  verifyAsset,
  updatePointer,
}) {
  validateCatalogPointer(pointer);
  const staged = await verifyState();
  const matches =
    staged?.release?.assets.filter(
      (asset) => asset.name === pointer.assetName,
    ) ?? [];
  if (matches.length !== 1 || matches[0].size !== pointer.bytes)
    throw new Error("Catalog upload did not finish");
  await verifyAsset(matches[0], pointer);
  const current = await verifyState();
  const stillStaged =
    current?.release?.assets.filter(
      (asset) => asset.name === pointer.assetName,
    ) ?? [];
  if (
    current?.release?.id !== staged.release.id ||
    stillStaged.length !== 1 ||
    stillStaged[0].id !== matches[0].id ||
    stillStaged[0].size !== pointer.bytes
  )
    throw new Error("Catalog release changed");
  await updatePointer(current.release.id, JSON.stringify(pointer));
}

async function publishEntry({
  repository,
  directory,
  entry,
  target,
  existingReleases,
  verifyState,
}) {
  const recordPath = resolve(directory, `${entry.id}.json`);
  let record = await validatedExtensionBuild({
    repository,
    directory,
    entry,
  });
  const zip = resolve(directory, `${entry.id}.zip`);
  let item = releaseFromListing(existingReleases, entry.tag);
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
    if (!item) throw new Error("Created extension release is not available");
  }
  const checksumPath = resolve(directory, `${entry.id}.zip.sha256`);
  const publishedChecksum = item.assets.find(
    (asset) => asset.name === `${entry.id}.zip.sha256`,
  );
  const publishedRecord = item.assets.find(
    (asset) => asset.name === `${entry.id}.json`,
  );
  const publishedArchive = item.assets.find(
    (asset) => asset.name === `${entry.id}.zip`,
  );
  if (publishedArchive) {
    if (!publishedRecord)
      throw new Error("Existing release is missing its package record");
    record = await restorePublishedExtension({
      repository,
      record,
      entry,
      publishedRecord,
      publishedArchive,
      publishedChecksum,
      checksumPath,
      recordPath,
      zip,
    });
  }
  const publishedAssets = await publishExtensionAssets({
    repository,
    item,
    entry,
    files: [
      [zip, `${entry.id}.zip`],
      [recordPath, `${entry.id}.json`],
      [checksumPath, `${entry.id}.zip.sha256`],
    ],
  });
  await verifyState();
  if (item.draft)
    mutate(
      "release",
      "edit",
      "--repo",
      repository,
      String(item.id),
      "--tag",
      entry.tag,
      "--draft",
      "false",
      "--make-latest",
      "false",
    );
  await verifyImmutableReleaseAssets({
    repository,
    receipt: publishedAssets,
  });
  return record;
}

export const publicationConcurrency = 6;

export async function runBounded(items, limit, task) {
  const queue = [...items];
  let failure;
  await Promise.all(
    Array.from({ length: Math.min(limit, queue.length) }, async () => {
      while (queue.length && !failure) {
        const item = queue.shift();
        try {
          await task(item);
        } catch (error) {
          failure ??= error;
        }
      }
    }),
  );
  if (failure) throw failure;
}

async function publishEntries({
  directory,
  repository,
  target,
  ref,
  catalogTag,
  publicKey,
  include,
}) {
  const script = fileURLToPath(import.meta.url);
  const environment = {
    ...process.env,
    EXTENSION_OUTPUT: directory,
    GITHUB_REPOSITORY: repository,
    GITHUB_SHA: target,
    GITHUB_REF: ref ?? "",
    EXTENSION_CATALOG_TAG: catalogTag,
    EXTENSION_CATALOG_PUBLIC_KEY: publicKey,
  };
  const worker = (entry) =>
    new Promise((done, fail) => {
      const child = spawn(process.execPath, [script, "--entry", entry.id], {
        env: environment,
        stdio: ["ignore", "inherit", "inherit"],
      });
      child.on("error", fail);
      child.on("exit", (code) =>
        code === 0
          ? done()
          : fail(new Error(`Extension publication failed: ${entry.id}`)),
      );
    });
  await runBounded(include, publicationConcurrency, worker);
  return Promise.all(
    include.map(async (entry) =>
      JSON.parse(
        await readFile(
          resolve(directory, `${entry.id}.published.json`),
          "utf8",
        ),
      ),
    ),
  );
}

async function publicationContext({
  directory,
  repository,
  target,
  ref,
  catalogTag,
  publicKey,
}) {
  const old = JSON.parse(
    await readFile(resolve(directory, "previous.json"), "utf8"),
  );
  const { include } = JSON.parse(
    await readFile(resolve(directory, "plan.json"), "utf8"),
  );
  assertShippingExtensions(include);
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
  return { old, include, verifyState };
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
  execFileSync(
    "swift",
    ["scripts/extension-catalog-sign.swift", "check-key", publicKey],
    {
      stdio: "inherit",
      timeout: 60_000,
    },
  );
  const { old, include, verifyState } = await publicationContext({
    directory,
    repository,
    target,
    ref,
    catalogTag,
    publicKey,
  });
  await verifyState();
  const publishDraft = async (id, tag) =>
    mutate(
      "release",
      "edit",
      "--repo",
      repository,
      String(id),
      "--tag",
      tag,
      "--draft",
      "false",
      "--make-latest",
      "false",
    );
  await preflightExtensionBuilds({
    repository,
    directory,
    include,
    previous: old,
  });
  if (include.length === 0) {
    const current = await verifyState();
    if (current?.release?.draft !== true || !current.asset)
      throw new Error(
        "A verified owned draft catalog is required for an empty publication resume",
      );
    await finalizeDraftCatalog({
      verifyState,
      publish: (id) => publishDraft(id, catalogTag),
    });
    await verifyState();
    return { published: [], revision: old.revision };
  }
  const records = await publishEntries({
    directory,
    repository,
    target,
    ref,
    catalogTag,
    publicKey,
    include,
  });
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
      "",
    );
    catalog = release(repository, catalogTag);
    if (!catalog) throw new Error("Created catalog release is not available");
  }
  const candidate = `catalog-${next.revision}.json`;
  await upload(repository, catalog.id, catalogTag, envelope, candidate);
  const pointer = catalogPointer(await readFile(envelope), next.revision);
  const verifyAsset = async (asset, pointer) => {
    const data = await readPointerAsset(repository, asset, pointer);
    const verified = JSON.parse(
      verifiedCatalogPayload(
        verifyCatalogPointerData(data, pointer),
        publicKey,
      ),
    );
    if (!isDeepStrictEqual(verified, next))
      throw new Error("Staged catalog differs");
  };
  await promoteExtensionCatalog({
    pointer,
    verifyState,
    verifyAsset,
    updatePointer: async (id, body) =>
      mutate(
        "release",
        "edit",
        "--repo",
        repository,
        String(id),
        "--tag",
        catalogTag,
        "--body",
        body,
        "--make-latest",
        "false",
      ),
  });
  await publishStableCatalog({
    repository,
    tag: catalogTag,
    file: envelope,
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
      publish: (id) => publishDraft(id, catalogTag),
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
  } else if (process.argv[2] === "--entry") {
    if (process.argv.length !== 4)
      throw new Error("Supply the extension to publish");
    const directory = process.env.EXTENSION_OUTPUT ?? "dist/extensions";
    const target = process.env.GITHUB_SHA;
    const { include, verifyState } = await publicationContext({
      directory,
      repository,
      target,
      ref: process.env.GITHUB_REF,
      catalogTag,
      publicKey,
    });
    const entry = include.find(({ id }) => id === process.argv[3]);
    if (!entry) throw new Error("Unknown extension publication entry");
    const record = await publishEntry({
      repository,
      directory,
      entry,
      target,
      existingReleases: listReleases({ repository }),
      verifyState,
    });
    await writeFile(
      resolve(directory, `${entry.id}.published.json`),
      JSON.stringify(record),
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
