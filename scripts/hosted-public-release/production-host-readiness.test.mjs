import { test } from "bun:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { generateKeyPairSync, sign } from "node:crypto";
import { catalogPointer } from "../extension-catalog-pointer.mjs";
import {
  managedNativeBuildSteps,
  shippingNativeTestSteps,
} from "../hosted-managed-views/native-ci-contract.mjs";
import { digest } from "./contract.mjs";
import {
  evidenceTag,
  nativeLineage,
  publicationComposition,
  stagedEvidence,
} from "./evidence.mjs";
import {
  admitHostBootstrapIntent,
  verifiedHostBootstrapIntent,
} from "./production-bootstrap.mjs";
import {
  hostReadinessAssetName,
  readHostReadinessBytes,
  verifyHostReadinessEnvelope,
  verifyHostReadinessNativeFacts,
  waitForStagedHostReadiness,
} from "./production-host-readiness.mjs";
import { verifiedProductionCatalog } from "./production-inputs.mjs";

const prepared = JSON.parse(
  execFileSync(
    "python3",
    [
      "-I",
      "-B",
      "-c",
      "import importlib.util,json;s=importlib.util.spec_from_file_location('cases','scripts/test-production-host-cohort.py');m=importlib.util.module_from_spec(s);s.loader.exec_module(m);print(json.dumps(m.synthetic_request()))",
    ],
    { encoding: "utf8" },
  ),
);
const source = "a".repeat(40);
const key = generateKeyPairSync("ed25519");
const publicKey = Buffer.from(
  key.publicKey.export({ format: "jwk" }).x,
  "base64url",
).toString("base64");
const envelope = (payload) => {
  const bytes = Buffer.from(JSON.stringify(payload));
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
  RUNNER_OS: "Linux",
  GITHUB_REPOSITORY: "pulkitxm/edith",
  GITHUB_REPOSITORY_ID: "1289153439",
  GITHUB_EVENT_NAME: "workflow_dispatch",
  GITHUB_REF: "refs/heads/main",
  GITHUB_SHA: source,
  GITHUB_RUN_ID: "12",
  GITHUB_RUN_ATTEMPT: "1",
  GITHUB_JOB: "publish",
  GITHUB_ACTOR_ID: "65671483",
  GITHUB_TOKEN: "synthetic-unused-token",
  PUBLIC_RELEASE_VERIFICATION: "1",
  BUILT_SHA: source,
  RELEASE_TAG: "v0.0.402",
  RELEASE_VERSION: "0.0.402",
  RELEASE_BUILD: "2",
  RELEASE_PRERELEASE: "true",
};
function fixture() {
  const bodies = new Map();
  const metadata = new Map();
  const sourceRun = (id, path) => ({
    id,
    run_attempt: 1,
    repository: { full_name: "pulkitxm/edith", id: 1289153439 },
    actor: { id: 65671483 },
    path,
    head_sha: source,
    head_branch: "main",
    event: "workflow_dispatch",
    status: "in_progress",
    conclusion: null,
  });
  const hostRun = sourceRun(12, ".github/workflows/ci.yml");
  const nativeRun = sourceRun(13, ".github/workflows/extensions.yml");
  const fingerprints = Object.fromEntries([
    ["keepAwake", "4".repeat(64)],
    ...Array.from({ length: 38 }, (_, index) => [
      `owner${index}`,
      "b".repeat(64),
    ]),
  ]);
  const old = prepared.packages.previous;
  const record = {
    id: "keepAwake",
    hostABI: "edith-host-2",
    architecture: "arm64",
    minimumSystemVersion: "14.0.0",
    dependencies: [],
    version: "1.0.1",
    sourceFingerprint: fingerprints.keepAwake,
    downloadBytes: 7,
    installedBytes: 10,
    sha256: digest(Buffer.from("fixture")),
    downloadURL: `https://github.com/pulkitxm/edith/releases/download/extensions%2FkeepAwake%2F1.0.1-${fingerprints.keepAwake.slice(0, 20)}/keepAwake.zip`,
  };
  const oldRecord = {
    ...record,
    version: "1.0.0",
    sourceFingerprint: old.sourceFingerprint,
    downloadBytes: old.downloadBytes,
    installedBytes: old.installedBytes,
    sha256: old.archiveSHA256,
    downloadURL: old.archiveURL,
  };
  const oldBytes = envelope({
    schemaVersion: 1,
    revision: 1,
    packages: [oldRecord],
  });
  const candidateBytes = envelope({
    schemaVersion: 1,
    revision: 2,
    packages: [oldRecord, record],
  });
  const previousCatalog = catalogPointer(oldBytes, 1);
  const candidateCatalog = catalogPointer(candidateBytes, 2);
  const template = {
    ...prepared,
    schema: 2,
    hosts: {
      previous: prepared.hosts.previous,
      current: {
        kind: "pending-public-host",
        source,
        run: null,
        runAttempt: null,
        tag: environment.RELEASE_TAG,
        version: environment.RELEASE_VERSION,
        build: 2,
      },
    },
    packages: { previous: old, current: null },
    catalogs: {
      previous: {
        ...prepared.catalogs.previous,
        ...Object.fromEntries(
          ["revision", "sha256", "bytes"].map((k) => [k, previousCatalog[k]]),
        ),
      },
      current: null,
    },
  };
  const jobs = [
    "plan",
    "frozen-host",
    "tests",
    "build (keepAwake)",
    "publish",
  ].map((name, index) => ({
    id: 201 + index,
    run_id: 13,
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
    ).map((name, index) => ({
      name,
      number: index + 1,
      status: "completed",
      conclusion: "success",
    })),
  }));
  jobs.at(-1).steps.push({
    name: "Publish immutable extension releases and the signed catalog",
    number: 2,
    status: "in_progress",
    conclusion: null,
  });
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
    workflow_run: { id: 13, head_sha: source },
  }));
  const payload = stagedEvidence({
    run: nativeRun,
    jobs,
    artifacts,
    source,
    plannedIDs: ["keepAwake"],
    fingerprints,
    environment: { ...environment, RUNNER_OS: "macOS", GITHUB_RUN_ID: "13" },
    publisherPhase: "publication",
  });
  const nativeBytes = envelope(payload);
  const lineagePayload = nativeLineage(record, payload, {
    sha256: digest(nativeBytes),
    bytes: nativeBytes.length,
  });
  const lineageBytes = envelope(lineagePayload);
  const compositionBytes = envelope(
    publicationComposition(
      source,
      13,
      1,
      [
        {
          package: record,
          lineageSHA256: digest(lineageBytes),
          lineageBytes: lineageBytes.length,
          sourceCommit: source,
          runID: 13,
          runAttempt: 1,
          evidenceSHA256: digest(nativeBytes),
          evidenceBytes: nativeBytes.length,
        },
      ],
      { keepAwake: record.sourceFingerprint },
    ),
  );
  let id = 400;
  const asset = (release, name, bytes) => {
    const value = {
      id: ++id,
      name,
      size: bytes.length,
      digest: `sha256:${digest(bytes)}`,
      state: "uploaded",
      browser_download_url: `https://github.com/pulkitxm/edith/releases/download/${encodeURIComponent(release.tag_name)}/${name}`,
      download_count: 0,
    };
    release.assets.push(value);
    bodies.set(value.id, bytes);
    return value;
  };
  const catalog = {
    id: 50,
    tag_name: "extension-catalog-v1",
    target_commitish: source,
    draft: false,
    prerelease: true,
    body: JSON.stringify(previousCatalog),
    assets: [],
  };
  const oldAsset = asset(catalog, previousCatalog.assetName, oldBytes);
  const candidateAsset = asset(
    catalog,
    candidateCatalog.assetName,
    candidateBytes,
  );
  const packageTag = `extensions/keepAwake/1.0.1-${record.sourceFingerprint.slice(0, 20)}`;
  const packageRelease = {
    id: 51,
    tag_name: packageTag,
    target_commitish: source,
    draft: false,
    prerelease: true,
    assets: [],
  };
  asset(packageRelease, "keepAwake.json", Buffer.from(JSON.stringify(record)));
  asset(packageRelease, "keepAwake.zip", Buffer.from("fixture"));
  asset(packageRelease, "keepAwake.native-evidence.json", lineageBytes);
  const nativeTag = evidenceTag(source, 13, 1);
  const nativeRelease = {
    id: 52,
    tag_name: nativeTag,
    target_commitish: source,
    draft: false,
    prerelease: true,
    assets: [],
  };
  const nativeAsset = asset(nativeRelease, "native-evidence.json", nativeBytes);
  const compositionAsset = asset(
    nativeRelease,
    "publication-composition.json",
    compositionBytes,
  );
  for (const row of payload.artifacts)
    nativeRelease.assets.push({
      id: ++id,
      name: row.assetName,
      size: row.artifactBytes,
      digest: `sha256:${row.artifactSHA256}`,
      state: "uploaded",
      browser_download_url: `https://github.com/pulkitxm/edith/releases/download/${encodeURIComponent(nativeTag)}/${row.assetName}`,
    });
  const descriptor = {
    schema: 1,
    purpose: "cohort-host-readiness",
    source,
    host: { ...template.hosts.current, run: 12, runAttempt: 1 },
    extensions: { run: 13, runAttempt: 1 },
    previousCatalog,
    candidateCatalog,
    package: record,
    nativeEvidence: {
      tag: nativeTag,
      sourceCommit: source,
      runID: 13,
      runAttempt: 1,
      envelopeSHA256: digest(nativeBytes),
      envelopeBytes: nativeBytes.length,
      compositionSHA256: digest(compositionBytes),
      compositionBytes: compositionBytes.length,
      releaseID: 52,
      envelopeAssetID: nativeAsset.id,
      compositionAssetID: compositionAsset.id,
    },
    catalogReleaseID: 50,
    previousAssetID: oldAsset.id,
    candidateAssetID: candidateAsset.id,
  };
  const readyAsset = asset(
    catalog,
    hostReadinessAssetName(descriptor.host),
    envelope(descriptor),
  );
  metadata.set("/actions/runs/12", hostRun);
  metadata.set("/actions/runs/13", nativeRun);
  metadata.set("/git/ref/heads/main", {
    ref: "refs/heads/main",
    object: { type: "commit", sha: source },
  });
  for (const release of [catalog, packageRelease, nativeRelease])
    metadata.set(
      `/releases/tags/${encodeURIComponent(release.tag_name)}`,
      release,
    );
  for (const tag of [packageTag, nativeTag])
    metadata.set(`/git/ref/tags/${encodeURIComponent(tag)}`, {
      ref: `refs/tags/${tag}`,
      object: { type: "commit", sha: source },
    });
  metadata.set("/actions/runs/13/attempts/1/jobs?per_page=100", {
    total_count: jobs.length,
    jobs,
  });
  metadata.set("/actions/runs/13/artifacts?per_page=100", {
    total_count: artifacts.length,
    artifacts,
  });
  const fetchMetadata = async (path) => {
    assert(metadata.has(path), path);
    return structuredClone(metadata.get(path));
  };
  const calls = [];
  const fetch_ = async (url) => {
    const path =
      new URL(url).pathname.replace("/repos/pulkitxm/edith", "") +
      new URL(url).search;
    calls.push(path);
    if (path.startsWith("/releases/assets/")) {
      const assetID = Number(path.split("/").at(-1));
      assert(bodies.has(assetID));
      for (const release of [catalog, packageRelease, nativeRelease])
        for (const row of release.assets)
          if (row.id === assetID)
            row.download_count = (row.download_count ?? 0) + 1;
      return new Response(bodies.get(assetID));
    }
    return Response.json(await fetchMetadata(path));
  };
  return {
    template,
    descriptor,
    readyAsset,
    record,
    expected: [
      {
        id: "keepAwake",
        hostABI: "edith-host-2",
        architecture: "arm64",
        minimumSystemVersion: "14.0.0",
        fingerprint: record.sourceFingerprint,
      },
    ],
    nativePayload: payload,
    nativeFacts: {
      run: nativeRun,
      jobs: { total_count: jobs.length, jobs },
      artifacts: { total_count: artifacts.length, artifacts },
    },
    fetchMetadata,
    fetch_,
    metadata,
    bodies,
    catalog,
    packageRelease,
    nativeRelease,
    calls,
  };
}
const admit = (f) =>
  admitHostBootstrapIntent(JSON.stringify(f.template), environment, {
    fetchMetadata: f.fetchMetadata,
  });
test("the public input constructor decodes actual signed catalog bytes without admitting unsigned data", () => {
  const f = fixture();
  const bytes = f.bodies.get(f.descriptor.previousAssetID);
  assert.equal(verifiedProductionCatalog(bytes, publicKey).revision, 1);
  assert.throws(() => verifiedProductionCatalog(Buffer.from("{}"), publicKey));
  const wrong = generateKeyPairSync("ed25519");
  assert.throws(() =>
    verifiedProductionCatalog(
      bytes,
      Buffer.from(
        wrong.publicKey.export({ format: "jwk" }).x,
        "base64url",
      ).toString("base64"),
    ),
  );
});
test("signed same-run staged candidate and actual native/public payload qualify readiness only", async () => {
  const f = fixture();
  const cap = await admit(f);
  const result = await waitForStagedHostReadiness(
    cap,
    f.expected,
    publicKey,
    environment,
    { fetch_: f.fetch_ },
  );
  assert.deepEqual(result, f.descriptor);
  assert.equal(result.host.kind, "pending-public-host");
  assert.equal(f.catalog.body, JSON.stringify(f.descriptor.previousCatalog));
  await assert.rejects(verifiedHostBootstrapIntent(cap).completed());
  assert(f.calls.some((path) => path.includes("attempts/1/jobs")));
  assert(f.readyAsset.download_count > 0);
});
test("signed descriptor rejects foreign source attempts pointers package and evidence identities", async () => {
  const f = fixture();
  const cap = await admit(f);
  for (const mutate of [
    (v) => {
      v.source = "b".repeat(40);
    },
    (v) => {
      v.host.run = 99;
    },
    (v) => {
      v.extensions.runAttempt = 0;
    },
    (v) => {
      v.previousCatalog.sha256 = "e".repeat(64);
    },
    (v) => {
      v.candidateCatalog.revision = 1;
    },
    (v) => {
      v.package.sourceFingerprint = "e".repeat(64);
    },
    (v) => {
      v.nativeEvidence.runID = 99;
    },
    (v) => {
      v.nativeEvidence.tag = "other";
    },
    (v) => {
      v.candidateAssetID = v.previousAssetID;
    },
    (v) => {
      v.publicationVerified = true;
    },
  ]) {
    const value = structuredClone(f.descriptor);
    mutate(value);
    assert.throws(() =>
      verifyHostReadinessEnvelope(envelope(value), publicKey, cap, f.expected),
    );
  }
  const wrong = generateKeyPairSync("ed25519");
  assert.throws(() =>
    verifyHostReadinessEnvelope(
      envelope(f.descriptor),
      Buffer.from(
        wrong.publicKey.export({ format: "jwk" }).x,
        "base64url",
      ).toString("base64"),
      cap,
      f.expected,
    ),
  );
  assert.throws(() =>
    verifyHostReadinessEnvelope(
      Buffer.alloc(16385),
      publicKey,
      cap,
      f.expected,
    ),
  );
});
test("real native facts reject failed skipped duplicated stale and canceled executions", () => {
  const f = fixture();
  verifyHostReadinessNativeFacts(f.nativePayload, f.nativeFacts);
  for (const mutate of [
    (v) => {
      v.run.run_attempt = 2;
    },
    (v) => {
      v.run.conclusion = "cancelled";
    },
    (v) => {
      v.run.actor.id = 1;
    },
    (v) => {
      v.jobs.jobs[2].conclusion = "failure";
    },
    (v) => {
      v.jobs.jobs[2].steps[0].conclusion = "skipped";
    },
    (v) => {
      v.jobs.jobs[2].steps.push({ ...v.jobs.jobs[2].steps[0] });
    },
    (v) => {
      v.jobs.jobs[1].id = v.jobs.jobs[0].id;
    },
    (v) => {
      v.artifacts.artifacts[0].expired = true;
    },
    (v) => {
      v.artifacts.artifacts[0].workflow_run.head_sha = "b".repeat(40);
    },
  ]) {
    const value = structuredClone(f.nativeFacts);
    mutate(value);
    assert.throws(() => verifyHostReadinessNativeFacts(f.nativePayload, value));
  }
});
test("current live pointer or immutable asset substitution rejects without modifying old catalog", async () => {
  for (const kind of [
    "pointer",
    "candidate",
    "record",
    "archive",
    "evidence",
    "native-tag",
  ]) {
    const f = fixture();
    const cap = await admit(f);
    if (kind === "pointer")
      f.catalog.body = JSON.stringify(f.descriptor.candidateCatalog);
    if (kind === "candidate")
      f.catalog.assets.find((a) => a.id === f.descriptor.candidateAssetID).id =
        999;
    if (kind === "record")
      f.bodies.set(f.packageRelease.assets[0].id, Buffer.from("forged-record"));
    if (kind === "archive")
      f.bodies.set(f.packageRelease.assets[1].id, Buffer.from("forged!"));
    if (kind === "evidence") f.nativeRelease.assets[0].id = 999;
    if (kind === "native-tag")
      f.metadata.get(
        `/git/ref/tags/${encodeURIComponent(f.descriptor.nativeEvidence.tag)}`,
      ).object.sha = "b".repeat(40);
    await assert.rejects(
      waitForStagedHostReadiness(cap, f.expected, publicKey, environment, {
        fetch_: f.fetch_,
      }),
    );
  }
});
test("missing descriptor consumes one original total deadline rather than resetting each poll", async () => {
  const f = fixture();
  const cap = await admit(f);
  f.catalog.assets = f.catalog.assets.filter((a) => a.id !== f.readyAsset.id);
  let time = 0;
  let polls = 0;
  await assert.rejects(
    waitForStagedHostReadiness(cap, f.expected, publicKey, environment, {
      fetch_: f.fetch_,
      timeout: 30000,
      now: () => time,
      sleep: async (duration) => {
        polls++;
        time += duration;
      },
    }),
  );
  assert.equal(time, 30000);
  assert.equal(polls, 2);
});
test("host cancellation while fetching readiness retires authority before any publication", async () => {
  const f = fixture();
  const cap = await admit(f);
  const fetch_ = async (...args) => {
    const response = await f.fetch_(...args);
    if (String(args[0]).endsWith(`/assets/${f.readyAsset.id}`))
      Object.assign(f.metadata.get("/actions/runs/12"), {
        status: "completed",
        conclusion: "cancelled",
      });
    return response;
  };
  await assert.rejects(
    waitForStagedHostReadiness(cap, f.expected, publicKey, environment, {
      fetch_,
    }),
  );
  assert.throws(() => verifiedHostBootstrapIntent(cap));
  assert.equal(f.catalog.body, JSON.stringify(f.descriptor.previousCatalog));
});
test("descriptor streams reject growth truncation digest mismatch and joined canceled readers", async () => {
  const bytes = Buffer.from("synthetic");
  const asset = {
    id: 5,
    size: bytes.length,
    digest: `sha256:${digest(bytes)}`,
  };
  for (const body of [
    Buffer.from("x"),
    Buffer.concat([bytes, Buffer.from("x")]),
    Buffer.from("different"),
  ])
    await assert.rejects(
      readHostReadinessBytes(asset, environment, () => 1000, {
        fetch_: async () => new Response(body),
      }),
    );
  let canceled = false;
  const stream = new ReadableStream({
    start(controller) {
      controller.enqueue(Buffer.alloc(20));
    },
    cancel() {
      canceled = true;
    },
  });
  await assert.rejects(
    readHostReadinessBytes(asset, environment, () => 1000, {
      fetch_: async () => new Response(stream),
    }),
  );
  assert.equal(canceled, true);
});

test("HTTP failures cancel an owned nonterminating body before rejection", async () => {
  let canceled = false;
  const stream = new ReadableStream({
    start(controller) {
      controller.enqueue(Buffer.from("synthetic error"));
    },
    cancel() {
      canceled = true;
    },
  });
  await assert.rejects(
    readHostReadinessBytes(
      { id: 1, size: 1, digest: `sha256:${"a".repeat(64)}` },
      environment,
      () => 1000,
      { fetch_: async () => new Response(stream, { status: 500 }) },
    ),
  );
  assert.equal(canceled, true);
});
