import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import {
  chmod,
  lstat,
  mkdir,
  mkdtemp,
  readFile,
  realpath,
  writeFile,
} from "node:fs/promises";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import {
  catalogAssetURL,
  parseCatalogPointer,
  verifyCatalogPointerData,
} from "../extension-catalog-pointer.mjs";
import { evidenceInventory } from "../extension-native-evidence.mjs";
import {
  extensionFingerprint,
  planUnpublishedExtensions,
} from "../extension-release-plan.mjs";
import { managedAuthenticatedFetch } from "../hosted-managed-views/execution-contract.mjs";
import {
  downloadCIArtifact,
  validatePackageReceipt,
} from "../hosted-managed-views/package-preparation.mjs";
import { verifiedCatalogPayload } from "../verify-extension-catalog.mjs";
import {
  closedJSON,
  currentPackages,
  digest,
  downloadPublic,
  hosted,
  hostRun,
  ownedDraftResume,
  productionRun,
  repository,
  request,
  successfulRun,
  toolchainProvenance,
} from "./contract.mjs";
import {
  admitEvidence,
  admitOriginalEvidence,
  closedAssetInventory,
  durableArtifact,
  evidenceTag,
  publisherStepNames,
  verifiedComposition,
  verifiedEnvelope,
  verifiedEvidence,
  verifiedLineage,
} from "./evidence.mjs";

const script = fileURLToPath(import.meta.url);
function command(file, args, cwd, timeout = 120000) {
  return execFileSync(file, args, {
    cwd,
    encoding: "utf8",
    timeout,
    maxBuffer: 8 * 1024 ** 2,
  });
}
async function record(path, value) {
  await writeFile(path, `${JSON.stringify(value, null, 2)}\n`, {
    flag: "wx",
    mode: 0o600,
  });
}
async function privateDirectory(path) {
  await mkdir(path, { mode: 0o700 });
  const status = await lstat(path);
  assert(
    status.isDirectory() &&
      status.uid === process.getuid() &&
      (status.mode & 0o7777) === 0o700,
  );
  assert.equal(await realpath(path), path);
}
export async function run() {
  hosted(process.env, process.env.EXPECTED_SOURCE_SHA);
  assert.equal(process.platform, "darwin");
  assert.equal(process.arch, "arm64");
  const options = request(process.env.PUBLIC_RELEASE_REQUEST);
  const root = await realpath(process.cwd());
  const clean = () => {
    assert.equal(
      command("git", ["rev-parse", "HEAD"], root).trim(),
      process.env.EXPECTED_SOURCE_SHA,
    );
    assert.equal(
      command(
        "git",
        ["status", "--porcelain", "--untracked-files=normal"],
        root,
      ),
      "",
    );
  };
  clean();
  const output = join(root, "local/hosted-public-release");
  await mkdir(join(root, "local"), { recursive: true });
  await privateDirectory(output);
  const work = await realpath(
    await mkdtemp(
      join(await realpath(process.env.RUNNER_TEMP), "public-release-"),
    ),
  );
  await chmod(work, 0o700);
  const authenticated = managedAuthenticatedFetch(process.env, fetch);
  for (const [key, name] of Object.entries({
    HOME: "home",
    CFFIXED_USER_HOME: "cfhome",
    XDG_CONFIG_HOME: "config",
    XDG_CACHE_HOME: "cache",
    XDG_DATA_HOME: "data",
    TMPDIR: "tmp",
  })) {
    const path = join(work, name);
    await privateDirectory(path);
    process.env[key] = path;
  }
  process.env.PYTHONDONTWRITEBYTECODE = "1";
  const python = (...args) =>
    JSON.parse(
      command(
        "python3",
        [
          "-B",
          join(root, "scripts/hosted-public-release/static-proof.py"),
          ...args,
        ],
        root,
        300000,
      ),
    );
  const document = (path) => python("document", path);
  async function api(path) {
    assert(/^\/(?:actions\/|git\/|pulls\/|releases\/)/.test(path));
    const response = await authenticated(
      `https://api.github.com/repos/${repository}${path}`,
      {
        signal: AbortSignal.timeout(60000),
        headers: { Accept: "application/vnd.github+json" },
      },
    );
    assert.equal(response.status, 200);
    const reader = response.body.getReader(),
      chunks = [];
    let total = 0;
    try {
      while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        total += value.length;
        assert(total <= 8 * 1024 ** 2);
        chunks.push(value);
      }
    } finally {
      await reader.cancel();
    }
    return closedJSON(Buffer.concat(chunks).toString("utf8"), 8 * 1024 ** 2);
  }
  async function inventory(runID) {
    const run = await api(`/actions/runs/${runID}`);
    async function pages(kind) {
      const values = [];
      for (let page = 1; page <= 10; page++) {
        const result = await api(
          `/actions/runs/${runID}/${kind}?per_page=100&page=${page}`,
        );
        assert(
          Number.isSafeInteger(result.total_count) &&
            result.total_count >= 0 &&
            result.total_count <= 1000,
        );
        assert(Array.isArray(result[kind]) && result[kind].length <= 100);
        values.push(...result[kind]);
        if (values.length === result.total_count) return values;
        assert(
          values.length < result.total_count && result[kind].length === 100,
        );
      }
      throw new Error("CI inventory exceeds pagination bound");
    }
    const [jobs, artifacts] = await Promise.all([
      pages("jobs"),
      pages("artifacts"),
    ]);
    return { run, jobs, artifacts };
  }
  const initialMain = await api("/git/ref/heads/main");
  const initialTag = await api(`/git/ref/tags/${options.tag}`);
  assert.equal(initialTag.object.type, "commit");
  assert.equal(initialMain.object.type, "commit");
  assert.equal(initialTag.object.sha, initialMain.object.sha);
  assert.equal(initialMain.object.sha, process.env.EXPECTED_SOURCE_SHA);
  const [production, host] = await Promise.all([
    inventory(options.packagesRun),
    inventory(options.hostRun),
  ]);
  for (const [value, id] of [
    [production, options.packagesRun],
    [host, options.hostRun],
  ])
    assert.equal(value.run.id, id);
  const sourceDirectory = join(work, "source");
  await privateDirectory(sourceDirectory);
  command(
    "git",
    ["clone", "--shared", "--no-checkout", root, sourceDirectory],
    root,
  );
  command("git", ["checkout", "--detach", options.source], sourceDirectory);
  const definitions = JSON.parse(
    await readFile(join(sourceDirectory, "Extensions/manifest.json"), "utf8"),
  );
  assert.equal(definitions.length, 39);
  assert.equal(new Set(definitions.map(({ id }) => id)).size, 39);
  const fingerprints = Object.fromEntries(
    await Promise.all(
      definitions.map(async (definition) => [
        definition.id,
        await extensionFingerprint(sourceDirectory, definition, definitions),
      ]),
    ),
  );
  const catalogRelease = await api("/releases/tags/extension-catalog-v1");
  assert.equal(catalogRelease.draft, false);
  assert.equal(catalogRelease.tag_name, "extension-catalog-v1");
  const pointer = parseCatalogPointer(catalogRelease.body);
  const envelope = join(work, "catalog.json");
  await publicAsset(
    catalogRelease,
    pointer.assetName,
    pointer.bytes,
    pointer.sha256,
    envelope,
  );
  assert.equal(
    catalogAssetURL(pointer),
    `https://github.com/${repository}/releases/download/extension-catalog-v1/${pointer.assetName}`,
  );
  const envelopeBytes = verifyCatalogPointerData(
    await readFile(envelope),
    pointer,
  );
  const config = await readFile(
    join(
      sourceDirectory,
      "Packages/ExtensionMarketplace/Sources/ExtensionMarketplace/MarketplaceConfiguration.swift",
    ),
    "utf8",
  );
  const keys = [
    ...config.matchAll(
      /publicKey\s*=\s*Data\(base64Encoded:\s*"([A-Za-z0-9+/=]+)"/g,
    ),
  ];
  assert.equal(keys.length, 1);
  const publicKey = keys[0][1];
  const catalog = JSON.parse(verifiedCatalogPayload(envelopeBytes, publicKey));
  assert.equal(catalog.revision, pointer.revision);
  const current = currentPackages(catalog, definitions, fingerprints),
    packages = [],
    archives = {};
  const lineages = new Map(),
    nativeLinks = [];
  async function signedAsset(item, name, fileName, maximum, expected) {
    const assets = item.assets.filter((asset) => asset.name === name);
    assert.equal(assets.length, 1);
    const asset = assets[0];
    assert(
      Number.isSafeInteger(asset.size) &&
        asset.size > 0 &&
        asset.size <= maximum,
    );
    assert.match(asset.digest, /^sha256:[a-f0-9]{64}$/);
    const pin = { bytes: asset.size, sha256: asset.digest.slice(7) };
    if (expected) assert.deepEqual(pin, expected);
    const path = join(work, fileName);
    await publicAsset(item, name, pin.bytes, pin.sha256, path);
    return { path, bytes: await readFile(path), pin };
  }
  for (const package_ of current) {
    const tag = decodeURIComponent(
      new URL(package_.downloadURL).pathname.split("/").at(-2),
    );
    const item = await api(`/releases/tags/${encodeURIComponent(tag)}`);
    assert.equal(item.tag_name, tag);
    assert.equal(item.draft, false);
    const value = await signedAsset(
      item,
      `${package_.id}.native-evidence.json`,
      `${package_.id}-lineage.json`,
      16 * 1024,
    );
    const lineage = verifiedLineage(value.bytes, publicKey, package_);
    lineages.set(package_.id, lineage);
    nativeLinks.push({
      id: package_.id,
      runID: lineage.runID,
      runAttempt: lineage.runAttempt,
      sourceCommit: lineage.sourceCommit,
      ...value.pin,
    });
  }
  const hostAdmission = hostRun({ ...host, source: options.source });
  const downloads = [];
  async function download(row, name) {
    const destination = join(work, name);
    if (row.durableURL)
      await downloadPublic({
        url: row.durableURL,
        bytes: row.artifactBytes,
        sha256: row.artifactSHA256,
        destination,
      });
    else
      await downloadCIArtifact({
        repository,
        row,
        destination,
        fetch: authenticated,
      });
    downloads.push({ name, ...row });
    return destination;
  }
  async function prepareProduction(
    value,
    sourceDirectory,
    definitions,
    fingerprints,
    name,
    origin,
  ) {
    const source = value.run.head_sha;
    assert.match(source, /^[a-f0-9]{40}$/);
    if (!origin)
      successfulRun(value.run, source, ".github/workflows/extensions.yml");
    const tag = evidenceTag(source, value.run.id, value.run.run_attempt);
    const item = await api(`/releases/tags/${encodeURIComponent(tag)}`);
    assert.equal(item.tag_name, tag);
    assert.equal(item.target_commitish, source);
    assert.equal(item.draft, false);
    const ref = await api(`/git/ref/tags/${encodeURIComponent(tag)}`);
    assert.equal(ref.object.type, "commit");
    assert.equal(ref.object.sha, source);
    const signed = await signedAsset(
      item,
      "native-evidence.json",
      `${name}-evidence.json`,
      1024 ** 2,
      origin
        ? { bytes: origin.evidenceBytes, sha256: origin.evidenceSHA256 }
        : undefined,
    );
    const payload = verifiedEvidence(signed.bytes, publicKey);
    assert.equal(payload.sourceCommit, source);
    assert.equal(payload.runID, value.run.id);
    assert.equal(payload.runAttempt, value.run.run_attempt);
    let composition;
    const compositionAssets = item.assets.filter(
      ({ name }) => name === "publication-composition.json",
    );
    assert(compositionAssets.length <= 1);
    if (compositionAssets.length) {
      const bytes = await signedAsset(
        item,
        "publication-composition.json",
        `${name}-composition.json`,
        1024 ** 2,
      );
      const raw = verifiedEnvelope(bytes.bytes, publicKey);
      composition = {
        payload: verifiedComposition(bytes.bytes, publicKey, {
          source,
          runID: value.run.id,
          attempt: value.run.run_attempt,
          records: raw.packages.map(({ package: record }) => record),
          fingerprints,
        }),
        pin: bytes.pin,
      };
    }
    if (!origin)
      assert(
        composition,
        "Current successful publication composition is required",
      );
    const storage = closedAssetInventory(
      payload,
      signed.pin,
      item.assets,
      composition?.pin,
    );
    const outer = await download(
      durableArtifact(payload, "extension-plan"),
      `${name}-plan.zip`,
    );
    const directory = join(work, `${name}-plan`);
    python(
      "extract",
      outer,
      directory,
      "plan.json",
      "previous.json",
      "previous-state.json",
    );
    const actual = document(join(directory, "plan.json"));
    const previous = document(join(directory, "previous.json"));
    const expected = await planUnpublishedExtensions(
      sourceDirectory,
      definitions,
      previous.packages,
    );
    assert.deepEqual(actual, { include: expected });
    const resume = expected.length
      ? undefined
      : {
          plan: actual,
          previous,
          state: document(join(directory, "previous-state.json")),
          definitions,
          fingerprints,
        };
    if (resume) ownedDraftResume(resume);
    const parameters = {
      ...value,
      source,
      definitions,
      fingerprints,
      plannedIDs: expected.map(({ id }) => id),
      resume,
    };
    const qualification = origin
      ? admitOriginalEvidence(
          payload,
          parameters,
          publisherStepNames(
            Bun.YAML.parse(
              await readFile(
                join(sourceDirectory, ".github/workflows/extensions.yml"),
                "utf8",
              ),
            ),
          ),
        )
      : {
          payload: admitEvidence(payload, parameters),
          originalWholeRunSucceeded: true,
          originalPublicationOnlyFailure: false,
        };
    if (!origin)
      productionRun({
        ...parameters,
        resolveArtifact: (name) => durableArtifact(payload, name),
      });
    const rows = payload.plannedIDs.map((id) => ({
      extensionID: id,
      sourceFingerprint: fingerprints[id],
      ...durableArtifact(payload, `extension-${id}`),
    }));
    const plan = {
      planSHA256: digest(await readFile(join(directory, "plan.json"))),
      plannedIDs: expected.map(({ id }) => id),
    };
    const releaseFrozen = await download(
      durableArtifact(payload, "frozen-extension-host"),
      `${name}-frozen.zip`,
    );
    const frozenDirectory = join(work, `${name}-frozen`);
    await privateDirectory(frozenDirectory);
    const frozen = JSON.parse(
      command(
        "python3",
        [
          "-B",
          join(root, "scripts/hosted-managed-views/frozen-host-artifact.py"),
          releaseFrozen,
          frozenDirectory,
          "--tree",
          "extension-release-host",
        ],
        root,
      ),
    );
    await chmod(frozen.hostBuildMetadata, 0o600);
    const metadata = document(frozen.hostBuildMetadata);
    assert.equal(metadata.sourceCommit, source);
    assert.equal(metadata.sourceTreeDirty, false);
    for (const [key, value] of Object.entries({
      configuration: "Release",
      optimization: "Osize",
      linkTimeOptimization: "full",
      architecture: "arm64",
    }))
      assert.equal(metadata[key], value);
    assert.notEqual(metadata.signature, "ad-hoc");
    const frozenSHA = digest(
      await readFile(join(frozen.hostApp, "Contents/MacOS/Edith")),
    );
    assert.equal(metadata.hostExecutableSHA256, frozenSHA);
    command(
      "codesign",
      ["--verify", "--deep", "--strict", frozen.hostApp],
      root,
    );
    return {
      value,
      source,
      plan,
      rows,
      frozen,
      frozenSHA,
      metadata,
      qualification,
      composition,
      storage,
      envelopePin: signed.pin,
    };
  }
  const currentProduction = await prepareProduction(
    production,
    sourceDirectory,
    definitions,
    fingerprints,
    "production",
  );
  const productionPlan = currentProduction.plan;
  const changed = new Set(productionPlan.plannedIDs);
  const currentKey = `${production.run.id}:${production.run.run_attempt}`;
  const requiredRetained = [...lineages.entries()].filter(
    ([, row]) => `${row.runID}:${row.runAttempt}` !== currentKey,
  );
  assert.deepEqual(
    Object.keys(options.retainedRuns).sort(),
    requiredRetained.map(([id]) => id).sort(),
  );
  for (const [id, row] of requiredRetained)
    assert.equal(options.retainedRuns[id], row.runID);
  const productionByRun = new Map([[currentKey, currentProduction]]);
  for (const [id, origin] of requiredRetained) {
    const key = `${origin.runID}:${origin.runAttempt}`;
    if (productionByRun.has(key)) continue;
    const value = await evidenceInventory(
      origin.runID,
      origin.runAttempt,
      authenticated,
    );
    assert.equal(value.run.id, origin.runID);
    assert.equal(value.run.run_attempt, origin.runAttempt);
    assert.equal(value.run.head_sha, origin.sourceCommit);
    command(
      "git",
      ["merge-base", "--is-ancestor", origin.sourceCommit, options.source],
      root,
    );
    const directory = join(work, `source-${origin.runID}-${origin.runAttempt}`);
    await privateDirectory(directory);
    command(
      "git",
      ["clone", "--shared", "--no-checkout", root, directory],
      root,
    );
    command("git", ["checkout", "--detach", origin.sourceCommit], directory);
    const priorDefinitions = JSON.parse(
      await readFile(join(directory, "Extensions/manifest.json"), "utf8"),
    );
    assert.equal(priorDefinitions.length, 39);
    const priorFingerprints = Object.fromEntries(
      await Promise.all(
        priorDefinitions.map(async (definition) => [
          definition.id,
          await extensionFingerprint(directory, definition, priorDefinitions),
        ]),
      ),
    );
    assert.equal(priorFingerprints[id], fingerprints[id]);
    productionByRun.set(
      key,
      await prepareProduction(
        value,
        directory,
        priorDefinitions,
        priorFingerprints,
        `retained-${origin.runID}-${origin.runAttempt}`,
        origin,
      ),
    );
  }
  const currentComposition = currentProduction.composition.payload;
  assert.deepEqual(
    currentComposition.packages.map(({ package: record }) => record.id).sort(),
    current.map(({ id }) => id).sort(),
  );
  const productionAdmission = current.map((record) => {
    const origin = lineages.get(record.id);
    const nativeLink = nativeLinks.find(({ id }) => id === record.id);
    const composed = currentComposition.packages.find(
      ({ package: row }) => row.id === record.id,
    );
    assert.deepEqual(composed, {
      package: record,
      lineageSHA256: nativeLink.sha256,
      lineageBytes: nativeLink.bytes,
      sourceCommit: origin.sourceCommit,
      runID: origin.runID,
      runAttempt: origin.runAttempt,
      evidenceSHA256: origin.evidenceSHA256,
      evidenceBytes: origin.evidenceBytes,
    });
    const admission = productionByRun.get(
      `${origin.runID}:${origin.runAttempt}`,
    );
    assert.equal(admission.source, origin.sourceCommit);
    assert.deepEqual(admission.envelopePin, {
      bytes: origin.evidenceBytes,
      sha256: origin.evidenceSHA256,
    });
    assert.equal(admission.metadata.sourceTreeDirty, false);
    const rows = admission.rows.filter(
      ({ extensionID }) => extensionID === record.id,
    );
    assert.equal(rows.length, 1);
    const row = rows[0];
    assert.equal(row.sourceFingerprint, fingerprints[record.id]);
    return {
      ...row,
      sourceCommit: admission.source,
      runID: origin.runID,
      runAttempt: origin.runAttempt,
      frozen: admission.frozen,
      frozenSHA: admission.frozenSHA,
      qualification:
        `${origin.runID}:${origin.runAttempt}` === currentKey
          ? "current-source-build"
          : admission.qualification.originalPublicationOnlyFailure
            ? "composed-publication-only-retry"
            : "retained-unchanged-fingerprint",
      originalWholeRunSucceeded:
        admission.qualification.originalWholeRunSucceeded,
      currentPlannedNativeValidated: changed.has(record.id),
    };
  });
  const hostBytes = await download(hostAdmission.bytes, "host-bytes.zip"),
    hostProof = await download(hostAdmission.proof, "host-proof.zip");
  python(
    "extract",
    hostBytes,
    join(work, "host-bytes"),
    "Edith.dmg",
    "appcast.xml",
    "host-release-proof.json",
    "build-metadata.json",
    "toolchain-provenance.json",
  );
  python(
    "extract",
    hostProof,
    join(work, "host-proof"),
    "host-release-proof.json",
    "build-metadata.json",
    "toolchain-provenance.json",
  );
  const proof = document(join(work, "host-proof/host-release-proof.json"));
  const hostToolchain = toolchainProvenance(
    document(join(work, "host-proof/toolchain-provenance.json")),
    options.source,
    proof.hostExecutableSHA256,
  );
  for (const name of [
    "host-release-proof.json",
    "build-metadata.json",
    "toolchain-provenance.json",
  ])
    assert.deepEqual(
      await readFile(join(work, "host-proof", name)),
      await readFile(join(work, "host-bytes", name)),
    );
  const qualification = python(
    "tag",
    root,
    options.source,
    options.tag,
    proof.version,
    proof.build,
    proof.dmgSHA256,
  );
  assert.equal(qualification.tagTargetCommit, initialMain.object.sha);
  const release = await api(`/releases/tags/${options.tag}`);
  assert.equal(release.tag_name, options.tag);
  assert.equal(release.draft, false);
  const dmgCI = await readFile(join(work, "host-bytes/Edith.dmg"));
  assert.equal(digest(dmgCI), proof.dmgSHA256);
  assert.equal(dmgCI.length, proof.dmgBytes);
  const appcastCI = await readFile(join(work, "host-bytes/appcast.xml"));
  assert.equal(digest(appcastCI), proof.appcastSHA256);
  async function publicAsset(release, name, bytes, sha256, destination) {
    const matching = release.assets.filter((asset) => asset.name === name);
    assert.equal(matching.length, 1);
    assert.equal(matching[0].size, bytes);
    const url = `https://github.com/${repository}/releases/download/${encodeURIComponent(release.tag_name)}/${name}`;
    assert.equal(matching[0].browser_download_url, url);
    if (matching[0].digest)
      assert.equal(matching[0].digest, `sha256:${sha256}`);
    return downloadPublic({ url, bytes, sha256, destination });
  }
  const dmg = join(work, "Edith.dmg"),
    appcast = join(work, "appcast.xml");
  const publicHost = [
    await publicAsset(
      release,
      "Edith.dmg",
      proof.dmgBytes,
      proof.dmgSHA256,
      dmg,
    ),
    await publicAsset(
      release,
      "appcast.xml",
      appcastCI.length,
      proof.appcastSHA256,
      appcast,
    ),
  ];
  assert.deepEqual(
    release.assets.map(({ name }) => name).sort(),
    [
      "Edith.dmg",
      "appcast.xml",
      "build-metadata.json",
      "host-release-proof.json",
      "toolchain-provenance.json",
    ].sort(),
  );
  for (const name of [
    "host-release-proof.json",
    "build-metadata.json",
    "toolchain-provenance.json",
  ]) {
    const bytes = await readFile(join(work, "host-proof", name));
    publicHost.push(
      await publicAsset(
        release,
        name,
        bytes.length,
        digest(bytes),
        join(work, `public-${name}`),
      ),
    );
  }
  for (const row of productionAdmission) {
    const definition = definitions.find(({ id }) => id === row.extensionID);
    const package_ = current.find(({ id }) => id === row.extensionID);
    const directory = join(work, row.extensionID);
    await privateDirectory(directory);
    await record(join(directory, "definition.json"), definition);
    const outer = await download(row, `${row.extensionID}-ci.zip`);
    const receipt = JSON.parse(
      command(
        "python3",
        [
          "-B",
          join(root, "scripts/hosted-managed-views/verify-package.py"),
          outer,
          directory,
          row.frozen.hostApp,
          row.sourceCommit,
          row.sourceFingerprint,
          row.frozenSHA,
        ],
        root,
        300000,
      ),
    );
    validatePackageReceipt(
      receipt,
      row,
      definition,
      row.sourceCommit,
      row.frozenSHA,
    );
    const metadataPath = join(directory, `package/${row.extensionID}.json`);
    await chmod(metadataPath, 0o600);
    const metadata = document(metadataPath);
    assert.deepEqual(metadata, package_);
    const destination = join(work, `${row.extensionID}.zip`);
    await downloadPublic({
      url: package_.downloadURL,
      bytes: package_.downloadBytes,
      sha256: package_.sha256,
      destination,
    });
    const metrics = python(
      "archive",
      destination,
      row.extensionID,
      String(package_.downloadBytes),
      package_.sha256,
    );
    assert.equal(metrics.installedBytes, package_.installedBytes);
    archives[package_.downloadURL] = destination;
    packages.push({
      ...metrics,
      version: package_.version,
      sourceFingerprint: row.sourceFingerprint,
      artifactID: row.artifactID,
      artifactRun: row.runID,
      artifactSourceCommit: row.sourceCommit,
      artifactAttempt: row.runAttempt,
      originalWholeRunSucceeded: row.originalWholeRunSucceeded,
      currentPlannedNativeValidated: row.currentPlannedNativeValidated,
      sourceQualification: row.qualification,
      sealedHostProvenanceVerified: true,
      productionSignatureVerified: true,
    });
  }
  const older = [];
  assert(options.updateIDs.every((id) => current.some((row) => row.id === id)));
  for (const package_ of current.filter(({ id }) =>
    options.updateIDs.includes(id),
  )) {
    const alternatives = catalog.packages
      .filter(
        (row) =>
          row.id === package_.id &&
          row.hostABI === package_.hostABI &&
          row.architecture === package_.architecture &&
          row.minimumSystemVersion === package_.minimumSystemVersion &&
          row.version.localeCompare(package_.version, undefined, {
            numeric: true,
          }) < 0,
      )
      .sort((a, b) =>
        a.version.localeCompare(b.version, undefined, { numeric: true }),
      );
    assert(
      alternatives.length > 0,
      `A real retained public update version is required for ${package_.id}`,
    );
    const previous = alternatives.at(-1);
    assert.notEqual(previous.sha256, package_.sha256);
    const previousTag = `extensions/${previous.id}/${previous.version}-${previous.sourceFingerprint.slice(0, 20)}`;
    assert.equal(
      previous.downloadURL,
      `https://github.com/pulkitxm/edith/releases/download/${encodeURIComponent(previousTag)}/${previous.id}.zip`,
    );
    const path = join(work, `${package_.id}-previous.zip`);
    await downloadPublic({
      url: previous.downloadURL,
      bytes: previous.downloadBytes,
      sha256: previous.sha256,
      destination: path,
    });
    const metrics = python(
      "archive",
      path,
      previous.id,
      String(previous.downloadBytes),
      previous.sha256,
    );
    assert.equal(metrics.installedBytes, previous.installedBytes);
    archives[previous.downloadURL] = path;
    older.push(previous);
  }
  const mount = join(work, "dmg-mount");
  await privateDirectory(mount);
  let hostStatic;
  let attached = false;
  try {
    command(
      "hdiutil",
      [
        "attach",
        dmg,
        "-readonly",
        "-nobrowse",
        "-noautoopen",
        "-mountpoint",
        mount,
      ],
      root,
    );
    attached = true;
    const hostRequest = join(work, "host-request.json");
    await record(hostRequest, {
      source: options.source,
      tag: options.tag,
      proof: join(work, "host-proof/host-release-proof.json"),
      metadata: join(work, "host-proof/build-metadata.json"),
      dmg,
      appcast,
      bundle: join(mount, "Edith.app"),
    });
    hostStatic = python("host", root, hostRequest);
  } finally {
    if (attached) command("hdiutil", ["detach", mount], root);
  }
  const harnessRequest = join(work, "installer-request.json");
  await record(harnessRequest, {
    catalog: envelope,
    publicKey,
    teamIdentifier: hostStatic.teamIdentifier,
    current,
    previous: older,
    archives,
    updateIDs: options.updateIDs,
    root: join(work, "installer"),
    sourceCommit: options.source,
    workflowCommit: process.env.EXPECTED_SOURCE_SHA,
  });
  command(
    "swift",
    [
      "build",
      "--package-path",
      "Packages/ExtensionMarketplace",
      "--configuration",
      "debug",
      "--jobs",
      "1",
      "--product",
      "MarketplaceHarness",
    ],
    root,
    900000,
  );
  const bin = command(
    "swift",
    [
      "build",
      "--package-path",
      "Packages/ExtensionMarketplace",
      "--configuration",
      "debug",
      "--show-bin-path",
    ],
    root,
  ).trim();
  assert(bin.startsWith(`${root}/`) && !bin.includes("\n"));
  const installer = JSON.parse(
    command(
      join(bin, "MarketplaceHarness"),
      ["verify-public-release", harnessRequest],
      root,
      3600000,
    ),
  );
  assert.equal(installer.installationVerified, true);
  assert.equal(installer.owners, 39);
  assert.equal(installer.sourceCommit, options.source);
  for (const value of [...productionByRun.values()]
    .map(({ value }) => value)
    .concat(host)) {
    const latest = await api(
      `/actions/runs/${value.run.id}/attempts/${value.run.run_attempt}`,
    );
    assert.equal(latest.status, "completed");
    assert.equal(latest.head_sha, value.run.head_sha);
    assert.equal(latest.conclusion, value.run.conclusion);
    assert.equal(latest.run_attempt, value.run.run_attempt);
  }
  assert.equal(
    (await api("/git/ref/heads/main")).object.sha,
    initialMain.object.sha,
  );
  const finalTag = await api(`/git/ref/tags/${options.tag}`);
  assert.deepEqual(finalTag.object, initialTag.object);
  const finalCatalog = await api("/releases/tags/extension-catalog-v1");
  assert.deepEqual(parseCatalogPointer(finalCatalog.body), pointer);
  clean();
  await record(join(output, "result.json"), {
    schema: 1,
    sourceCommit: options.source,
    workflowCommit: process.env.EXPECTED_SOURCE_SHA,
    tag: options.tag,
    qualification,
    packagesRun: options.packagesRun,
    hostRun: options.hostRun,
    productionPlan,
    admissionMode:
      changed.size === 39 ? "initial-full39" : "composed-selective",
    retainedPlans: [...productionByRun.values()]
      .filter((value) => value !== currentProduction)
      .map(({ source, plan, value }) => ({
        sourceCommit: source,
        runID: value.run.id,
        ...plan,
      })),
    nativeLinks,
    evidenceReleases: [...productionByRun.values()].map(
      ({ source, value, storage, qualification }) => ({
        sourceCommit: source,
        runID: value.run.id,
        runAttempt: value.run.run_attempt,
        ...storage,
        ...qualification,
        payload: undefined,
      }),
    ),
    evidenceReleaseBytes: [...productionByRun.values()].reduce(
      (sum, { storage }) => sum + storage.totalEvidenceBytes,
      0,
    ),
    nativeLinkBytes: nativeLinks.reduce((sum, { bytes }) => sum + bytes, 0),
    fingerprints,
    fingerprintSHA256: digest(Buffer.from(JSON.stringify(fingerprints))),
    artifacts: downloads,
    publicHost,
    host: hostStatic,
    hostToolchain,
    catalogRevision: pointer.revision,
    catalogSHA256: pointer.sha256,
    packages,
    installer,
    publicBytesVerified: true,
    installerStateVerified: true,
    workerFunctionalActionsVerified: false,
    managedViewsVerified: false,
    sparkleUpdateExecuted: false,
    hardwareVerified: false,
  });
}
if (process.argv[1] && resolve(process.argv[1]) === script) {
  try {
    await run();
  } catch (error) {
    process.stderr.write(
      `Public release verification rejected: ${error.message}\n`,
    );
    process.exitCode = 1;
  }
}
