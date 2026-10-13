import { test } from "bun:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import {
  chmod,
  link,
  mkdir,
  mkdtemp,
  rm,
  symlink,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import {
  managedNativeBuildSteps,
  shippingNativeTestSteps,
} from "../hosted-managed-views/native-ci-contract.mjs";
import { stagedEvidence } from "./evidence.mjs";
import {
  admitCurrentProductionNativeRun,
  boundedProductionFile,
  closedProductionAsset,
  matchingProductionCatalogRecord,
  productionVerifiedInputs,
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
