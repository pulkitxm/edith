import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { createHash, generateKeyPairSync, sign } from "node:crypto";
import {
  chmod,
  copyFile,
  cp,
  mkdir,
  mkdtemp,
  readFile,
  realpath,
  rm,
  symlink,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { catalogPointer } from "../extension-catalog-pointer.mjs";
import { extensionChecksum } from "../extension-publish.mjs";
import { extensionReleaseTag } from "../extension-release-plan.mjs";
import {
  managedNativeBuildSteps,
  shippingNativeTestSteps,
} from "../hosted-managed-views/native-ci-contract.mjs";
import {
  closedAssetInventory,
  evidenceTag,
  nativeLineage,
  preservationStep,
  publicationStep,
  stagedEvidence,
} from "./evidence.mjs";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const hash = (bytes) => createHash("sha256").update(bytes).digest("hex");
const repositoryName = "pulkitxm/edith";

export async function orchestrationFixture(action, variant = "fixed") {
  assert(
    [
      "fixed",
      "lost-run-projection",
      "three-key-sparkle",
      "seven-stage-summary",
      "wrong-current-run",
      "child-retirement",
      "primary-native-failure",
    ].includes(variant),
  );
  const directory = await realpath(
    await mkdtemp(join(resolve(tmpdir()), "production-orchestration-pure-")),
  );
  await chmod(directory, 0o700);
  const repository = join(directory, "repository");
  const binary = join(directory, "bin");
  const home = join(directory, "account");
  for (const path of [repository, binary, home])
    await mkdir(path, { mode: 0o700 });
  await mkdir(join(home, "Library"), { mode: 0o700 });
  const childEnvironment = {
    PATH: process.env.PATH,
    HOME: home,
    TMPDIR: directory,
    PYTHONDONTWRITEBYTECODE: "1",
  };
  const git = (...args) =>
    execFileSync("git", args, {
      cwd: repository,
      env: childEnvironment,
      encoding: "utf8",
      timeout: 10000,
    }).trim();
  const keys = generateKeyPairSync("ed25519");
  const publicKey = Buffer.from(
    keys.publicKey.export({ format: "jwk" }).x,
    "base64url",
  ).toString("base64");
  const privateKey = keys.privateKey
    .export({ type: "pkcs8", format: "pem" })
    .toString();
  const envelope = (value) => {
    const bytes = Buffer.from(JSON.stringify(value));
    return Buffer.from(
      JSON.stringify({
        payload: bytes.toString("base64"),
        signature: sign(null, bytes, keys.privateKey).toString("base64"),
      }),
    );
  };
  const state = {
    repository,
    home,
    publicKey,
    privateKey,
    variant,
    next: 1000,
    releases: [],
    bytes: {},
    api: {},
    events: [],
    promotions: 0,
  };
  const stateFile = join(directory, "state.json");
  const save = () =>
    writeFile(stateFile, JSON.stringify(state), { mode: 0o600 });
  const asset = (tag, name, bytes) => {
    const id = state.next++;
    state.bytes[id] = Buffer.from(bytes).toString("base64");
    return {
      id,
      name,
      size: bytes.length,
      digest: `sha256:${hash(bytes)}`,
      state: "uploaded",
      browser_download_url: `https://github.com/${repositoryName}/releases/download/${encodeURIComponent(tag)}/${name}`,
    };
  };
  const release = (tag, source, files, prerelease = true) => {
    const value = {
      id: state.next++,
      tag_name: tag,
      target_commitish: source,
      draft: false,
      prerelease,
      assets: Object.entries(files).map(([name, bytes]) =>
        asset(tag, name, bytes),
      ),
    };
    state.releases.push(value);
    state.api[`/git/ref/tags/${encodeURIComponent(tag)}`] = {
      ref: `refs/tags/${tag}`,
      object: { type: "commit", sha: source },
    };
    return value;
  };
  try {
    for (const path of ["scripts", "Resources", "Casks"])
      await cp(join(root, path), join(repository, path), { recursive: true });
    const alter = async (path, before, after) => {
      const source = await readFile(join(repository, path), "utf8");
      assert.equal(source.split(before).length, 2);
      await writeFile(join(repository, path), source.replace(before, after));
    };
    if (variant === "lost-run-projection")
      await alter(
        "scripts/hosted-public-release/production-inputs.mjs",
        '      "GITHUB_RUN_ID",\n      "GITHUB_RUN_ATTEMPT",\n      "GITHUB_JOB",\n',
        "",
      );
    if (variant === "three-key-sparkle")
      await alter(
        "scripts/hosted-public-release/production-sparkle-inputs.py",
        "['request', 'generation', 'directory', 'releaseChannel']",
        "['request', 'generation', 'directory']",
      );
    if (variant === "seven-stage-summary") {
      await alter(
        "scripts/hosted-public-release/production-summary.mjs",
        '  "update-feed-route",\n',
        "",
      );
      await alter(
        "scripts/hosted-public-release/production-summary.mjs",
        '  "update-feed-restoration",\n',
        "",
      );
    }
    for (const path of [
      "Packages/EdithHost/Sources/EdithHostCore/HostRemoteAuthentication.swift",
      "Tests/HostedProductionUpdate/ProducerSources/ProductionHostProbe.swift",
      "Extensions/manifest.json",
    ]) {
      await mkdir(dirname(join(repository, path)), { recursive: true });
      await copyFile(join(root, path), join(repository, path));
    }
    const configuration =
      "Packages/ExtensionMarketplace/Sources/ExtensionMarketplace/MarketplaceConfiguration.swift";
    await mkdir(dirname(join(repository, configuration)), { recursive: true });
    await writeFile(
      join(repository, configuration),
      `publicKey = Data(base64Encoded: "${publicKey}")`,
    );
    await writeFile(
      join(repository, ".gitignore"),
      "local/\ndist/\nnode_modules\n",
    );
    await symlink(join(root, "node_modules"), join(repository, "node_modules"));
    const info = (version, build) =>
      `<plist version="1.0"><dict><key>CFBundleShortVersionString</key><string>${version}</string><key>CFBundleVersion</key><string>${build}</string></dict></plist>`;
    const metadata = async (version, build) => {
      for (const path of ["Resources/Info.plist", "Resources/HelperInfo.plist"])
        await writeFile(join(repository, path), info(version, build));
      await writeFile(
        join(repository, "Casks/edith.rb"),
        `  version "${version}"\n`,
      );
    };
    await metadata("0.0.401", 1);
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
    const sourceA = commit("Synthetic previous release implementation");
    git("update-ref", "refs/heads/main", sourceA);
    git("tag", "v0.0.401", sourceA);
    await metadata("0.0.402", 2);
    await writeFile(
      join(repository, "Implementation.swift"),
      "let syntheticImplementation = 2\n",
    );
    git("add", ".");
    const source = commit("Synthetic current release implementation", sourceA);
    git("update-ref", "refs/heads/main", source);
    git("tag", "v0.0.402", source);
    git("remote", "add", "origin", repository);
    state.source = source;
    const archive = join(directory, "archives");
    await mkdir(archive, { mode: 0o700 });
    const prepared = JSON.parse(
      execFileSync(
        "python3",
        [
          "-I",
          "-B",
          "-c",
          "import importlib.util,json,pathlib,sys;s=importlib.util.spec_from_file_location('cases',sys.argv[1]);m=importlib.util.module_from_spec(s);s.loader.exec_module(m);d=pathlib.Path(sys.argv[2]);a=d/'previous';a.mkdir(mode=0o700);b=d/'current';b.mkdir(mode=0o700);old=m.synthetic_archive(a)['request'];case=m.ProductionStaticInputTests();current=case.measured_context(b);print(json.dumps({'request':old,'record':current['record']}))",
          join(root, "scripts/test-production-static-inputs.py"),
          archive,
        ],
        { env: childEnvironment, timeout: 10000 },
      ).toString(),
    );
    const template = prepared.request;
    template.source = source;
    template.packages.current = null;
    template.catalogs.current = null;
    const run = (id, sha, workflow, active = false) => ({
      id,
      run_attempt: 1,
      repository: { full_name: repositoryName, id: 1289153439 },
      actor: { id: 65671483 },
      head_sha: sha,
      head_branch: "main",
      event: "workflow_dispatch",
      path: workflow,
      status: active ? "in_progress" : "completed",
      conclusion: active ? null : "success",
    });
    for (const [generation, sha, id] of [
      ["previous", sourceA, 1],
      ["current", source, 2],
    ]) {
      const host = template.hosts[generation];
      const executable = Buffer.from(
        `synthetic unexecuted ${generation} host implementation`,
      );
      const dmg = Buffer.from(`synthetic unmounted ${generation} DMG`);
      const appcast = Buffer.from(`synthetic ${generation} appcast`);
      Object.assign(host, {
        source: sha,
        run: id,
        hostExecutableSHA256: hash(executable),
        normalizedUnsignedSHA256: hash(executable),
        dmgBytes: dmg.length,
        dmgSHA256: hash(dmg),
        appcastSHA256: hash(appcast),
      });
      const proof = Object.fromEntries(
        Object.entries(host).map(([name, value]) => [
          {
            source: "sourceCommit",
            designatedRequirement: "verifiedDesignatedRequirement",
          }[name] ?? name,
          value,
        ]),
      );
      const proofBytes = Buffer.from(JSON.stringify(proof));
      host.proofSHA256 = hash(proofBytes);
      const files = {
        "Edith.dmg": dmg,
        "appcast.xml": appcast,
        "host-release-proof.json": proofBytes,
        "build-metadata.json": Buffer.from("{}"),
        "toolchain-provenance.json": Buffer.from(
          JSON.stringify({
            schema: 1,
            sourceCommit: sha,
            hostExecutableSHA256: host.hostExecutableSHA256,
            xcode: "Xcode 16.0\nBuild version 16A242d",
            sdk: "14.0",
            builderSignature: "ad-hoc",
          }),
        ),
      };
      release(host.tag, sha, files);
      state.api[`/actions/runs/${id}`] = run(
        id,
        sha,
        ".github/workflows/ci.yml",
      );
      state.api[`/actions/runs/${id}/jobs?per_page=100`] = {
        total_count: 2,
        jobs: ["Build DMG", "Publish release"].map((name, index) => ({
          id: 100 + id * 10 + index,
          run_id: id,
          name,
          status: "completed",
          conclusion: "success",
        })),
      };
      state[generation] = { host, executable: executable.toString("base64") };
    }
    const old = template.packages.previous;
    old.source = sourceA;
    old.run = 3;
    const previousBytes = await readFile(
      join(archive, "previous/keepAwake.zip"),
    );
    const previousRecord = {
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
    const oldTag = decodeURIComponent(
      new URL(old.archiveURL).pathname.split("/").at(-2),
    );
    release(oldTag, sourceA, {
      "keepAwake.zip": previousBytes,
      "keepAwake.json": Buffer.from(JSON.stringify(previousRecord)),
      "keepAwake.native-evidence.json": envelope({
        schema: 1,
        kind: "extension-native-lineage",
        repository: repositoryName,
        package: previousRecord,
        sourceCommit: sourceA,
        runID: old.run,
        runAttempt: 1,
        evidenceTag: evidenceTag(sourceA, old.run, 1),
        evidenceSHA256: "f".repeat(64),
        evidenceBytes: 17,
      }),
    });
    state.api[`/actions/runs/${old.run}`] = run(
      old.run,
      sourceA,
      ".github/workflows/extensions.yml",
    );
    const catalog = {
      schemaVersion: 1,
      revision: 1,
      packages: [previousRecord],
    };
    const catalogBytes = envelope(catalog);
    const pointer = catalogPointer(catalogBytes, 1);
    const catalogRelease = release("extension-catalog-v1", source, {
      [pointer.assetName]: catalogBytes,
    });
    catalogRelease.body = JSON.stringify(pointer);
    Object.assign(
      template.catalogs.previous,
      Object.fromEntries(
        ["revision", "sha256", "bytes"].map((name) => [name, pointer[name]]),
      ),
    );
    const output = join(repository, "dist/extensions");
    await mkdir(output, { recursive: true, mode: 0o700 });
    const record = prepared.record;
    const entry = {
      id: "keepAwake",
      version: "1.0.1",
      fingerprint: record.sourceFingerprint,
    };
    entry.tag = extensionReleaseTag(entry);
    for (const [name, bytes] of Object.entries({
      "previous.json": JSON.stringify(catalog),
      "plan.json": JSON.stringify({ include: [entry] }),
      "keepAwake.json": JSON.stringify(record),
      "keepAwake.zip.sha256": extensionChecksum(record),
    }))
      await writeFile(join(output, name), bytes, { mode: 0o600 });
    await copyFile(
      join(archive, "current/keepAwake.zip"),
      join(output, "keepAwake.zip"),
    );
    const environment = {
      ...childEnvironment,
      PATH: `${binary}:${childEnvironment.PATH}`,
      GITHUB_ACTIONS: "true",
      RUNNER_ENVIRONMENT: "github-hosted",
      RUNNER_OS: "macOS",
      GITHUB_REPOSITORY: repositoryName,
      GITHUB_REPOSITORY_ID: "1289153439",
      GITHUB_EVENT_NAME: "workflow_dispatch",
      GITHUB_REF: "refs/heads/main",
      GITHUB_SHA: source,
      GITHUB_RUN_ID: "4",
      GITHUB_RUN_ATTEMPT: "1",
      GITHUB_JOB: "publish",
      GITHUB_ACTOR_ID: "65671483",
      GITHUB_TOKEN: "synthetic-readonly-token",
      GH_TOKEN: "synthetic-publication-token",
      EXTENSION_CATALOG_PRIVATE_KEY: privateKey,
      EXTENSION_CATALOG_PUBLIC_KEY: publicKey,
      PUBLIC_RELEASE_VERIFICATION: "1",
      PUBLISH: "true",
      REBUILD: "",
    };
    const nativeRun = run(4, source, ".github/workflows/extensions.yml", true);
    const jobs = [
      "plan",
      "frozen-host",
      "tests",
      "build (keepAwake)",
      "publish",
    ].map((name, index) => ({
      id: 201 + index,
      run_id: 4,
      name,
      status: name === "publish" ? "in_progress" : "completed",
      conclusion: name === "publish" ? null : "success",
      steps: (name === "tests"
        ? shippingNativeTestSteps
        : name.startsWith("build (")
          ? managedNativeBuildSteps
          : name === "publish"
            ? [preservationStep]
            : []
      ).map((step, index) => ({
        name: step,
        number: index + 1,
        status: "completed",
        conclusion: "success",
      })),
    }));
    jobs.at(-1).steps.push({
      name: publicationStep,
      number: 2,
      status: "in_progress",
      conclusion: null,
    });
    const names = [
      "extension-plan",
      "frozen-extension-host",
      "extension-keepAwake",
    ];
    const artifactFiles = Object.fromEntries(
      names.map((name) => [
        name,
        Buffer.from(`synthetic immutable ${name} artifact`),
      ]),
    );
    const artifacts = names.map((name, index) => ({
      id: 301 + index,
      name,
      size_in_bytes: artifactFiles[name].length,
      digest: `sha256:${hash(artifactFiles[name])}`,
      expired: false,
      workflow_run: { id: 4, head_sha: source },
    }));
    const definitions = JSON.parse(
      await readFile(join(repository, "Extensions/manifest.json"), "utf8"),
    );
    assert(Array.isArray(definitions));
    const fingerprints = Object.fromEntries(
      definitions.map(({ id }) => [
        id,
        id === "keepAwake" ? record.sourceFingerprint : hash(id),
      ]),
    );
    const evidence = stagedEvidence({
      run: nativeRun,
      jobs,
      artifacts,
      source,
      plannedIDs: ["keepAwake"],
      fingerprints,
      environment,
      publisherPhase: "publication",
    });
    const evidenceBytes = envelope(evidence);
    const lineage = envelope(
      nativeLineage(record, evidence, {
        sha256: hash(evidenceBytes),
        bytes: evidenceBytes.length,
      }),
    );
    const evidenceFiles = {
      "native-evidence.json": evidenceBytes,
      ...Object.fromEntries(
        evidence.artifacts.map(({ name, assetName }) => [
          assetName,
          artifactFiles[name],
        ]),
      ),
    };
    release(evidenceTag(source, 4, 1), source, evidenceFiles);
    const preparation = {
      tag: evidenceTag(source, 4, 1),
      sourceCommit: source,
      runID: 4,
      runAttempt: 1,
      ...closedAssetInventory(evidence, {
        sha256: hash(evidenceBytes),
        bytes: evidenceBytes.length,
      }),
    };
    for (const [name, bytes] of Object.entries({
      "native-evidence.json": evidenceBytes,
      "keepAwake.native-evidence.json": lineage,
      "native-evidence-preparation.json": Buffer.from(
        JSON.stringify(preparation),
      ),
    }))
      await writeFile(join(output, name), bytes, { mode: 0o600 });
    state.api["/actions/runs/4"] = nativeRun;
    if (variant === "wrong-current-run")
      state.api["/actions/runs/4"] = { ...nativeRun, id: 5 };
    state.api["/actions/runs/4/attempts/1/jobs?per_page=100"] = {
      total_count: jobs.length,
      jobs,
    };
    state.api["/actions/runs/4/artifacts?per_page=100"] = {
      total_count: artifacts.length,
      artifacts,
    };
    state.template = template;
    await save();
    await action({
      directory,
      repository,
      binary,
      home,
      environment,
      stateFile,
      state,
      template,
      save,
    });
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
}
