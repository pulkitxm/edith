import { expect, test } from "bun:test";
import { generateKeyPairSync, sign } from "node:crypto";
import {
  preserveNativeEvidenceTag,
  verifyOriginalNativeLineage,
} from "./extension-native-evidence.mjs";
import {
  managedNativeBuildSteps,
  shippingNativeTestSteps,
} from "./hosted-managed-views/native-ci-contract.mjs";
import {
  digest,
  ownedDraftResume,
  productionRun,
} from "./hosted-public-release/contract.mjs";
import {
  admitEvidence,
  admitOriginalEvidence,
  closedAssetInventory,
  durableArtifact,
  nativeLineage,
  publicationComposition,
  stagedEvidence,
  verifiedComposition,
  verifiedEvidence,
  verifiedLineage,
} from "./hosted-public-release/evidence.mjs";

const source = "a".repeat(40);
const key = generateKeyPairSync("ed25519");
const publicKey = Buffer.from(
  key.publicKey.export({ format: "jwk" }).x,
  "base64url",
).toString("base64");
function envelope(payload) {
  const bytes = Buffer.from(
    typeof payload === "string" ? payload : JSON.stringify(payload),
  );
  return Buffer.from(
    JSON.stringify({
      payload: bytes.toString("base64"),
      signature: sign(null, bytes, key.privateKey).toString("base64"),
    }),
  );
}
function fixture() {
  const fingerprints = Object.fromEntries(
    Array.from({ length: 39 }, (_, index) => [`owner${index}`, "b".repeat(64)]),
  );
  const plannedIDs = ["owner0"];
  const run = {
    id: 101,
    run_attempt: 1,
    repository: { full_name: "pulkitxm/edith" },
    path: ".github/workflows/extensions.yml",
    head_sha: source,
    head_branch: "main",
    event: "push",
    status: "in_progress",
    conclusion: null,
  };
  const jobs = [
    "plan",
    "frozen-host",
    "tests",
    "build (owner0)",
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
    "extension-owner0",
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
  };
  return {
    run,
    jobs,
    artifacts,
    source,
    plannedIDs,
    fingerprints,
    environment,
  };
}
function completed(value) {
  const jobs = value.jobs.map((job) => ({
    ...job,
    status: "completed",
    conclusion: "success",
    steps: job.steps.map((step) => ({
      ...step,
      status: "completed",
      conclusion: "success",
    })),
  }));
  jobs
    .find(({ name }) => name === "publish")
    .steps.push({
      name: "Publish immutable extension releases and the signed catalog",
      number: 2,
      status: "completed",
      conclusion: "success",
    });
  return {
    ...value,
    run: { ...value.run, status: "completed", conclusion: "success" },
    jobs,
  };
}

test("durable signed evidence preserves exact original archives after CI expiry", () => {
  const value = fixture();
  const payload = stagedEvidence(value);
  const signed = envelope(payload);
  expect(verifiedEvidence(signed, publicKey)).toEqual(payload);
  const success = completed(value);
  for (const artifacts of [
    success.artifacts.map((row) => ({ ...row, expired: true })),
    [],
  ]) {
    expect(admitEvidence(payload, { ...success, artifacts })).toEqual(payload);
    expect(durableArtifact(payload, "extension-owner0").artifactID).toBe(303);
  }
});

test("staging requires real source and attempt identity with all actual native predecessors successful", () => {
  for (const mutation of [
    (value) => {
      value.environment.GITHUB_RUN_ID = "102";
    },
    (value) => {
      value.environment.GITHUB_RUN_ATTEMPT = "2";
    },
    (value) => {
      value.run.head_sha = "d".repeat(40);
    },
    (value) => {
      value.jobs[3].steps[0].conclusion = "failure";
    },
    (value) => {
      value.jobs[2].status = "queued";
    },
    (value) => {
      value.jobs[4].conclusion = "success";
    },
    (value) => {
      value.artifacts.pop();
    },
    (value) => {
      value.artifacts[0].expired = true;
    },
    (value) => {
      value.artifacts.push({ ...value.artifacts[0], name: "private-log" });
    },
  ]) {
    const value = fixture();
    mutation(value);
    expect(() => stagedEvidence(value)).toThrow();
  }
});

test("expired artifacts never excuse corrupt signatures, changed run jobs or original hashes", () => {
  const value = fixture();
  const payload = stagedEvidence(value);
  const signed = envelope(payload);
  const corrupted = JSON.parse(signed);
  corrupted.signature = Buffer.alloc(64).toString("base64");
  expect(() =>
    verifiedEvidence(Buffer.from(JSON.stringify(corrupted)), publicKey),
  ).toThrow();
  expect(() =>
    verifiedEvidence(
      envelope(
        JSON.stringify(payload).replace(
          '"schema":1',
          '"schema":1,"\\u0073chema":1',
        ),
      ),
      publicKey,
    ),
  ).toThrow();
  for (const mutate of [
    (success) => {
      success.run.conclusion = "failure";
    },
    (success) => {
      success.run.id = 102;
    },
    (success) => {
      success.run.run_attempt = 2;
    },
    (success) => {
      success.jobs[3].id++;
    },
    (success) => {
      success.jobs[3].steps[0].number++;
    },
    (success) => {
      success.artifacts[2].digest = `sha256:${"f".repeat(64)}`;
    },
    (success) => {
      success.artifacts[2].workflow_run.head_sha = "f".repeat(40);
    },
    (success) => {
      success.fingerprints.owner0 = "f".repeat(64);
    },
  ]) {
    const success = completed(fixture());
    mutate(success);
    expect(() => admitEvidence(payload, success)).toThrow();
  }
  expect(() =>
    admitEvidence(payload, { ...completed(fixture()), run: null }),
  ).toThrow();
});

test("immutable retry lineage stays bound to old published bytes and original native run", () => {
  const payload = stagedEvidence(fixture());
  const bytes = envelope(payload);
  const record = {
    id: "owner0",
    sourceFingerprint: "b".repeat(64),
    sha256: "e".repeat(64),
    version: "1.0.0",
  };
  const link = nativeLineage(record, payload, {
    bytes: bytes.length,
    sha256: digest(bytes),
  });
  const signed = envelope(link);
  expect(verifiedLineage(signed, publicKey, record).runID).toBe(101);
  expect(() =>
    verifiedLineage(signed, publicKey, { ...record, sha256: "f".repeat(64) }),
  ).toThrow();
  expect(() =>
    verifiedLineage(
      envelope({ ...link, sourceCommit: "f".repeat(40) }),
      publicKey,
      record,
    ),
  ).toThrow();
  expect(() =>
    nativeLineage({ ...record, sourceFingerprint: "f".repeat(64) }, payload, {
      bytes: bytes.length,
      sha256: digest(bytes),
    }),
  ).toThrow();
});

test("explicit composed retry admits only publication-stage failure with exact old native identity", () => {
  const payload = stagedEvidence(fixture());
  const names = [
    "Preserve immutable native evidence before publication",
    "Publish immutable extension releases and the signed catalog",
  ];
  const failed = () => {
    const value = completed(fixture());
    value.run.conclusion = "failure";
    value.jobs[4].conclusion = "failure";
    value.jobs[4].steps[1].conclusion = "failure";
    return value;
  };
  const qualification = admitOriginalEvidence(payload, failed(), names);
  expect(qualification.originalWholeRunSucceeded).toBe(false);
  expect(qualification.originalPublicationOnlyFailure).toBe(true);
  for (const mutate of [
    (value) => {
      value.run.conclusion = "cancelled";
    },
    (value) => {
      value.run.run_attempt = 2;
    },
    (value) => {
      value.jobs[4].run_id = 102;
    },
    (value) => {
      value.run = null;
    },
    (value) => {
      value.jobs[0].conclusion = "failure";
    },
    (value) => {
      value.jobs[1].conclusion = "failure";
    },
    (value) => {
      value.jobs[2].steps[0].conclusion = "failure";
    },
    (value) => {
      value.jobs[3].steps[0].conclusion = "failure";
    },
    (value) => {
      value.jobs[4].conclusion = "timed_out";
    },
    (value) => {
      value.jobs[4].steps[0].conclusion = "failure";
    },
    (value) => {
      value.jobs[4].steps.push({
        name: "Unknown publication operation",
        number: 3,
        status: "completed",
        conclusion: "success",
      });
    },
    (value) => {
      value.jobs.pop();
    },
    (value) => {
      value.source = "f".repeat(40);
    },
    (value) => {
      value.fingerprints.owner0 = "f".repeat(64);
    },
    (value) => {
      value.artifacts[2].digest = `sha256:${"f".repeat(64)}`;
    },
  ]) {
    const value = failed();
    mutate(value);
    expect(() => admitOriginalEvidence(payload, value, names)).toThrow();
  }
});

test("signed full publication composition keeps every old package origin separate from the current successful attempt", () => {
  const value = fixture();
  const rows = Object.keys(value.fingerprints).map((id) => ({
    package: {
      id,
      sourceFingerprint: value.fingerprints[id],
      sha256: "e".repeat(64),
      version: "1.0.0",
    },
    lineageSHA256: "c".repeat(64),
    lineageBytes: 200,
    sourceCommit: "d".repeat(40),
    runID: 100,
    runAttempt: 2,
    evidenceSHA256: "f".repeat(64),
    evidenceBytes: 300,
  }));
  const payload = publicationComposition(
    source,
    101,
    3,
    rows,
    value.fingerprints,
  );
  const admission = {
    source,
    runID: 101,
    attempt: 3,
    records: rows.map(({ package: record }) => record),
    fingerprints: value.fingerprints,
  };
  expect(verifiedComposition(envelope(payload), publicKey, admission)).toEqual(
    payload,
  );
  expect(payload.packages[0].runID).toBe(100);
  expect(payload.publicationRunID).toBe(101);
  for (const changed of [
    { ...admission, source: "f".repeat(40) },
    { ...admission, runID: 102 },
    { ...admission, attempt: 4 },
    { ...admission, records: admission.records.slice(1) },
    {
      ...admission,
      fingerprints: { ...value.fingerprints, owner0: "f".repeat(64) },
    },
  ])
    expect(() =>
      verifiedComposition(envelope(payload), publicKey, changed),
    ).toThrow();
  const wrongArchive = structuredClone(admission);
  wrongArchive.records[0].sha256 = "f".repeat(64);
  expect(() =>
    verifiedComposition(envelope(payload), publicKey, wrongArchive),
  ).toThrow();
  expect(() =>
    publicationComposition(source, 101, 3, rows.slice(1), value.fingerprints),
  ).toThrow();
  const native = stagedEvidence(value);
  const failedCurrent = completed(value);
  failedCurrent.run.conclusion = "failure";
  expect(() => admitEvidence(native, failedCurrent)).toThrow();
});

test("producer retries require the original immutable API attempt and closed public evidence inventory", async () => {
  const payload = stagedEvidence(fixture());
  const bytes = envelope(payload);
  const record = {
    id: "owner0",
    sourceFingerprint: "b".repeat(64),
    sha256: "e".repeat(64),
    version: "1.0.0",
  };
  const origin = nativeLineage(record, payload, {
    bytes: bytes.length,
    sha256: digest(bytes),
  });
  const inventory = closedAssetInventory(payload, {
    bytes: bytes.length,
    sha256: digest(bytes),
  });
  const actualAssets = inventory.assets.map(
    ({ name, bytes: size, sha256 }, index) => ({
      id: 1000 + index,
      name,
      size,
      digest: `sha256:${sha256}`,
    }),
  );
  const make = () => {
    const original = completed(fixture());
    original.artifacts = [];
    original.run.conclusion = "failure";
    original.jobs[4].conclusion = "failure";
    original.jobs[4].steps[1].conclusion = "failure";
    const item = {
      draft: false,
      target_commitish: source,
      assets: structuredClone(actualAssets),
    };
    const ref = { object: { type: "commit", sha: source } };
    const responses = new Map([
      ["/actions/runs/101/attempts/1", original.run],
      [
        "/actions/runs/101/attempts/1/jobs?per_page=100&page=1",
        { total_count: 5, jobs: original.jobs },
      ],
      [
        "/actions/runs/101/artifacts?per_page=100&page=1",
        { total_count: 0, artifacts: [] },
      ],
    ]);
    let ancestor = true;
    const options = {
      origin,
      publicKey,
      currentSource: "d".repeat(40),
      currentFingerprints: fixture().fingerprints,
      fetchAPI: async (url) => {
        const path =
          new URL(url).pathname.replace("/repos/pulkitxm/edith", "") +
          new URL(url).search;
        if (path.startsWith("/git/ref/tags/")) return Response.json(ref);
        return responses.has(path)
          ? Response.json(responses.get(path))
          : new Response("", { status: 404 });
      },
      readRelease: () => item,
      downloadAsset: async ({ expectedBytes, expectedSHA256 }) => {
        expect(expectedBytes).toBe(bytes.length);
        expect(expectedSHA256).toBe(digest(bytes));
        return { data: bytes, size: bytes.length, sha256: digest(bytes) };
      },
      readSource: () =>
        "jobs:\n  publish:\n    steps:\n      - name: Preserve immutable native evidence before publication\n        run: preserve\n      - name: Publish immutable extension releases and the signed catalog\n        run: publish\n",
      requireAncestor: () => {
        if (!ancestor) throw new Error("foreign source");
      },
    };
    return {
      options,
      original,
      item,
      ref,
      responses,
      rejectAncestor: () => {
        ancestor = false;
      },
    };
  };
  expect(
    (await verifyOriginalNativeLineage(make().options))
      .originalPublicationOnlyFailure,
  ).toBe(true);
  for (const mutate of [
    (value) => value.responses.delete("/actions/runs/101/attempts/1"),
    (value) => {
      value.original.jobs[3].conclusion = "failure";
    },
    (value) => {
      value.original.jobs[1].conclusion = "cancelled";
    },
    (value) => {
      value.original.jobs[2].conclusion = "failure";
    },
    (value) => {
      value.original.run.run_attempt = 2;
    },
    (value) => {
      value.ref.object.type = "tag";
    },
    (value) => {
      value.ref.object.sha = "f".repeat(40);
    },
    (value) => {
      value.item.assets.push({
        id: 2000,
        name: "private-log.txt",
        size: 10,
        digest: `sha256:${"f".repeat(64)}`,
      });
    },
    (value) => {
      value.item.assets[0].digest = `sha256:${"f".repeat(64)}`;
    },
    (value) => {
      value.options.currentFingerprints.owner0 = "f".repeat(64);
    },
    (value) => value.rejectAncestor(),
  ]) {
    const value = make();
    mutate(value);
    await expect(verifyOriginalNativeLineage(value.options)).rejects.toThrow();
  }
});

test("closed evidence asset sizes include envelope and every preserved original archive", () => {
  const payload = stagedEvidence(fixture());
  const bytes = envelope(payload);
  const inventory = closedAssetInventory(payload, {
    bytes: bytes.length,
    sha256: digest(bytes),
  });
  expect(inventory.originalArchiveBytes).toBe(111);
  expect(inventory.totalEvidenceBytes).toBe(111 + bytes.length);
  const actual = inventory.assets.map(({ name, bytes, sha256 }) => ({
    name,
    size: bytes,
    digest: `sha256:${sha256}`,
  }));
  expect(
    closedAssetInventory(
      payload,
      { bytes: bytes.length, sha256: digest(bytes) },
      actual,
    ),
  ).toEqual(inventory);
  expect(() =>
    closedAssetInventory(
      payload,
      { bytes: bytes.length, sha256: digest(bytes) },
      actual.slice(1),
    ),
  ).toThrow();
  expect(() =>
    closedAssetInventory(
      payload,
      { bytes: bytes.length, sha256: digest(bytes) },
      [
        ...actual,
        { name: "private-log", size: 1, digest: `sha256:${"f".repeat(64)}` },
      ],
    ),
  ).toThrow();
});

test("fresh evidence drafts preserve an exact lightweight source tag before release creation", async () => {
  let ref = null;
  const writes = [];
  const tag = `extension-evidence/${source}/101-1`;
  const fetchAPI = async (url) => {
    expect(url).toBe(
      `https://api.github.com/repos/pulkitxm/edith/git/ref/tags/${encodeURIComponent(tag)}`,
    );
    return new Response(JSON.stringify(ref), { status: ref ? 200 : 404 });
  };
  const value = {
    source,
    runID: 101,
    attempt: 1,
    fetchAPI,
    createTag: async (name, sha) => {
      writes.push({ name, sha });
      ref = { ref: `refs/tags/${name}`, object: { type: "commit", sha } };
    },
  };
  expect(await preserveNativeEvidenceTag(value)).toBe(tag);
  expect(writes).toEqual([{ name: tag, sha: source }]);
  expect(await preserveNativeEvidenceTag(value)).toBe(tag);
  expect(writes).toHaveLength(1);
  for (const changed of [
    { object: { type: "tag", sha: source } },
    { object: { type: "commit", sha: "b".repeat(40) } },
    { ref: `refs/tags/${tag}-other` },
  ]) {
    ref = {
      ref: `refs/tags/${tag}`,
      object: { type: "commit", sha: source },
      ...changed,
    };
    await expect(preserveNativeEvidenceTag(value)).rejects.toThrow();
    expect(writes).toHaveLength(1);
  }
  for (const status of [401, 403, 500]) {
    await expect(
      preserveNativeEvidenceTag({
        ...value,
        fetchAPI: async () => new Response("failure", { status }),
      }),
    ).rejects.toThrow();
    expect(writes).toHaveLength(1);
  }
  await expect(
    preserveNativeEvidenceTag({
      ...value,
      fetchAPI: async () => new Response("missing", { status: 404 }),
      createTag: async () => {},
    }),
  ).rejects.toThrow();
});

function emptyDraftFixture() {
  const value = fixture();
  const definitions = Object.keys(value.fingerprints).map((id) => ({
    id,
    hostABI: "edith-host-2",
    minimumSystemVersion: "14.0.0",
    dependencies: [],
  }));
  const packages = definitions.map((definition) => ({
    ...definition,
    version: "1.0.0",
    architecture: "arm64",
    sha256: "d".repeat(64),
    sourceFingerprint: value.fingerprints[definition.id],
    downloadBytes: 1,
    installedBytes: 1,
    downloadURL: `https://github.com/pulkitxm/edith/releases/download/${encodeURIComponent(`extensions/${definition.id}/1.0.0-${value.fingerprints[definition.id].slice(0, 20)}`)}/${definition.id}.zip`,
  }));
  value.plannedIDs = [];
  value.jobs[3] = {
    id: 204,
    run_id: 101,
    name: "build",
    status: "completed",
    conclusion: "skipped",
    steps: [],
  };
  value.artifacts = value.artifacts.slice(0, 2);
  value.definitions = definitions;
  value.resume = {
    plan: { include: [] },
    previous: { schemaVersion: 1, revision: 1, packages },
    state: { draft: true },
    definitions,
    fingerprints: value.fingerprints,
  };
  return value;
}

test("an exact owned full draft can resume without rebuilding while retaining every global native gate", () => {
  const value = emptyDraftFixture();
  expect(ownedDraftResume(value.resume)).toHaveLength(39);
  const payload = stagedEvidence(value);
  expect(verifiedEvidence(envelope(payload), publicKey)).toEqual(payload);
  const success = completed(value);
  success.jobs.find(({ name }) => name === "build").conclusion = "skipped";
  expect(admitEvidence(payload, success)).toEqual(payload);
  expect(productionRun(success)).toEqual([]);
  expect(() =>
    nativeLineage(value.resume.previous.packages[0], payload, {
      bytes: 100,
      sha256: "c".repeat(64),
    }),
  ).toThrow();
  expect(() => admitOriginalEvidence(payload, success, [])).toThrow();
  for (const mutate of [
    (v) => {
      delete v.resume;
    },
    (v) => {
      v.resume.state.draft = false;
    },
    (v) => {
      v.resume.state.extra = true;
    },
    (v) => {
      v.resume.previous.packages.pop();
    },
    (v) => {
      v.resume.previous.packages[0].sourceFingerprint = "e".repeat(64);
    },
    (v) => {
      v.resume.previous.packages[0].hostABI = "foreign-ABI";
    },
    (v) => {
      v.fingerprints = { ...v.fingerprints, owner0: "e".repeat(64) };
    },
    (v) => {
      v.run.head_sha = "f".repeat(40);
    },
    (v) => {
      v.jobs[3].conclusion = "success";
    },
    (v) => {
      v.jobs[3].name = "build (owner0)";
    },
    (v) => {
      v.jobs[3].steps = [
        {
          name: "unexpected native step",
          number: 1,
          status: "completed",
          conclusion: "skipped",
        },
      ];
    },
    (v) => {
      v.jobs[1].conclusion = "failure";
    },
    (v) => {
      v.jobs[2].steps[0].conclusion = "skipped";
    },
  ]) {
    const changed = structuredClone(value);
    mutate(changed);
    expect(() => stagedEvidence(changed)).toThrow();
  }
  for (const mutate of [
    (v) => {
      v.run.conclusion = "failure";
    },
    (v) => {
      v.jobs.find(({ name }) => name === "publish").steps.at(-1).conclusion =
        "failure";
    },
    (v) => {
      v.jobs[1].conclusion = "skipped";
    },
    (v) => {
      delete v.resume;
    },
  ]) {
    const changed = structuredClone(success);
    mutate(changed);
    expect(() => admitEvidence(payload, changed)).toThrow();
  }
});
