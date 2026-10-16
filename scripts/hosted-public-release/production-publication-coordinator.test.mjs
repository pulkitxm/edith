import { test } from "bun:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { PassThrough } from "node:stream";
import {
  productionCatalogBinding,
  productionCatalogChannel,
  productionCatalogMessage,
} from "./production-catalog-channel.mjs";
import {
  admitProductionPublicationEnvironment,
  admitStagedPublicationAPI,
  completedProductionCohortRequest,
  coordinateProductionCatalog,
  parseProductionCohortTemplate,
} from "./production-publication-coordinator.mjs";

const previous = {
  schemaVersion: 1,
  revision: 1,
  assetName: "catalog-1.json",
  bytes: 100,
  sha256: "a".repeat(64),
};
const candidate = {
  schemaVersion: 1,
  revision: 2,
  assetName: "catalog-2.json",
  bytes: 200,
  sha256: "b".repeat(64),
};
const identity = { source: "c".repeat(40), previous, candidate };
const record = {
  id: "keepAwake",
  version: "1.0.1",
  sha256: "d".repeat(64),
  sourceFingerprint: "e".repeat(64),
};
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
const measured = {
  ...prepared.packages.current,
  source: identity.source,
  archiveSHA256: record.sha256,
  sourceFingerprint: record.sourceFingerprint,
  archiveURL: `https://github.com/pulkitxm/edith/releases/download/extensions%2FkeepAwake%2F1.0.1-${record.sourceFingerprint.slice(0, 20)}/keepAwake.zip`,
};
Object.assign(record, {
  downloadURL: measured.archiveURL,
  downloadBytes: measured.downloadBytes,
  installedBytes: measured.installedBytes,
  hostABI: measured.hostABI,
  architecture: measured.architecture,
  minimumSystemVersion: measured.minimumSystemVersion,
  dependencies: measured.dependencies,
});
const template = {
  ...prepared,
  source: identity.source,
  catalogs: {
    previous: { ...prepared.catalogs.previous, sha256: previous.sha256 },
    current: null,
  },
  packages: { previous: prepared.packages.previous, current: null },
};
const text = completedProductionCohortRequest(
  template,
  identity,
  record,
  measured,
);
const binding = productionCatalogBinding(text, identity);
function pair() {
  const left = new PassThrough();
  const right = new PassThrough();
  const parent = productionCatalogChannel(left, right);
  const child = productionCatalogChannel(right, left);
  return {
    parent,
    child,
    close: () => {
      parent.close();
      child.close();
    },
  };
}

test("real restoration milestone gates promotion and acknowledgement follows completed promotion", async () => {
  const channels = pair();
  let started = false;
  let finished = false;
  let release;
  const held = new Promise((resolve) => {
    release = resolve;
  });
  try {
    const operation = coordinateProductionCatalog(
      channels.parent,
      binding,
      async () => {
        started = true;
        await held;
        finished = true;
      },
      () => true,
    );
    assert.equal(started, false);
    await channels.child.write(
      productionCatalogMessage("host-restored", binding),
    );
    await new Promise((resolve) => setImmediate(resolve));
    assert.equal(started, true);
    assert.equal(finished, false);
    let acknowledged = false;
    const acknowledgement = channels.child.read().then((message) => {
      acknowledged = true;
      return message;
    });
    await new Promise((resolve) => setImmediate(resolve));
    assert.equal(acknowledged, false);
    release();
    await operation;
    assert.deepEqual(
      await acknowledgement,
      productionCatalogMessage("catalog-promoted", binding),
    );
    assert.equal(finished, true);
  } finally {
    release();
    channels.close();
  }
});

test("wrong request, early child retirement and failed promotion cannot produce a promotion acknowledgement", async () => {
  for (const kind of ["wrong-request", "retired", "failed-promote"]) {
    const channels = pair();
    let calls = 0;
    const operation = coordinateProductionCatalog(
      channels.parent,
      binding,
      async () => {
        calls++;
        throw new Error("synthetic promotion failure");
      },
      () => kind !== "retired",
    );
    const message = productionCatalogMessage("host-restored", binding);
    await channels.child.write(
      kind === "wrong-request"
        ? { ...message, requestSHA256: "f".repeat(64) }
        : message,
    );
    await assert.rejects(operation);
    assert.equal(calls, kind === "failed-promote" ? 1 : 0);
    const acknowledgement = channels.child.read();
    channels.close();
    await assert.rejects(acknowledgement);
  }
});

test("current catalog metadata comes only from the actual staged candidate and exact package bytes", () => {
  assert.throws(() =>
    completedProductionCohortRequest(
      { ...template, schema: 2 },
      identity,
      record,
      measured,
    ),
  );
  const completed = JSON.parse(text);
  assert.deepEqual(completed.catalogs.current, {
    revision: 2,
    sha256: candidate.sha256,
    bytes: 200,
    signatureVerified: true,
    selectedVersion: "1.0.1",
    selectedArchiveSHA256: record.sha256,
  });
  assert.equal(template.catalogs.current, null);
  assert.equal(template.packages.current, null);
  assert.deepEqual(completed.packages.previous, template.packages.previous);
  assert.deepEqual(completed.packages.current, measured);
  for (const change of [
    { version: "1.0.0" },
    { sha256: "f".repeat(64) },
    { sourceFingerprint: "f".repeat(64) },
    { id: "calendar" },
  ])
    assert.throws(() =>
      completedProductionCohortRequest(
        template,
        identity,
        {
          ...record,
          ...change,
        },
        measured,
      ),
    );
  assert.throws(() =>
    completedProductionCohortRequest(
      { ...template, catalogs: { ...template.catalogs, current: candidate } },
      identity,
      record,
      measured,
    ),
  );
  assert.throws(() =>
    completedProductionCohortRequest(
      { ...template, source: "f".repeat(40) },
      identity,
      record,
      measured,
    ),
  );
  assert.throws(() =>
    completedProductionCohortRequest(
      { ...template, application: "/synthetic/Edith.app" },
      identity,
      record,
      measured,
    ),
  );
});

test("publication owner admission rejects foreign repository, actor, ref, source, ordinary push and ambient authority", () => {
  const environment = {
    GITHUB_ACTIONS: "true",
    RUNNER_ENVIRONMENT: "github-hosted",
    RUNNER_OS: "macOS",
    GITHUB_REPOSITORY: "pulkitxm/edith",
    GITHUB_REPOSITORY_ID: "1289153439",
    GITHUB_EVENT_NAME: "workflow_dispatch",
    GITHUB_REF: "refs/heads/main",
    PUBLIC_RELEASE_VERIFICATION: "1",
    GITHUB_ACTOR_ID: "65671483",
    GITHUB_SHA: identity.source,
    GH_TOKEN: "synthetic-write",
    GITHUB_TOKEN: "synthetic-read",
    EXTENSION_CATALOG_PRIVATE_KEY: "synthetic-signing",
  };
  admitProductionPublicationEnvironment(environment, identity.source);
  for (const change of [
    { GITHUB_REPOSITORY: "synthetic/foreign" },
    { GITHUB_REPOSITORY_ID: "1" },
    { GITHUB_ACTOR_ID: "1" },
    { GITHUB_REF: "refs/heads/synthetic" },
    { GITHUB_SHA: "f".repeat(40) },
    { GITHUB_EVENT_NAME: "push" },
    { RUNNER_ENVIRONMENT: "self-hosted" },
    { NODE_OPTIONS: "synthetic" },
    { EDITH_EXTENSION_DATA_ROOT: "/synthetic" },
    { GH_TOKEN: "synthetic-read" },
  ])
    assert.throws(() =>
      admitProductionPublicationEnvironment(
        { ...environment, ...change },
        identity.source,
      ),
    );
});

test("cohort template parser rejects duplicate source and measured-pointer substitutions before publication", () => {
  const environment = {
    PATH: process.env.PATH,
    PUBLIC_RELEASE_VERIFICATION: "1",
  };
  const request = { schema: 1, ...template };
  assert.deepEqual(
    parseProductionCohortTemplate(JSON.stringify(request), environment),
    request,
  );
  assert.throws(() =>
    parseProductionCohortTemplate(
      JSON.stringify(request).replace('"schema":1', '"schema":1,"schema":1'),
      environment,
    ),
  );
  assert.throws(() =>
    parseProductionCohortTemplate(
      JSON.stringify({
        ...request,
        catalogs: { ...request.catalogs, current: candidate },
      }),
      environment,
    ),
  );
  assert.throws(() =>
    parseProductionCohortTemplate(
      JSON.stringify({ ...request, application: "/synthetic/Edith.app" }),
      environment,
    ),
  );
});

test("missing reviewed publication prerequisites fail before credential or artifact authority can be used", () => {
  const namespace = {
    publishExtensions() {},
    stagedExtensionPublication() {},
    promoteStagedExtensionPublication() {},
  };
  assert.equal(admitStagedPublicationAPI(namespace), namespace);
  for (const name of Object.keys(namespace)) {
    const absent = { ...namespace };
    delete absent[name];
    assert.throws(
      () => admitStagedPublicationAPI(absent),
      /Reviewed staged publication APIs/,
    );
    assert.throws(
      () => admitStagedPublicationAPI({ ...namespace, [name]: true }),
      /Reviewed staged publication APIs/,
    );
  }
});

test("preparation cannot supply fabricated B package facts or weaken immutable A and host expectations", () => {
  const environment = {
    PATH: process.env.PATH,
    PUBLIC_RELEASE_VERIFICATION: "1",
  };
  for (const change of [
    { packages: { ...template.packages, current: measured } },
    {
      packages: {
        ...template.packages,
        previous: { ...template.packages.previous, version: "1.0.1" },
      },
    },
    {
      hosts: {
        ...template.hosts,
        current: {
          ...template.hosts.current,
          normalizedUnsignedSHA256:
            template.hosts.previous.normalizedUnsignedSHA256,
        },
      },
    },
  ])
    assert.throws(() =>
      parseProductionCohortTemplate(
        JSON.stringify({ ...template, ...change }),
        environment,
      ),
    );
  for (const change of [
    { source: "f".repeat(40) },
    { downloadBytes: measured.downloadBytes + 1 },
  ]) {
    const changed = { ...measured, ...change };
    assert.throws(() =>
      completedProductionCohortRequest(template, identity, record, changed),
    );
  }
});

await import("../production-orchestration.test.js");
