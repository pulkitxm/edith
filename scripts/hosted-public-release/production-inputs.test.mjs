import { test } from "bun:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { createHash, generateKeyPairSync, sign } from "node:crypto";
import {
  chmod,
  copyFile,
  link,
  mkdir,
  mkdtemp,
  readFile,
  rename,
  rm,
  symlink,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { catalogPointer } from "../extension-catalog-pointer.mjs";
import {
  managedNativeBuildSteps,
  shippingNativeTestSteps,
} from "../hosted-managed-views/native-ci-contract.mjs";
import { stagedEvidence } from "./evidence.mjs";
import {
  admitHostBootstrapIntent,
  retireHostBootstrapIntent,
} from "./production-bootstrap.mjs";
import {
  admitCurrentProductionNativeRun,
  boundedProductionFile,
  closedProductionAsset,
  matchingProductionCatalogRecord,
  preparePreviousHostBootstrapInputs,
  productionInputEnvironment,
  productionVerifiedInputs,
  verifiedPreviousHostBootstrapInputs,
} from "./production-inputs.mjs";

test("faked verification flags and copied capability shells never create execution authority", async () => {
  for (const fake of [
    {},
    {
      artifactVerificationExecuted: true,
      productionCompatibilityValidated: true,
    },
    { request: { source: "a".repeat(40) }, roles: [] },
  ]) {
    assert.throws(() => productionVerifiedInputs(fake));
  }
});

test("public assets bind immutable URL bytes and GitHub digest while preserving configured extension prereleases", () => {
  const tag = `extensions/keepAwake/1.0.0-${"a".repeat(20)}`;
  const asset = {
    name: "keepAwake.zip",
    size: 12,
    digest: `sha256:${"a".repeat(64)}`,
    browser_download_url: `https://github.com/pulkitxm/edith/releases/download/${encodeURIComponent(tag)}/keepAwake.zip`,
  };
  const release = {
    tag_name: tag,
    draft: false,
    prerelease: true,
    assets: [asset],
  };
  assert.equal(
    closedProductionAsset(release, asset.name).sha256,
    "a".repeat(64),
  );
  for (const edit of [
    { draft: true },
    { assets: [asset, asset] },
    { assets: [{ ...asset, digest: null }] },
    {
      assets: [
        {
          ...asset,
          browser_download_url: "https://foreign.example/package.zip",
        },
      ],
    },
  ])
    assert.throws(() =>
      closedProductionAsset({ ...release, ...edit }, asset.name),
    );
  assert.throws(() =>
    closedProductionAsset(release, asset.name, { bytes: 13 }),
  );
  assert.throws(() =>
    closedProductionAsset(release, asset.name, { sha256: "b".repeat(64) }),
  );
});

test("bounded private records reject oversized empty permissive linked symlink and FIFO files without external mutation", async () => {
  const directory = await mkdtemp(
    join(tmpdir(), "production-cohort-synthetic-"),
  );
  await chmod(directory, 0o700);
  try {
    const good = join(directory, "good");
    await writeFile(good, "synthetic", { mode: 0o600 });
    assert.equal(
      (await boundedProductionFile(good, 9)).bytes.toString(),
      "synthetic",
    );
    await assert.rejects(boundedProductionFile(good, 8));
    const empty = join(directory, "empty");
    await writeFile(empty, "", { mode: 0o600 });
    await assert.rejects(boundedProductionFile(empty, 9));
    await chmod(good, 0o644);
    await assert.rejects(boundedProductionFile(good, 9));
    await chmod(good, 0o600);
    await link(good, join(directory, "hard"));
    await assert.rejects(boundedProductionFile(good, 9));
    await rm(join(directory, "hard"));
    const linked = join(directory, "symlink");
    await symlink(good, linked);
    await assert.rejects(boundedProductionFile(linked, 9));
    const fifo = join(directory, "fifo");
    execFileSync("/usr/bin/mkfifo", [fifo]);
    await assert.rejects(boundedProductionFile(fifo, 9));
    assert.equal(
      (await boundedProductionFile(good, 9)).bytes.toString(),
      "synthetic",
    );
  } finally {
    await rm(directory, { recursive: true });
  }
});

test("only bounded owned executable files can become pinned observer implementations", async () => {
  const directory = await mkdtemp(
    join(tmpdir(), "production-executable-synthetic-"),
  );
  await chmod(directory, 0o700);
  try {
    await mkdir(join(directory, "nested"), { mode: 0o700 });
    const executable = join(directory, "nested", "program");
    await writeFile(executable, "synthetic-unexecuted-bytes", { mode: 0o700 });
    assert.equal(
      (await boundedProductionFile(executable, 100, true)).bytes.toString(),
      "synthetic-unexecuted-bytes",
    );
    await chmod(executable, 0o600);
    await assert.rejects(boundedProductionFile(executable, 100, true));
    await chmod(executable, 0o777);
    await assert.rejects(boundedProductionFile(executable, 100, true));
  } finally {
    await rm(directory, { recursive: true });
  }
});

test("large delivery bytes are hashed in bounded chunks without retaining executable or archive contents", async () => {
  const directory = await mkdtemp(
    join(tmpdir(), "production-stream-synthetic-"),
  );
  await chmod(directory, 0o700);
  try {
    const bytes = Buffer.alloc(200000, 42);
    const path = join(directory, "delivery");
    await writeFile(path, bytes, { mode: 0o600 });
    const actual = await boundedProductionFile(
      path,
      bytes.length,
      false,
      false,
    );
    assert.equal(actual.bytes, undefined);
    assert.equal(actual.byteCount, bytes.length);
    assert.equal(
      actual.sha256,
      createHash("sha256").update(bytes).digest("hex"),
    );
    await assert.rejects(
      boundedProductionFile(path, bytes.length - 1, false, false),
    );
  } finally {
    await rm(directory, { recursive: true });
  }
});

test("actual pure archive and historical release counterexamples run with script CI", () => {
  const root = join(dirname(fileURLToPath(import.meta.url)), "../..");
  execFileSync(
    "python3",
    ["-I", "-B", join(root, "scripts/test-production-static-inputs.py")],
    {
      cwd: root,
      env: {
        PATH: process.env.PATH,
        TMPDIR: tmpdir(),
        PYTHONDONTWRITEBYTECODE: "1",
      },
      timeout: 30000,
      maxBuffer: 65536,
    },
  );
});

test("selected signed catalog row must equal the immutable release record in every field", () => {
  const record = {
    id: "keepAwake",
    version: "1.0.0",
    hostABI: "edith-host-2",
    architecture: "arm64",
    sha256: "a".repeat(64),
    dependencies: [],
    installedBytes: 100,
    downloadBytes: 50,
    sourceFingerprint: "b".repeat(64),
    minimumSystemVersion: "14.0.0",
    downloadURL:
      "https://github.com/pulkitxm/edith/releases/download/synthetic/keepAwake.zip",
  };
  assert.deepEqual(
    matchingProductionCatalogRecord([{ ...record }], record),
    record,
  );
  for (const edit of [
    { dependencies: ["foreign"] },
    { installedBytes: 101 },
    { downloadBytes: 51 },
    { sourceFingerprint: "c".repeat(64) },
    { minimumSystemVersion: "26.0.0" },
    { downloadURL: "https://foreign.example/keepAwake.zip" },
    { version: "1.0.1" },
    { extraAuthority: true },
  ]) {
    assert.throws(() =>
      matchingProductionCatalogRecord([{ ...record, ...edit }], record),
    );
  }
  assert.throws(() => matchingProductionCatalogRecord([], record));
  assert.throws(() =>
    matchingProductionCatalogRecord(
      [record, { ...record, version: "1.0.1" }],
      record,
    ),
  );
});

function currentNativeFacts() {
  const source = "a".repeat(40);
  const record = {
    id: "keepAwake",
    version: "1.0.1",
    sourceFingerprint: "b".repeat(64),
  };
  const lineage = { sourceCommit: source, runID: 101, runAttempt: 1 };
  const run = {
    id: 101,
    run_attempt: 1,
    repository: { full_name: "pulkitxm/edith" },
    path: ".github/workflows/extensions.yml",
    head_sha: source,
    head_branch: "main",
    event: "workflow_dispatch",
    status: "in_progress",
    conclusion: null,
    actor: { id: 65671483 },
  };
  const jobs = [
    "plan",
    "frozen-host",
    "tests",
    "build (keepAwake)",
    "publish",
  ].map((name, index) => ({
    id: 201 + index,
    run_id: run.id,
    name,
    status: name === "publish" ? "in_progress" : "completed",
    conclusion: name === "publish" ? null : "success",
    steps: (name === "tests"
      ? shippingNativeTestSteps
      : name.startsWith("build (")
        ? managedNativeBuildSteps
        : name === "publish"
          ? ["Preserve immutable native evidence before publication"]
          : []
    ).map((name_, number) => ({
      name: name_,
      number: number + 1,
      status: name === "publish" ? "in_progress" : "completed",
      conclusion: name === "publish" ? null : "success",
    })),
  }));
  const artifacts = [
    "extension-plan",
    "frozen-extension-host",
    "extension-keepAwake",
  ].map((name, index) => ({
    name,
    id: 301 + index,
    size_in_bytes: 37,
    digest: `sha256:${"c".repeat(64)}`,
    expired: false,
    workflow_run: { id: run.id, head_sha: source },
  }));
  const environment = {
    GITHUB_ACTIONS: "true",
    RUNNER_ENVIRONMENT: "github-hosted",
    RUNNER_OS: "macOS",
    GITHUB_REF: "refs/heads/main",
    GITHUB_REPOSITORY: "pulkitxm/edith",
    GITHUB_SHA: source,
    GITHUB_RUN_ID: "101",
    GITHUB_RUN_ATTEMPT: "1",
    GITHUB_JOB: "publish",
    GITHUB_EVENT_NAME: "workflow_dispatch",
    GITHUB_ACTOR_ID: "65671483",
  };
  const facts = { run, jobs, artifacts };
  const payload = stagedEvidence({
    ...facts,
    source,
    plannedIDs: [record.id],
    fingerprints: {
      ...Object.fromEntries(
        Array.from({ length: 38 }, (_, i) => [`owner${i}`, "b".repeat(64)]),
      ),
      keepAwake: record.sourceFingerprint,
    },
    environment,
  });
  const publisher = jobs.find(({ name }) => name === "publish");
  publisher.steps[0].status = "completed";
  publisher.steps[0].conclusion = "success";
  publisher.steps.push({
    name: "Publish immutable extension releases and the signed catalog",
    number: 2,
    status: "in_progress",
    conclusion: null,
  });
  return { record, lineage, facts, payload, environment };
}

test("same-run current B requires real native staging identity while publication remains active", () => {
  const value = currentNativeFacts();
  admitCurrentProductionNativeRun(
    value.lineage,
    value.payload,
    value.facts,
    value.record,
    value.environment,
  );
  assert.throws(() => productionVerifiedInputs(value));
});

test("current staging rejects another run source actor attempt, incomplete native jobs and publisher step drift", () => {
  const changes = [
    (v) => {
      v.environment.GITHUB_RUN_ID = "102";
    },
    (v) => {
      v.environment.GITHUB_RUN_ATTEMPT = "2";
    },
    (v) => {
      v.environment.GITHUB_SHA = "f".repeat(40);
    },
    (v) => {
      v.environment.GITHUB_JOB = "tests";
    },
    (v) => {
      v.facts.run.actor.id = 1;
    },
    (v) => {
      v.facts.run.event = "push";
    },
    (v) => {
      v.facts.run.status = "completed";
    },
    (v) => {
      v.facts.jobs.find(({ name }) => name === "tests").conclusion = "failure";
    },
    (v) => {
      v.facts.jobs.find(({ name }) => name === "tests").steps[0].conclusion =
        "skipped";
    },
    (v) => {
      v.facts.jobs.find(({ name }) => name === "publish").steps[0].status =
        "in_progress";
    },
    (v) => {
      v.facts.jobs.find(({ name }) => name === "publish").steps[1].status =
        "completed";
    },
    (v) => {
      v.facts.artifacts[0].expired = true;
    },
    (v) => {
      v.payload.fingerprints.keepAwake = "f".repeat(64);
    },
    (v) => {
      v.record.version = "1.0.0";
    },
  ];
  for (const change of changes) {
    const value = currentNativeFacts();
    change(value);
    assert.throws(() =>
      admitCurrentProductionNativeRun(
        value.lineage,
        value.payload,
        value.facts,
        value.record,
        value.environment,
      ),
    );
  }
});

test("previous preparation rejects copied pending and completed-looking shells before native admission", async () => {
  for (const fake of [
    {},
    { role: "extensions", template: { schema: 2 } },
    { publicationVerified: true },
  ]) {
    await assert.rejects(preparePreviousHostBootstrapInputs(fake));
    assert.throws(() => verifiedPreviousHostBootstrapInputs(fake));
  }
});

async function withPreviousFixture(action) {
  const directory = await mkdtemp(
    join(resolve(tmpdir()), "previous-inputs-pure-"),
  );
  await chmod(directory, 0o700);
  const repository = join(directory, "repository");
  await mkdir(repository, { mode: 0o700 });
  const root = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
  const key = generateKeyPairSync("ed25519");
  const publicKey = Buffer.from(
    key.publicKey.export({ format: "jwk" }).x,
    "base64url",
  ).toString("base64");
  const hash = (value) => createHash("sha256").update(value).digest("hex");
  const envelope = (value) => {
    const bytes = Buffer.from(JSON.stringify(value));
    return Buffer.from(
      JSON.stringify({
        payload: bytes.toString("base64"),
        signature: sign(null, bytes, key.privateKey).toString("base64"),
      }),
    );
  };
  const environment = {
    HOME: process.env.HOME,
    PATH: process.env.PATH,
    TMPDIR: process.env.TMPDIR,
    GITHUB_ACTIONS: "true",
    RUNNER_ENVIRONMENT: "github-hosted",
    RUNNER_OS: "macOS",
    GITHUB_REPOSITORY: "pulkitxm/edith",
    GITHUB_REPOSITORY_ID: "1289153439",
    GITHUB_EVENT_NAME: "workflow_dispatch",
    GITHUB_REF: "refs/heads/main",
    GITHUB_RUN_ID: "13",
    GITHUB_RUN_ATTEMPT: "1",
    GITHUB_JOB: "publish",
    GITHUB_ACTOR_ID: "65671483",
    GITHUB_TOKEN: "synthetic-readonly-token",
    GH_TOKEN: "synthetic-parent-write-token",
    EXTENSION_CATALOG_PRIVATE_KEY: "synthetic-parent-private-key",
    PUBLIC_RELEASE_VERIFICATION: "1",
    PUBLISH: "true",
    REBUILD: "",
  };
  const childEnvironment = {
    PATH: process.env.PATH,
    HOME: directory,
    TMPDIR: tmpdir(),
    PYTHONDONTWRITEBYTECODE: "1",
  };
  const git = (...args) =>
    execFileSync("git", args, {
      cwd: repository,
      env: childEnvironment,
      encoding: "utf8",
      timeout: 10000,
    }).trim();
  const files = new Map();
  const metadata = new Map();
  let capability;
  const previousEnvironment = Object.fromEntries(
    Object.keys(environment).map((name) => [name, process.env[name]]),
  );
  const oldFetch = globalThis.fetch;
  try {
    for (const name of [
      "scripts/hosted-public-release",
      "Resources",
      "Casks",
      "Packages/ExtensionMarketplace/Sources/ExtensionMarketplace",
    ])
      await mkdir(join(repository, name), { recursive: true, mode: 0o700 });
    for (const name of ["production-cohort.py", "static-proof.py"])
      await copyFile(
        join(root, "scripts/hosted-public-release", name),
        join(repository, "scripts/hosted-public-release", name),
      );
    const nativeSource = await readFile(
      join(root, "scripts/hosted-public-release/production-static-inputs.py"),
      "utf8",
    );
    const start = nativeSource.indexOf("def inspect_host("),
      end = nativeSource.indexOf("def completed_host_publication(", start);
    assert(start > 0 && end > start);
    const nativeHost = `def inspect_host(directory, expected, generation, release_channel, normalized):
    assert os.environ['PUBLISH'] == 'false' and os.environ['REBUILD'] == ''
    assert 'GH_TOKEN' not in os.environ and 'EXTENSION_CATALOG_PRIVATE_KEY' not in os.environ
    identity = release_tag(ROOT, expected, generation, release_channel)
    assert STATIC.file_hash(directory / 'Edith.dmg') == {'bytes': expected['dmgBytes'], 'sha256': expected['dmgSHA256']}
    return {'generation': generation, 'tagIdentity': identity, 'role': {'role': 'host', 'executable': COHORT.EXECUTABLE, 'codeHash': 'a' * 40, 'requirement': expected['designatedRequirement']}}


`;
    let native =
      nativeSource.slice(0, start) + nativeHost + nativeSource.slice(end);
    const signingStart = native.indexOf("def signing("),
      signingEnd = native.indexOf("def historical_tag(", signingStart);
    assert(signingStart > 0 && signingEnd > signingStart);
    native =
      native.slice(0, signingStart) +
      `def signing(path, expected_team, requirement=None):
    assert os.environ['PUBLISH'] == 'false' and os.environ['REBUILD'] == ''
    assert 'GH_TOKEN' not in os.environ and 'EXTENSION_CATALOG_PRIVATE_KEY' not in os.environ
    return {'codeHash': 'a' * 40, 'requirement': 'synthetic unexecuted native signature'}


` +
      native.slice(signingEnd);
    await writeFile(
      join(
        repository,
        "scripts/hosted-public-release/production-static-inputs.py",
      ),
      native,
    );
    await writeFile(join(repository, ".gitignore"), "local/\n");
    const info = `<plist version="1.0"><dict><key>CFBundleShortVersionString</key><string>0.0.401</string><key>CFBundleVersion</key><string>1</string></dict></plist>`;
    for (const name of ["Info.plist", "HelperInfo.plist"])
      await writeFile(join(repository, "Resources", name), info);
    await writeFile(
      join(repository, "Casks/edith.rb"),
      '  version "0.0.318"\n',
    );
    await writeFile(
      join(
        repository,
        "Packages/ExtensionMarketplace/Sources/ExtensionMarketplace/MarketplaceConfiguration.swift",
      ),
      `publicKey = Data(base64Encoded: "${publicKey}")`,
    );
    git("init", "--initial-branch=main");
    git("add", ".");
    const commit = (message, parent) =>
      git(
        "-c",
        "user.name=Synthetic",
        "-c",
        "user.email=synthetic@example.invalid",
        "commit-tree",
        git("write-tree"),
        ...(parent ? ["-p", parent] : []),
        "-m",
        message,
      );
    const sourceA = commit("Synthetic previous implementation");
    git("update-ref", "refs/heads/main", sourceA);
    git("tag", "v0.0.401", sourceA);
    await writeFile(
      join(repository, "Implementation.swift"),
      "let syntheticImplementation = 2\n",
    );
    git("add", ".");
    const source = commit("Synthetic current implementation", sourceA);
    git("update-ref", "refs/heads/main", source);
    git("remote", "add", "origin", repository);
    const archiveDirectory = join(directory, "archive");
    await mkdir(archiveDirectory, { mode: 0o700 });
    const prepared = JSON.parse(
      execFileSync(
        "python3",
        [
          "-I",
          "-B",
          "-c",
          "import importlib.util,json,pathlib,sys;s=importlib.util.spec_from_file_location('cases',sys.argv[1]);m=importlib.util.module_from_spec(s);s.loader.exec_module(m);print(json.dumps(m.synthetic_archive(pathlib.Path(sys.argv[2]))['request']))",
          join(root, "scripts/test-production-static-inputs.py"),
          archiveDirectory,
        ],
        { env: childEnvironment, timeout: 10000 },
      ).toString(),
    );
    const host = prepared.hosts.previous;
    Object.assign(host, {
      source: sourceA,
      dmgSHA256: hash(Buffer.from("synthetic unexecuted DMG")),
      dmgBytes: 24,
      appcastSHA256: hash(Buffer.from("synthetic unexecuted appcast")),
    });
    files.set("Edith.dmg", Buffer.from("synthetic unexecuted DMG"));
    host.dmgBytes = files.get("Edith.dmg").length;
    files.set("appcast.xml", Buffer.from("synthetic unexecuted appcast"));
    const proof = Object.fromEntries(
      Object.entries(host).map(([name, value]) => [
        {
          source: "sourceCommit",
          designatedRequirement: "verifiedDesignatedRequirement",
        }[name] ?? name,
        value,
      ]),
    );
    files.set("host-release-proof.json", Buffer.from(JSON.stringify(proof)));
    host.proofSHA256 = hash(files.get("host-release-proof.json"));
    files.set("build-metadata.json", Buffer.from("{}"));
    files.set(
      "toolchain-provenance.json",
      Buffer.from(
        JSON.stringify({
          schema: 1,
          sourceCommit: sourceA,
          hostExecutableSHA256: host.hostExecutableSHA256,
          xcode: "Xcode 16.0\nBuild version 16A242d",
          sdk: "14.0",
          builderSignature: "ad-hoc",
        }),
      ),
    );
    files.set(
      "keepAwake.zip",
      await readFile(join(archiveDirectory, "keepAwake.zip")),
    );
    const old = prepared.packages.previous;
    const record = {
      id: old.id,
      version: old.version,
      downloadURL: old.archiveURL,
      sha256: old.archiveSHA256,
      downloadBytes: old.downloadBytes,
      installedBytes: old.installedBytes,
      sourceFingerprint: old.sourceFingerprint,
      hostABI: old.hostABI,
      architecture: old.architecture,
      minimumSystemVersion: old.minimumSystemVersion,
      dependencies: old.dependencies,
    };
    files.set("keepAwake.json", Buffer.from(JSON.stringify(record)));
    files.set(
      "keepAwake.native-evidence.json",
      envelope({
        schema: 1,
        kind: "extension-native-lineage",
        repository: "pulkitxm/edith",
        package: record,
        sourceCommit: old.source,
        runID: old.run,
        runAttempt: 1,
        evidenceTag: `extension-evidence/${old.source}/${old.run}-1`,
        evidenceSHA256: "f".repeat(64),
        evidenceBytes: 17,
      }),
    );
    const catalogBytes = envelope({
      schemaVersion: 1,
      revision: 1,
      packages: [record],
    });
    files.set("catalog-1.json", catalogBytes);
    Object.assign(prepared.catalogs.previous, catalogPointer(catalogBytes, 1));
    delete prepared.catalogs.previous.assetName;
    delete prepared.catalogs.previous.schemaVersion;
    const template = {
      ...prepared,
      schema: 2,
      source,
      hosts: {
        previous: host,
        current: {
          kind: "pending-public-host",
          source,
          run: 12,
          runAttempt: 1,
          tag: "v0.0.402",
          version: "0.0.402",
          build: 2,
        },
      },
      packages: { previous: old, current: null },
      catalogs: { previous: prepared.catalogs.previous, current: null },
    };
    environment.GITHUB_SHA = source;
    previousEnvironment.GITHUB_SHA = process.env.GITHUB_SHA;
    const run = (id, sha, path, active = false) => ({
      id,
      run_attempt: 1,
      repository: { full_name: "pulkitxm/edith", id: 1289153439 },
      actor: { id: 65671483 },
      head_sha: sha,
      head_branch: "main",
      event: "workflow_dispatch",
      path,
      status: active ? "in_progress" : "completed",
      conclusion: active ? null : "success",
    });
    metadata.set(
      "/actions/runs/12",
      run(12, source, ".github/workflows/ci.yml", true),
    );
    metadata.set(
      "/actions/runs/13",
      run(13, source, ".github/workflows/extensions.yml", true),
    );
    metadata.set("/git/ref/heads/main", {
      ref: "refs/heads/main",
      object: { type: "commit", sha: source },
    });
    metadata.set(
      "/actions/runs/1",
      run(1, sourceA, ".github/workflows/ci.yml"),
    );
    metadata.set(
      `/actions/runs/${old.run}`,
      run(old.run, old.source, ".github/workflows/extensions.yml"),
    );
    metadata.set("/actions/runs/1/attempts/1/jobs?per_page=100", {
      total_count: 2,
      jobs: ["Build DMG", "Publish release"].map((name, index) => ({
        id: 101 + index,
        run_id: 1,
        run_attempt: 1,
        head_sha: sourceA,
        name,
        status: "completed",
        conclusion: "success",
      })),
    });
    const release = (tag, names, target) => ({
      id: metadata.size + 100,
      tag_name: tag,
      target_commitish: target,
      draft: false,
      prerelease: true,
      assets: names.map((name, index) => ({
        id: metadata.size * 10 + index + 1,
        name,
        size: files.get(name).length,
        digest: `sha256:${hash(files.get(name))}`,
        state: "uploaded",
        browser_download_url: `https://github.com/pulkitxm/edith/releases/download/${encodeURIComponent(tag)}/${name}`,
        download_count: 0,
      })),
    });
    metadata.set("/git/ref/tags/v0.0.401", {
      object: { type: "commit", sha: sourceA },
    });
    metadata.set(
      "/releases/tags/v0.0.401",
      release(
        "v0.0.401",
        [
          "Edith.dmg",
          "appcast.xml",
          "build-metadata.json",
          "host-release-proof.json",
          "toolchain-provenance.json",
        ],
        sourceA,
      ),
    );
    metadata.set(
      `/releases/tags/${encodeURIComponent(decodeURIComponent(new URL(old.archiveURL).pathname.split("/").at(-2)))}`,
      release(
        decodeURIComponent(new URL(old.archiveURL).pathname.split("/").at(-2)),
        ["keepAwake.json", "keepAwake.native-evidence.json", "keepAwake.zip"],
        old.source,
      ),
    );
    metadata.set("/releases/tags/extension-catalog-v1", {
      ...release("extension-catalog-v1", ["catalog-1.json"], source),
      body: JSON.stringify(catalogPointer(catalogBytes, 1)),
    });
    const fetchMetadata = async (path) => {
      assert(metadata.has(path), path);
      return structuredClone(metadata.get(path));
    };
    capability = await admitHostBootstrapIntent(
      JSON.stringify(template),
      environment,
      { fetchMetadata },
    );
    Object.assign(process.env, environment);
    globalThis.fetch = async (url, options = {}) => {
      const parsed = new URL(url);
      if (parsed.origin === "https://api.github.com") {
        assert.equal(
          options.headers.Authorization,
          "Bearer synthetic-readonly-token",
        );
        return new Response(
          JSON.stringify(
            await fetchMetadata(
              parsed.pathname.replace("/repos/pulkitxm/edith", "") +
                parsed.search,
            ),
          ),
        );
      }
      assert.equal(parsed.origin, "https://github.com");
      const name = parsed.pathname.split("/").at(-1);
      assert(files.has(name), name);
      return new Response(files.get(name));
    };
    const original = join(
      root,
      "scripts/hosted-public-release/production-inputs.mjs",
    );
    let code = await readFile(original, "utf8");
    code = code.replace(
      'const root = resolve(dirname(fileURLToPath(import.meta.url)), "../..");',
      `const root = ${JSON.stringify(repository)};`,
    );
    code = code.replace(
      '  assert.equal(process.platform, "darwin");\n  assert.equal(process.arch, "arm64");',
      '  assert.equal(process.env.RUNNER_OS, "macOS");',
    );
    code = code.replace(/from "(\.[^"]+)"/g, (match, relative) =>
      match.replace(
        relative,
        pathToFileURL(resolve(dirname(original), relative)).href,
      ),
    );
    const snapshot = join(directory, "producer.mjs");
    await writeFile(snapshot, code, { mode: 0o600 });
    const producer = await import(pathToFileURL(snapshot).href);
    await action({
      producer,
      capability,
      metadata,
      files,
      repository,
      template,
    });
  } finally {
    if (capability) retireHostBootstrapIntent(capability);
    globalThis.fetch = oldFetch;
    for (const [name, value] of Object.entries(previousEnvironment)) {
      if (value === undefined) delete process.env[name];
      else process.env[name] = value;
    }
    await rm(directory, { recursive: true, force: true });
  }
}

test("actual previous opaque preparation verifies real API signed catalog and ZIP without current authority", async () => {
  await withPreviousFixture(
    async ({ producer, capability, template, metadata }) => {
      const partial =
          await producer.preparePreviousHostBootstrapInputs(capability),
        value = producer.verifiedPreviousHostBootstrapInputs(partial);
      assert.deepEqual(Object.keys(value.hosts), ["previous"]);
      assert.deepEqual(Object.keys(value.packages), ["previous"]);
      assert.equal(value.template.hosts.current.kind, "pending-public-host");
      assert.equal(value.template.packages.current, null);
      assert.equal(
        value.hosts.previous.tagIdentity.sourceCommit,
        template.hosts.previous.source,
      );
      assert.equal(
        value.packages.previous.metrics.sha256,
        template.packages.previous.archiveSHA256,
      );
      assert.equal(process.env.GITHUB_TOKEN, "synthetic-readonly-token");
      assert.equal(process.env.GH_TOKEN, "synthetic-parent-write-token");
      assert.throws(() => producer.productionVerifiedInputs(partial));
      assert.throws(() => productionVerifiedInputs(partial));
      assert.throws(() =>
        producer.verifiedPreviousHostBootstrapInputs({ ...partial }),
      );
      metadata.get("/actions/runs/1").repository.open_issues_count = 999;
      metadata.get("/actions/runs/1").repository.stargazers_count = 999;
      metadata.get("/releases/tags/v0.0.401").assets[0].download_count = 999;
      metadata.get("/releases/tags/v0.0.401").name =
        "Updated public description";
      await value.revalidate();
      assert.equal((await value.catalog()).selectedVersion, "1.0.0");
    },
  );
});

test.each([
  [
    "cancelled pending host",
    async ({ metadata }) => {
      metadata.get("/actions/runs/12").status = "completed";
      metadata.get("/actions/runs/12").conclusion = "cancelled";
    },
  ],
  [
    "replayed public asset",
    async ({ metadata }) => {
      metadata.get("/releases/tags/v0.0.401").assets[0].id += 100;
    },
  ],
  [
    "changed LIVE catalog",
    async ({ metadata }) => {
      metadata.get("/releases/tags/extension-catalog-v1").body = "{}";
    },
  ],
  [
    "identical bytes on a replacement inode",
    async ({ value }) => {
      const path = join(value.directory, "host-previous/Edith.dmg");
      const bytes = await readFile(path);
      await writeFile(`${path}.replacement`, bytes, { mode: 0o600 });
      await rename(`${path}.replacement`, path);
    },
  ],
  [
    "modified sealed file",
    async ({ value }) => {
      await writeFile(
        join(value.directory, "host-previous/Edith.dmg"),
        "changed",
        { mode: 0o600 },
      );
    },
  ],
])("previous input authority revokes on %s", async (_, edit) => {
  await withPreviousFixture(async (f) => {
    const partial = await f.producer.preparePreviousHostBootstrapInputs(
      f.capability,
    );
    const value = f.producer.verifiedPreviousHostBootstrapInputs(partial);
    await edit({ ...f, value });
    await assert.rejects(value.revalidate());
    assert.throws(() =>
      f.producer.verifiedPreviousHostBootstrapInputs(partial),
    );
  });
});

test.each([
  [
    "foreign original repository",
    ({ metadata }) => {
      metadata.get("/actions/runs/1").repository.id = 1;
    },
  ],
  [
    "foreign original triggering actor",
    ({ metadata }) => {
      metadata.get("/actions/runs/1").triggering_actor = { id: 1 };
    },
  ],
  [
    "invalid original run attempt",
    ({ metadata }) => {
      delete metadata.get("/actions/runs/1").run_attempt;
    },
  ],
  [
    "invalid original job ID",
    ({ metadata }) => {
      metadata.get("/actions/runs/1/attempts/1/jobs?per_page=100").jobs[0].id =
        0;
    },
  ],
  [
    "duplicate original job ID",
    ({ metadata }) => {
      const jobs = metadata.get(
        "/actions/runs/1/attempts/1/jobs?per_page=100",
      ).jobs;
      jobs[1].id = jobs[0].id;
    },
  ],
  [
    "foreign original package repository",
    ({ metadata, template }) => {
      metadata.get(
        `/actions/runs/${template.packages.previous.run}`,
      ).repository.id = 1;
    },
  ],
  [
    "failed original host job",
    ({ metadata }) => {
      metadata.get(
        "/actions/runs/1/attempts/1/jobs?per_page=100",
      ).jobs[0].conclusion = "failure";
    },
  ],
  [
    "wrong original host attempt",
    ({ metadata }) => {
      metadata.get(
        "/actions/runs/1/attempts/1/jobs?per_page=100",
      ).jobs[0].run_attempt = 2;
    },
  ],
  [
    "draft original public host",
    ({ metadata }) => {
      metadata.get("/releases/tags/v0.0.401").draft = true;
    },
  ],
  [
    "duplicate original public asset",
    ({ metadata }) => {
      const release = metadata.get("/releases/tags/v0.0.401");
      release.assets[1].id = release.assets[0].id;
    },
  ],
  [
    "wrong old native attempt",
    ({ metadata, template }) => {
      metadata.get(
        `/actions/runs/${template.packages.previous.run}`,
      ).run_attempt = 2;
    },
  ],
  [
    "unsigned native lineage",
    ({ files, metadata }) => {
      const bytes = Buffer.from(
        JSON.stringify({
          payload: Buffer.from("{}").toString("base64"),
          signature: Buffer.alloc(64).toString("base64"),
        }),
      );
      files.set("keepAwake.native-evidence.json", bytes);
      for (const release of metadata.values())
        for (const asset of release.assets ?? [])
          if (asset.name === "keepAwake.native-evidence.json") {
            asset.size = bytes.length;
            asset.digest = `sha256:${createHash("sha256").update(bytes).digest("hex")}`;
          }
    },
  ],
])("previous preparation cannot mint authority with %s", async (_, edit) => {
  await withPreviousFixture(async (f) => {
    edit(f);
    await assert.rejects(
      f.producer.preparePreviousHostBootstrapInputs(f.capability),
    );
    assert.equal(process.env.GITHUB_TOKEN, "synthetic-readonly-token");
  });
});

test("owned preparation retains same-run publication identity through actual staged-native admission", () => {
  const value = currentNativeFacts();
  const environment = productionInputEnvironment({
    ...value.environment,
    PUBLIC_RELEASE_VERIFICATION: "1",
    GITHUB_TOKEN: "synthetic-read-token",
    GH_TOKEN: "synthetic-write-token",
    EXTENSION_CATALOG_PRIVATE_KEY: "synthetic-signing-key",
    PRIVATE_FIELD: "synthetic-private",
    PUBLISH: "false",
    REBUILD: "",
  });
  admitCurrentProductionNativeRun(
    value.lineage,
    value.payload,
    value.facts,
    value.record,
    environment,
  );
  for (const key of [
    "GITHUB_TOKEN",
    "GH_TOKEN",
    "EXTENSION_CATALOG_PRIVATE_KEY",
    "PRIVATE_FIELD",
  ])
    assert.equal(environment[key], undefined);
  assert.throws(() => productionVerifiedInputs({ ...value, environment }));
  for (const [key, wrong] of [
    ["GITHUB_RUN_ID", "102"],
    ["GITHUB_RUN_ATTEMPT", "2"],
    ["GITHUB_JOB", "tests"],
  ]) {
    for (const changed of [
      { ...value.environment, [key]: wrong },
      Object.fromEntries(
        Object.entries(value.environment).filter(([name]) => name !== key),
      ),
    ])
      assert.throws(() =>
        admitCurrentProductionNativeRun(
          value.lineage,
          value.payload,
          value.facts,
          value.record,
          productionInputEnvironment(changed),
        ),
      );
  }
});
