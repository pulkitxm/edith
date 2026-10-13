import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { constants } from "node:fs";
import { lstat, mkdir, open, realpath } from "node:fs/promises";
import { basename, dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import {
  parseCatalogPointer,
  verifyCatalogPointerData,
} from "../extension-catalog-pointer.mjs";
import { managedAuthenticatedFetch } from "../hosted-managed-views/execution-contract.mjs";
import { verifiedCatalogPayload } from "../verify-extension-catalog.mjs";
import {
  closedJSON,
  downloadPublic,
  successfulRun,
  toolchainProvenance,
} from "./contract.mjs";
import {
  stagedEvidence,
  verifiedEvidence,
  verifiedLineage,
} from "./evidence.mjs";

export function admitCurrentProductionNativeRun(
  lineage,
  payload,
  facts,
  record,
  environment,
) {
  assert.equal(record.id, "keepAwake");
  assert.equal(record.version, "1.0.1");
  assert.equal(lineage.sourceCommit, environment.GITHUB_SHA);
  assert.equal(String(lineage.runID), environment.GITHUB_RUN_ID);
  assert.equal(String(lineage.runAttempt), environment.GITHUB_RUN_ATTEMPT);
  assert.equal(environment.GITHUB_EVENT_NAME, "workflow_dispatch");
  assert.equal(facts.run.event, "workflow_dispatch");
  assert([65671483, 320458784].includes(facts.run.actor?.id));
  assert.equal(String(facts.run.actor.id), environment.GITHUB_ACTOR_ID);
  assert.equal(payload.fingerprints.keepAwake, record.sourceFingerprint);
  const observed = stagedEvidence({
    ...facts,
    source: lineage.sourceCommit,
    plannedIDs: ["keepAwake"],
    fingerprints: payload.fingerprints,
    environment,
    publisherPhase: "publication",
  });
  assert.deepEqual(payload, observed);
}

const root = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const admitted = new WeakMap();
export async function boundedProductionFile(
  path,
  maximum,
  executable = false,
  retain = true,
) {
  assert(Number.isSafeInteger(maximum) && maximum > 0 && maximum <= 1024 ** 3);
  assert(!retain || maximum <= 16777216);
  assert.equal(await realpath(path), path);
  const handle = await open(
    path,
    constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK,
  );
  try {
    const info = await handle.stat({ bigint: true });
    assert(
      info.isFile() &&
        info.uid === BigInt(process.getuid()) &&
        info.nlink === 1n &&
        info.size > 0n &&
        info.size <= BigInt(maximum) &&
        (executable
          ? (info.mode & 0o022n) === 0n && (info.mode & 0o111n) !== 0n
          : (info.mode & 0o7777n) === 0o600n),
    );
    const buffer = Buffer.alloc(Math.min(Number(info.size) + 1, 65536));
    const checksum = createHash("sha256");
    const chunks = [];
    let used = 0;
    while (true) {
      const { bytesRead } = await handle.read(
        buffer,
        0,
        Math.min(buffer.length, Number(info.size) - used + 1),
        null,
      );
      if (bytesRead === 0) break;
      used += bytesRead;
      assert(used <= Number(info.size));
      const bytes = buffer.subarray(0, bytesRead);
      checksum.update(bytes);
      if (retain) chunks.push(Buffer.from(bytes));
    }
    assert.equal(used, Number(info.size));
    const after = await handle.stat({ bigint: true });
    for (const key of [
      "dev",
      "ino",
      "uid",
      "mode",
      "nlink",
      "size",
      "mtimeNs",
      "ctimeNs",
    ])
      assert.equal(after[key], info[key]);
    const pathInfo = await lstat(path, { bigint: true });
    for (const key of [
      "dev",
      "ino",
      "uid",
      "mode",
      "nlink",
      "size",
      "mtimeNs",
      "ctimeNs",
    ])
      assert.equal(pathInfo[key], info[key]);
    assert.equal(await realpath(path), path);
    return {
      bytes: retain ? Buffer.concat(chunks, used) : undefined,
      byteCount: used,
      sha256: checksum.digest("hex"),
      dev: info.dev,
      ino: info.ino,
    };
  } finally {
    await handle.close();
  }
}

const freeze = (value) => {
  if (value !== null && typeof value === "object") {
    for (const item of Object.values(value)) freeze(item);
    Object.freeze(value);
  }
  return value;
};
export function productionVerifiedInputs(capability) {
  const value = admitted.get(capability);
  assert(value, "Public inputs must be verified by the owned preparation");
  return value;
}
export function closedProductionAsset(release, name, expected) {
  assert.equal(release.draft, false);
  const matches = release.assets.filter((asset) => asset.name === name);
  assert.equal(matches.length, 1);
  const asset = matches[0];
  assert(
    Number.isSafeInteger(asset.size) &&
      asset.size > 0 &&
      asset.size <= 1024 ** 3,
  );
  assert.match(asset.digest, /^sha256:[a-f0-9]{64}$/);
  const actual = {
    bytes: asset.size,
    sha256: asset.digest.slice(7),
    url: asset.browser_download_url,
  };
  assert.equal(
    actual.url,
    `https://github.com/pulkitxm/edith/releases/download/${encodeURIComponent(release.tag_name)}/${name}`,
  );
  if (expected?.bytes !== undefined) assert.equal(actual.bytes, expected.bytes);
  if (expected?.sha256 !== undefined)
    assert.equal(actual.sha256, expected.sha256);
  if (expected?.url !== undefined) assert.equal(actual.url, expected.url);
  return actual;
}
export function matchingProductionCatalogRecord(records, immutable) {
  assert(Array.isArray(records) && records.length <= 1000);
  const matching = records.filter(
    (item) =>
      item.id === "keepAwake" &&
      item.hostABI === "edith-host-2" &&
      item.architecture === "arm64",
  );
  matching.sort((a, b) =>
    a.version.localeCompare(b.version, undefined, { numeric: true }),
  );
  assert(matching.length > 0);
  const selected = matching.at(-1);
  assert.deepEqual(selected, immutable);
  return selected;
}
async function privateDirectory(path) {
  await mkdir(path, { mode: 0o700 });
  const info = await lstat(path);
  assert(
    info.isDirectory() &&
      info.uid === process.getuid() &&
      (info.mode & 0o7777) === 0o700,
  );
  assert.equal(await realpath(path), path);
}
async function record(path, value) {
  const handle = await open(
    path,
    constants.O_CREAT |
      constants.O_EXCL |
      constants.O_WRONLY |
      constants.O_NOFOLLOW,
    0o600,
  );
  try {
    await handle.writeFile(JSON.stringify(value));
    await handle.sync();
  } finally {
    await handle.close();
  }
}
export async function prepareProductionInputs(text) {
  assert.equal(process.platform, "darwin");
  assert.equal(process.arch, "arm64");
  assert.equal(process.env.PUBLIC_RELEASE_VERIFICATION, "1");
  const environment = Object.fromEntries(
    [
      "HOME",
      "PATH",
      "TMPDIR",
      "DEVELOPER_DIR",
      "LANG",
      "LC_ALL",
      "GITHUB_ACTIONS",
      "RUNNER_ENVIRONMENT",
      "RUNNER_OS",
      "GITHUB_REPOSITORY",
      "GITHUB_REPOSITORY_ID",
      "GITHUB_EVENT_NAME",
      "GITHUB_REF",
      "GITHUB_SHA",
      "GITHUB_ACTOR_ID",
      "PUBLIC_RELEASE_VERIFICATION",
      "PUBLISH",
      "REBUILD",
    ]
      .filter((key) => process.env[key] !== undefined)
      .map((key) => [key, process.env[key]]),
  );
  for (const key of [
    "PYTHONPATH",
    "PYTHONHOME",
    "NODE_OPTIONS",
    "NODE_PATH",
    "CFFIXED_USER_HOME",
    "SSH_AUTH_SOCK",
  ])
    assert(process.env[key] === undefined);
  assert(!Object.keys(process.env).some((key) => key.startsWith("EDITH_")));
  assert(
    typeof text === "string" &&
      Buffer.byteLength(text) > 0 &&
      Buffer.byteLength(text) <= 65536,
  );
  const validated = execFileSync(
    "python3",
    [
      "-I",
      "-B",
      "-c",
      "import importlib.util,json,os,sys;s=importlib.util.spec_from_file_location('cohort',sys.argv[1]);m=importlib.util.module_from_spec(s);s.loader.exec_module(m);v=m.request(sys.stdin.read());m.hosted(os.environ,v['source']);print(json.dumps(v))",
      join(root, "scripts/hosted-public-release/production-cohort.py"),
    ],
    {
      cwd: root,
      env: environment,
      input: text,
      timeout: 60000,
      maxBuffer: 65536,
    },
  );
  const request = closedJSON(validated.toString(), 65536);
  assert.equal(
    execFileSync("git", ["rev-parse", "HEAD"], {
      cwd: root,
      env: environment,
      encoding: "utf8",
    }).trim(),
    request.source,
  );
  assert.equal(
    execFileSync("git", ["status", "--porcelain", "--untracked-files=normal"], {
      cwd: root,
      env: environment,
      encoding: "utf8",
    }),
    "",
  );
  await mkdir(join(root, "local"), { recursive: true });
  const directory = join(root, "local/public-host-cohort");
  await privateDirectory(directory);
  const authenticated = managedAuthenticatedFetch(process.env, fetch);
  const api = async (path) => {
    assert(
      /^\/(?:actions\/runs\/|releases\/tags\/|git\/ref\/tags\/)/.test(path),
    );
    const response = await authenticated(
      `https://api.github.com/repos/pulkitxm/edith${path}`,
      {
        signal: AbortSignal.timeout(60000),
        headers: { Accept: "application/vnd.github+json" },
      },
    );
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
    return closedJSON(Buffer.concat(chunks).toString(), 8 * 1024 ** 2);
  };
  const verifiedFiles = [];
  const download = async (release, name, target, expected) => {
    const asset = closedProductionAsset(release, name, expected);
    const maximum =
      name.endsWith(".zip") || name.endsWith(".dmg")
        ? 512 * 1024 ** 2
        : name === "keepAwake.native-evidence.json"
          ? 1024 ** 2
          : name.startsWith("catalog-")
            ? 3 * 1024 ** 2
            : 1024 ** 2;
    assert(asset.bytes <= maximum);
    await downloadPublic({ ...asset, destination: target });
    verifiedFiles.push({ target, ...asset });
    return asset;
  };
  const python = (phase, context) =>
    JSON.parse(
      execFileSync(
        "python3",
        [
          "-I",
          "-B",
          join(
            root,
            "scripts/hosted-public-release/production-static-inputs.py",
          ),
          phase,
          context,
        ],
        { cwd: root, env: environment, timeout: 300000, maxBuffer: 1024 ** 2 },
      ),
    );
  const hosts = {},
    packages = {};
  const config = execFileSync(
    "git",
    [
      "show",
      `${request.source}:Packages/ExtensionMarketplace/Sources/ExtensionMarketplace/MarketplaceConfiguration.swift`,
    ],
    { cwd: root, env: environment, encoding: "utf8" },
  );
  const keys = [
    ...config.matchAll(
      /publicKey\s*=\s*Data\(base64Encoded:\s*"([A-Za-z0-9+/=]+)"/g,
    ),
  ];
  assert.equal(keys.length, 1);
  const publicKey = keys[0][1];
  for (const generation of ["previous", "current"]) {
    const host = request.hosts[generation];
    const run = await api(`/actions/runs/${host.run}`);
    successfulRun(run, host.source, ".github/workflows/ci.yml");
    assert.equal(run.head_branch, "main");
    assert(["push", "workflow_dispatch"].includes(run.event));
    assert([65671483, 320458784].includes(run.actor.id));
    const jobs = await api(`/actions/runs/${host.run}/jobs?per_page=100`);
    assert(jobs.total_count <= 100 && jobs.jobs.length === jobs.total_count);
    for (const name of ["Build DMG", "Publish release"]) {
      const matching = jobs.jobs.filter((job) => job.name === name);
      assert.equal(matching.length, 1);
      assert.equal(matching[0].run_id, host.run);
      assert.equal(matching[0].conclusion, "success");
    }
    const ref = await api(`/git/ref/tags/${encodeURIComponent(host.tag)}`);
    assert.equal(ref.object.type, "commit");
    const release = await api(`/releases/tags/${encodeURIComponent(host.tag)}`);
    assert.equal(release.tag_name, host.tag);
    const hostDirectory = join(directory, `host-${generation}`);
    await privateDirectory(hostDirectory);
    for (const name of [
      "host-release-proof.json",
      "build-metadata.json",
      "appcast.xml",
      "toolchain-provenance.json",
    ])
      await download(
        release,
        name,
        join(hostDirectory, name),
        name === "host-release-proof.json"
          ? { sha256: host.proofSHA256 }
          : name === "appcast.xml"
            ? { sha256: host.appcastSHA256 }
            : undefined,
      );
    await download(
      release,
      basename(new URL(host.dmgURL).pathname),
      join(hostDirectory, "Edith.dmg"),
      { bytes: host.dmgBytes, sha256: host.dmgSHA256, url: host.dmgURL },
    );
    execFileSync(
      "git",
      [
        "fetch",
        "--no-tags",
        "--depth=2",
        "origin",
        `refs/tags/${host.tag}:refs/tags/${host.tag}`,
        "+refs/heads/main:refs/remotes/origin/main",
        host.source,
      ],
      { cwd: root, env: environment, timeout: 60000, stdio: "pipe" },
    );
    assert.equal(
      execFileSync("git", ["rev-parse", `refs/tags/${host.tag}`], {
        cwd: root,
        env: environment,
        encoding: "utf8",
      }).trim(),
      ref.object.sha,
    );
    const hostContext = join(hostDirectory, "context.json");
    await record(hostContext, {
      request,
      generation,
      directory: hostDirectory,
    });
    toolchainProvenance(
      closedJSON(
        (
          await boundedProductionFile(
            join(hostDirectory, "toolchain-provenance.json"),
            65536,
          )
        ).bytes.toString(),
        65536,
      ),
      host.source,
      host.hostExecutableSHA256,
    );
    hosts[generation] = python("host", hostContext);
    const item = request.packages[generation];
    const tag = decodeURIComponent(
      new URL(item.archiveURL).pathname.split("/").at(-2),
    );
    const packageRelease = await api(
      `/releases/tags/${encodeURIComponent(tag)}`,
    );
    const packageDirectory = join(directory, `package-${generation}`);
    await privateDirectory(packageDirectory);
    await download(
      packageRelease,
      "keepAwake.json",
      join(packageDirectory, "keepAwake.json"),
    );
    const record_ = closedJSON(
      (
        await boundedProductionFile(
          join(packageDirectory, "keepAwake.json"),
          65536,
        )
      ).bytes.toString(),
      65536,
    );
    for (const [key, actual] of Object.entries({
      id: item.id,
      version: item.version,
      downloadURL: item.archiveURL,
      sha256: item.archiveSHA256,
      downloadBytes: item.downloadBytes,
      installedBytes: item.installedBytes,
      sourceFingerprint: item.sourceFingerprint,
      hostABI: item.hostABI,
      architecture: item.architecture,
      minimumSystemVersion: item.minimumSystemVersion,
      dependencies: item.dependencies,
    }))
      assert.deepEqual(record_[key], actual);
    await download(
      packageRelease,
      "keepAwake.native-evidence.json",
      join(packageDirectory, "keepAwake.native-evidence.json"),
    );
    const lineage = verifiedLineage(
      (
        await boundedProductionFile(
          join(packageDirectory, "keepAwake.native-evidence.json"),
          1024 ** 2,
        )
      ).bytes,
      publicKey,
      record_,
    );
    assert.equal(lineage.sourceCommit, item.source);
    assert.equal(lineage.runID, item.run);
    const native = await api(`/actions/runs/${item.run}`);
    if (generation === "current" && native.status === "in_progress") {
      const evidenceRelease = await api(
        `/releases/tags/${encodeURIComponent(lineage.evidenceTag)}`,
      );
      assert.equal(evidenceRelease.target_commitish, item.source);
      const evidenceRef = await api(
        `/git/ref/tags/${encodeURIComponent(lineage.evidenceTag)}`,
      );
      assert.equal(evidenceRef.object.type, "commit");
      assert.equal(evidenceRef.object.sha, item.source);
      await download(
        evidenceRelease,
        "native-evidence.json",
        join(packageDirectory, "native-evidence.json"),
        {
          bytes: lineage.evidenceBytes,
          sha256: lineage.evidenceSHA256,
        },
      );
      const payload = verifiedEvidence(
        (
          await boundedProductionFile(
            join(packageDirectory, "native-evidence.json"),
            1024 ** 2,
          )
        ).bytes,
        publicKey,
      );
      const jobs = await api(
        `/actions/runs/${item.run}/attempts/${lineage.runAttempt}/jobs?per_page=100`,
      );
      const artifacts = await api(
        `/actions/runs/${item.run}/artifacts?per_page=100`,
      );
      assert.equal(jobs.total_count, jobs.jobs.length);
      assert.equal(artifacts.total_count, artifacts.artifacts.length);
      assert(jobs.jobs.length <= 100 && artifacts.artifacts.length <= 100);
      admitCurrentProductionNativeRun(
        lineage,
        payload,
        { run: native, jobs: jobs.jobs, artifacts: artifacts.artifacts },
        record_,
        environment,
      );
    } else
      successfulRun(native, item.source, ".github/workflows/extensions.yml");
    assert.equal(native.head_branch, "main");
    assert(["push", "workflow_dispatch"].includes(native.event));
    assert([65671483, 320458784].includes(native.actor.id));
    await download(
      packageRelease,
      "keepAwake.zip",
      join(packageDirectory, "keepAwake.zip"),
      {
        bytes: item.downloadBytes,
        sha256: item.archiveSHA256,
        url: item.archiveURL,
      },
    );
    const packageContext = join(packageDirectory, "context.json");
    await record(packageContext, {
      request,
      generation,
      directory: packageDirectory,
    });
    packages[generation] = {
      ...python("package", packageContext),
      catalogRecord: record_,
    };
  }
  const catalogCalls = { previous: 0, current: 0 };
  const catalog = async (generation) => {
    assert(["previous", "current"].includes(generation));
    assert(catalogCalls[generation]++ < 3);
    const release = await api("/releases/tags/extension-catalog-v1");
    const pointer = parseCatalogPointer(release.body);
    const expected = request.catalogs[generation];
    assert.equal(pointer.revision, expected.revision);
    assert.equal(pointer.sha256, expected.sha256);
    assert.equal(pointer.bytes, expected.bytes);
    const path = join(
      directory,
      `catalog-${generation}-${catalogCalls[generation]}.json`,
    );
    await download(release, pointer.assetName, path, {
      bytes: expected.bytes,
      sha256: expected.sha256,
    });
    const bytes = verifyCatalogPointerData(
      (await boundedProductionFile(path, 3 * 1024 ** 2)).bytes,
      pointer,
    );
    const value = closedJSON(
      verifiedCatalogPayload(bytes, publicKey),
      3 * 1024 ** 2,
    );
    const selected = matchingProductionCatalogRecord(
      value.packages,
      packages[generation].catalogRecord,
    );
    assert.equal(selected.version, expected.selectedVersion);
    assert.equal(selected.sha256, expected.selectedArchiveSHA256);
    return freeze({
      revision: pointer.revision,
      sha256: pointer.sha256,
      bytes: pointer.bytes,
      selectedVersion: selected.version,
      selectedArchiveSHA256: selected.sha256,
    });
  };
  await catalog("previous");
  const roles = [
    hosts.previous.role,
    hosts.current.role,
    ...Object.values(hosts).map(({ role }) => ({ ...role, role: "engine" })),
    packages.previous.managedUIRole,
    packages.current.managedUIRole,
  ];
  const revalidate = async () => {
    assert.equal(
      execFileSync("git", ["rev-parse", "HEAD"], {
        cwd: root,
        env: environment,
        encoding: "utf8",
      }).trim(),
      request.source,
    );
    assert.equal(
      execFileSync(
        "git",
        ["status", "--porcelain", "--untracked-files=normal"],
        { cwd: root, env: environment, encoding: "utf8" },
      ),
      "",
    );
    assert(verifiedFiles.length > 0 && verifiedFiles.length <= 24);
    for (const file of verifiedFiles) {
      const actual = await boundedProductionFile(
        file.target,
        file.bytes,
        false,
        false,
      );
      assert.equal(actual.byteCount, file.bytes);
      assert.equal(actual.sha256, file.sha256);
    }
  };
  await revalidate();
  const capability = Object.freeze({});
  admitted.set(
    capability,
    freeze({
      request,
      directory,
      environment,
      hosts,
      packages,
      roles,
      catalog,
      revalidate,
    }),
  );
  return capability;
}
