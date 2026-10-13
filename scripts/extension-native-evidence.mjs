import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import {
  chmod,
  lstat,
  mkdir,
  mkdtemp,
  readFile,
  realpath,
  rm,
  writeFile,
} from "node:fs/promises";
import { join, resolve } from "node:path";
import {
  extensionFingerprint,
  planUnpublishedExtensions,
} from "./extension-release-plan.mjs";
import {
  downloadCIArtifact,
  validatePackageReceipt,
} from "./hosted-managed-views/package-preparation.mjs";
import {
  closedJSON,
  digest,
  ownedDraftResume,
  repository,
} from "./hosted-public-release/contract.mjs";
import {
  admitOriginalEvidence,
  closedAssetInventory,
  evidenceTag,
  nativeLineage,
  publisherStepNames,
  stagedEvidence,
  verifiedComposition,
  verifiedEnvelope,
  verifiedEvidence,
} from "./hosted-public-release/evidence.mjs";
import {
  publishExtensionAssets,
  verifyImmutableReleaseAssets,
} from "./immutable-release-assets.mjs";
import { downloadReleaseAsset } from "./release-asset-read.mjs";
import {
  executeReleaseMutation,
  preflightReleaseAsset,
} from "./release-asset-upload.mjs";
import { lookupRelease } from "./release-lookup.mjs";
import {
  assertShippingExtensions,
  shippingDefinitions,
  shippingExtensionIDs,
} from "./shipping-extension-policy.mjs";

export async function withFrozenCarrierDirectory(root, artifact, operation) {
  const sourceRoot = await realpath(root);
  const local = join(sourceRoot, "local");
  await mkdir(local, { recursive: true, mode: 0o700 });
  const parent = await lstat(local);
  assert(parent.isDirectory() && parent.uid === process.getuid());
  assert.equal(parent.mode & 0o022, 0);
  assert.equal(await realpath(local), local);
  const directory = await mkdtemp(join(local, "native-evidence-carrier-"));
  await chmod(directory, 0o700);
  const owned = await lstat(directory);
  assert(owned.isDirectory() && owned.uid === process.getuid());
  assert.equal(owned.mode & 0o777, 0o700);
  assert.equal(await realpath(directory), directory);
  try {
    const restored = closedJSON(
      execFileSync(
        "python3",
        [
          "-B",
          join(
            sourceRoot,
            "scripts/hosted-managed-views/frozen-host-artifact.py",
          ),
          artifact,
          directory,
          "--tree",
          "minimal-host",
        ],
        {
          cwd: sourceRoot,
          timeout: 300000,
          maxBuffer: 8 * 1024 ** 2,
          encoding: "utf8",
        },
      ),
    );
    assert.equal(restored.hostApp, join(directory, "Edith.app"));
    assert.equal(
      restored.hostBuildMetadata,
      join(directory, "build-metadata.json"),
    );
    return await operation(directory);
  } finally {
    const current = await lstat(directory);
    assert(current.isDirectory() && current.uid === owned.uid);
    assert.equal(current.dev, owned.dev);
    assert.equal(current.ino, owned.ino);
    assert.equal(current.mode & 0o777, 0o700);
    assert.equal(await realpath(directory), directory);
    await rm(directory, { recursive: true });
  }
}

export async function readEvidenceAPI(
  path,
  fetch_,
  { allowMissing = false } = {},
) {
  assert(/^\/(?:actions\/|git\/)/.test(path));
  const response = await fetch_(
    `https://api.github.com/repos/${repository}${path}`,
    {
      signal: AbortSignal.timeout(60000),
      headers: { Accept: "application/vnd.github+json" },
    },
  );
  if (allowMissing && response.status === 404) {
    await response.body?.cancel();
    return null;
  }
  assert.equal(response.status, 200);
  const reader = response.body.getReader();
  const chunks = [];
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

export async function preserveNativeEvidenceTag({
  source,
  runID,
  attempt,
  fetchAPI,
  createTag,
}) {
  const tag = evidenceTag(source, runID, attempt);
  const path = `/git/ref/tags/${encodeURIComponent(tag)}`;
  let ref = await readEvidenceAPI(path, fetchAPI, { allowMissing: true });
  if (!ref) {
    await createTag(tag, source);
    ref = await readEvidenceAPI(path, fetchAPI);
  }
  assert.equal(ref.ref, `refs/tags/${tag}`);
  assert.equal(ref.object.type, "commit");
  assert.equal(ref.object.sha, source);
  return tag;
}

export async function evidenceInventory(runID, attempt, fetch_) {
  assert(
    Number.isSafeInteger(runID) &&
      runID > 0 &&
      Number.isSafeInteger(attempt) &&
      attempt > 0,
  );
  const run = await readEvidenceAPI(
    `/actions/runs/${runID}/attempts/${attempt}`,
    fetch_,
  );
  async function pages(kind) {
    const path =
      kind === "jobs"
        ? `/actions/runs/${runID}/attempts/${attempt}/jobs`
        : `/actions/runs/${runID}/artifacts`;
    const rows = [];
    for (let page = 1; page <= 10; page++) {
      const result = await readEvidenceAPI(
        `${path}?per_page=100&page=${page}`,
        fetch_,
      );
      assert(
        Number.isSafeInteger(result.total_count) &&
          result.total_count >= 0 &&
          result.total_count <= 1000,
      );
      assert(Array.isArray(result[kind]) && result[kind].length <= 100);
      rows.push(...result[kind]);
      if (rows.length === result.total_count) return rows;
      assert(rows.length < result.total_count && result[kind].length === 100);
    }
    throw new Error("Native evidence inventory exceeds its bound");
  }
  const [jobs, artifacts] = await Promise.all([
    pages("jobs"),
    pages("artifacts"),
  ]);
  return { run, jobs, artifacts };
}

export async function verifyOriginalNativeLineage({
  origin,
  publicKey,
  currentSource,
  currentFingerprints,
  fetchAPI,
  readRelease = lookupRelease,
  downloadAsset = downloadReleaseAsset,
  readSource = (source, path) =>
    execFileSync("git", ["show", `${source}:${path}`], {
      encoding: "utf8",
      timeout: 60000,
      maxBuffer: 1024 ** 2,
    }),
  requireAncestor = (source, current) =>
    execFileSync("git", ["merge-base", "--is-ancestor", source, current], {
      timeout: 60000,
      stdio: "ignore",
    }),
}) {
  assert.equal(
    origin.package.sourceFingerprint,
    currentFingerprints[origin.package.id],
  );
  requireAncestor(origin.sourceCommit, currentSource);
  const item = readRelease({ repository, tag: origin.evidenceTag });
  assert(item && !item.draft && item.target_commitish === origin.sourceCommit);
  const ref = await readEvidenceAPI(
    `/git/ref/tags/${encodeURIComponent(origin.evidenceTag)}`,
    fetchAPI,
  );
  assert.equal(ref.object.type, "commit");
  assert.equal(ref.object.sha, origin.sourceCommit);
  const rows = item.assets.filter(
    ({ name }) => name === "native-evidence.json",
  );
  assert.equal(rows.length, 1);
  const bytes = (
    await downloadAsset({
      repository,
      asset: rows[0],
      expectedBytes: origin.evidenceBytes,
      expectedSHA256: origin.evidenceSHA256,
      maximumBytes: 1024 ** 2,
    })
  ).data;
  const payload = verifiedEvidence(bytes, publicKey);
  assert.equal(payload.sourceCommit, origin.sourceCommit);
  assert.equal(payload.runID, origin.runID);
  assert.equal(payload.runAttempt, origin.runAttempt);
  assert(payload.plannedIDs.includes(origin.package.id));
  assert.equal(
    payload.fingerprints[origin.package.id],
    origin.package.sourceFingerprint,
  );
  const compositions = item.assets.filter(
    ({ name }) => name === "publication-composition.json",
  );
  assert(compositions.length <= 1);
  let composition;
  if (compositions.length) {
    const asset = compositions[0];
    assert.match(asset.digest, /^sha256:[a-f0-9]{64}$/);
    const result = await downloadAsset({
      repository,
      asset,
      expectedSHA256: asset.digest.slice(7),
      maximumBytes: 1024 ** 2,
    });
    const raw = verifiedEnvelope(result.data, publicKey);
    verifiedComposition(result.data, publicKey, {
      source: payload.sourceCommit,
      runID: payload.runID,
      attempt: payload.runAttempt,
      records: raw.packages.map(({ package: record }) => record),
      fingerprints: payload.fingerprints,
    });
    composition = { bytes: result.size, sha256: result.sha256 };
  }
  closedAssetInventory(
    payload,
    { bytes: bytes.length, sha256: digest(bytes) },
    item.assets,
    composition,
  );
  const value = await evidenceInventory(
    origin.runID,
    origin.runAttempt,
    fetchAPI,
  );
  return admitOriginalEvidence(
    payload,
    {
      ...value,
      source: origin.sourceCommit,
      plannedIDs: payload.plannedIDs,
      fingerprints: payload.fingerprints,
    },
    publisherStepNames(
      Bun.YAML.parse(
        readSource(origin.sourceCommit, ".github/workflows/extensions.yml"),
      ),
    ),
  );
}

export async function publishNativeEvidence({
  directory,
  target,
  include,
  publicKey,
  publishFiles,
  lookupRelease,
  mutate,
  publishDraft,
}) {
  const environment = process.env;
  assert.equal(environment.GITHUB_ACTIONS, "true");
  assert.equal(environment.RUNNER_ENVIRONMENT, "github-hosted");
  assert.equal(environment.RUNNER_OS, "macOS");
  assert.equal(process.platform, "darwin");
  assert.equal(process.arch, "arm64");
  assert.match(target, /^[a-f0-9]{40}$/);
  const token = environment.GITHUB_TOKEN;
  assert(typeof token === "string" && token.length > 0);
  const authenticated = (url, init = {}) => {
    assert.equal(new URL(url).origin, "https://api.github.com");
    return fetch(url, {
      ...init,
      headers: { ...init.headers, Authorization: `Bearer ${token}` },
    });
  };
  const root = await realpath(process.cwd());
  const command = (file, args, timeout = 300000) =>
    execFileSync(file, args, {
      cwd: root,
      timeout,
      maxBuffer: 8 * 1024 ** 2,
      encoding: "utf8",
    });
  assert.equal(command("git", ["rev-parse", "HEAD"]).trim(), target);
  assert.equal(
    command("git", ["status", "--porcelain", "--untracked-files=normal"]),
    "",
  );
  const runID = Number(environment.GITHUB_RUN_ID),
    attempt = Number(environment.GITHUB_RUN_ATTEMPT);
  const value = await evidenceInventory(runID, attempt, authenticated);
  const definitions = closedJSON(
    await readFile(join(root, "Extensions/manifest.json"), "utf8"),
    1024 ** 2,
  );
  assertShippingExtensions(include);
  const fingerprints = Object.fromEntries(
    await Promise.all(
      definitions.map(async (definition) => [
        definition.id,
        await extensionFingerprint(root, definition, definitions),
      ]),
    ),
  );
  let resume;
  if (!include.length) {
    resume = {
      plan: closedJSON(
        await readFile(resolve(directory, "plan.json"), "utf8"),
        1024 ** 2,
      ),
      previous: closedJSON(
        await readFile(resolve(directory, "previous.json"), "utf8"),
        1024 ** 2,
      ),
      state: closedJSON(
        await readFile(resolve(directory, "previous-state.json"), "utf8"),
        4096,
      ),
      definitions,
      fingerprints,
      shippingIDs: shippingExtensionIDs,
    };
    ownedDraftResume(resume);
    const { publicationPlanningState } = await import(
      "./extension-publish.mjs"
    );
    assert.deepEqual(
      await publicationPlanningState({
        repository,
        catalogTag: process.env.EXTENSION_CATALOG_TAG ?? "extension-catalog-v1",
        publicKey,
      }),
      { catalog: resume.previous, draft: true },
    );
  }
  const payload = stagedEvidence({
    ...value,
    source: target,
    plannedIDs: include.map(({ id }) => id),
    fingerprints,
    environment,
    resume,
  });
  const work = await realpath(
    await mkdtemp(
      join(await realpath(environment.RUNNER_TEMP), "native-evidence-"),
    ),
  );
  await chmod(work, 0o700);
  const python = (...args) =>
    closedJSON(
      command("python3", [
        "-B",
        join(root, "scripts/hosted-public-release/static-proof.py"),
        ...args,
      ]),
      8 * 1024 ** 2,
    );
  const files = [];
  for (const row of payload.artifacts) {
    const path = join(work, row.assetName);
    await downloadCIArtifact({
      repository,
      row,
      destination: path,
      fetch: authenticated,
    });
    files.push([path, row.assetName]);
  }
  const rowPath = (name) =>
    join(work, payload.artifacts.find((row) => row.name === name).assetName);
  const planDirectory = join(work, "plan");
  python(
    "extract",
    rowPath("extension-plan"),
    planDirectory,
    "plan.json",
    "previous.json",
    "previous-state.json",
  );
  const plan = python("document", join(planDirectory, "plan.json"));
  const previous = python("document", join(planDirectory, "previous.json"));
  assert.deepEqual(plan, { include });
  if (resume) {
    assert.deepEqual(previous, resume.previous);
    assert.deepEqual(
      python("document", join(planDirectory, "previous-state.json")),
      resume.state,
    );
  }
  assert.deepEqual(
    include,
    await planUnpublishedExtensions(
      root,
      shippingDefinitions(definitions),
      previous.packages,
    ),
  );
  const hostDirectory = join(work, "host");
  command("mkdir", ["-m", "700", hostDirectory]);
  const frozen = closedJSON(
    command("python3", [
      "-B",
      join(root, "scripts/hosted-managed-views/frozen-host-artifact.py"),
      rowPath("frozen-extension-host"),
      hostDirectory,
      "--tree",
      "extension-release-host",
    ]),
  );
  await chmod(frozen.hostBuildMetadata, 0o600);
  const metadata = python("document", frozen.hostBuildMetadata);
  assert.equal(metadata.sourceCommit, target);
  assert.equal(metadata.sourceTreeDirty, false);
  for (const [key, expected] of Object.entries({
    configuration: "Release",
    optimization: "Osize",
    linkTimeOptimization: "full",
    architecture: "arm64",
  }))
    assert.equal(metadata[key], expected);
  assert.notEqual(metadata.signature, "ad-hoc");
  const hostHash = digest(
    await readFile(join(frozen.hostApp, "Contents/MacOS/Edith")),
  );
  assert.equal(hostHash, metadata.hostExecutableSHA256);
  command("codesign", ["--verify", "--deep", "--strict", frozen.hostApp]);
  await withFrozenCarrierDirectory(
    root,
    rowPath("frozen-extension-host"),
    async (carrierDirectory) => {
      for (const entry of include) {
        const path = join(work, `verify-${entry.id}`);
        command("mkdir", ["-m", "700", path]);
        const definition = definitions.find(({ id }) => id === entry.id);
        await writeFile(
          join(path, "definition.json"),
          JSON.stringify(definition),
          {
            mode: 0o600,
            flag: "wx",
          },
        );
        const row = payload.artifacts.find(
          ({ name }) => name === `extension-${entry.id}`,
        );
        const receipt = closedJSON(
          command("python3", [
            "-B",
            join(root, "scripts/hosted-managed-views/verify-package.py"),
            rowPath(row.name),
            path,
            frozen.hostApp,
            target,
            entry.fingerprint,
            hostHash,
            "--carrier-directory",
            carrierDirectory,
          ]),
          8 * 1024 ** 2,
        );
        validatePackageReceipt(
          receipt,
          {
            ...row,
            extensionID: entry.id,
            sourceFingerprint: entry.fingerprint,
          },
          definition,
          target,
          hostHash,
        );
        await chmod(join(path, "package", `${entry.id}.json`), 0o600);
        assert.deepEqual(
          python("document", join(path, "package", `${entry.id}.json`)),
          closedJSON(
            await readFile(resolve(directory, `${entry.id}.json`), "utf8"),
            1024 ** 2,
          ),
        );
      }
    },
  );
  const payloadPath = join(work, "payload.json"),
    envelopePath = join(work, "native-evidence.json");
  await writeFile(payloadPath, JSON.stringify(payload), {
    flag: "wx",
    mode: 0o600,
  });
  command(
    "swift",
    ["scripts/extension-catalog-sign.swift", "sign", payloadPath, envelopePath],
    60000,
  );
  await chmod(envelopePath, 0o600);
  const envelope = await readFile(envelopePath);
  assert.deepEqual(verifiedEvidence(envelope, publicKey), payload);
  files.push([envelopePath, "native-evidence.json"]);
  for (const [file, name] of files)
    preflightReleaseAsset({ repository, file, name });
  const latest = await evidenceInventory(runID, attempt, authenticated);
  assert.deepEqual(
    stagedEvidence({
      ...latest,
      source: target,
      plannedIDs: payload.plannedIDs,
      fingerprints,
      environment,
      resume,
    }),
    payload,
  );
  const tag = evidenceTag(target, runID, attempt);
  let item = lookupRelease(repository, tag);
  if (item) assert(item.tag_name === tag && item.target_commitish === target);
  await preserveNativeEvidenceTag({
    source: target,
    runID,
    attempt,
    fetchAPI: authenticated,
    createTag: (name, sha) =>
      mutate("tag", "create", "--repo", repository, "--target", sha, name),
  });
  if (!item) {
    mutate(
      "release",
      "create",
      "--repo",
      repository,
      tag,
      "--target",
      target,
      "--name",
      `Extension native evidence ${runID}/${attempt}`,
      "--draft",
      "--prerelease",
      "--body",
      "Immutable native package and frozen-host evidence.",
    );
    item = lookupRelease(repository, tag);
  }
  assert(item && item.tag_name === tag && item.target_commitish === target);
  assert(
    item.assets.every(({ name }) =>
      files.some(([, expected]) => name === expected),
    ),
  );
  const publishedAssets = await publishFiles({
    repository,
    item,
    entry: { tag },
    files,
  });
  if (item.draft) await publishDraft(item.id);
  await verifyImmutableReleaseAssets({ repository, receipt: publishedAssets });
  const envelopeDigest = { bytes: envelope.length, sha256: digest(envelope) };
  await writeFile(resolve(directory, "native-evidence.json"), envelope, {
    mode: 0o600,
    flag: "wx",
  });
  for (const entry of include) {
    const record = closedJSON(
      await readFile(resolve(directory, `${entry.id}.json`), "utf8"),
      1024 ** 2,
    );
    const lineagePayload = join(work, `${entry.id}.lineage.json`);
    await writeFile(
      lineagePayload,
      JSON.stringify(nativeLineage(record, payload, envelopeDigest)),
      { mode: 0o600, flag: "wx" },
    );
    command(
      "swift",
      [
        "scripts/extension-catalog-sign.swift",
        "sign",
        lineagePayload,
        resolve(directory, `${entry.id}.native-evidence.json`),
      ],
      60000,
    );
  }
  const summary = {
    tag,
    sourceCommit: target,
    runID,
    runAttempt: attempt,
    ...closedAssetInventory(payload, envelopeDigest),
  };
  await writeFile(
    resolve(directory, "native-evidence-preparation.json"),
    JSON.stringify(summary),
    { mode: 0o600, flag: "wx" },
  );
  return summary;
}

export async function preparedNativeEvidence({
  directory,
  target,
  include,
  publicKey,
}) {
  assert.equal(process.env.GITHUB_ACTIONS, "true");
  assert.equal(process.env.RUNNER_ENVIRONMENT, "github-hosted");
  const envelope = await readFile(resolve(directory, "native-evidence.json"));
  const payload = verifiedEvidence(envelope, publicKey);
  assert.equal(payload.sourceCommit, target);
  assert.equal(String(payload.runID), process.env.GITHUB_RUN_ID);
  assert.equal(String(payload.runAttempt), process.env.GITHUB_RUN_ATTEMPT);
  assert.deepEqual(
    payload.plannedIDs,
    include.map(({ id }) => id),
  );
  for (const entry of include)
    assert.equal(payload.fingerprints[entry.id], entry.fingerprint);
  if (!include.length)
    ownedDraftResume({
      plan: closedJSON(
        await readFile(resolve(directory, "plan.json"), "utf8"),
        1024 ** 2,
      ),
      previous: closedJSON(
        await readFile(resolve(directory, "previous.json"), "utf8"),
        1024 ** 2,
      ),
      state: closedJSON(
        await readFile(resolve(directory, "previous-state.json"), "utf8"),
        4096,
      ),
      definitions: closedJSON(
        await readFile(resolve("Extensions/manifest.json"), "utf8"),
        1024 ** 2,
      ),
      fingerprints: payload.fingerprints,
      shippingIDs: shippingExtensionIDs,
    });
  const expected = {
    tag: evidenceTag(target, payload.runID, payload.runAttempt),
    sourceCommit: target,
    runID: payload.runID,
    runAttempt: payload.runAttempt,
    ...closedAssetInventory(payload, {
      bytes: envelope.length,
      sha256: digest(envelope),
    }),
  };
  assert.deepEqual(
    closedJSON(
      await readFile(
        resolve(directory, "native-evidence-preparation.json"),
        "utf8",
      ),
      1024 ** 2,
    ),
    expected,
  );
  return expected;
}

if (import.meta.main) {
  assert.equal(process.argv.length, 2);
  const directory = process.env.EXTENSION_OUTPUT ?? "dist/extensions";
  const { include } = closedJSON(
    await readFile(resolve(directory, "plan.json"), "utf8"),
    1024 ** 2,
  );
  await publishNativeEvidence({
    directory,
    target: process.env.GITHUB_SHA,
    include,
    publicKey: process.env.EXTENSION_CATALOG_PUBLIC_KEY,
    publishFiles: publishExtensionAssets,
    lookupRelease: (repository, tag) => lookupRelease({ repository, tag }),
    mutate: (...args) => executeReleaseMutation(args),
    publishDraft: (id) =>
      executeReleaseMutation([
        "release",
        "edit",
        "--repo",
        repository,
        String(id),
        "--draft",
        "false",
        "--make-latest",
        "false",
      ]),
  });
}
