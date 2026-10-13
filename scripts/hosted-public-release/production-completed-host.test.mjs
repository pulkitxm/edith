import { test } from "bun:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { chmod, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import {
  admitHostBootstrapIntent,
  retireHostBootstrapIntent,
} from "./production-bootstrap.mjs";
import {
  completedHostBootstrap,
  completedHostPublication,
} from "./production-completed-host.mjs";

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
const source = "a".repeat(40),
  continuation = "b".repeat(40);
const template = {
  ...prepared,
  schema: 2,
  source,
  hosts: {
    previous: prepared.hosts.previous,
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
  packages: { previous: prepared.packages.previous, current: null },
  catalogs: { previous: prepared.catalogs.previous, current: null },
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
  GITHUB_SHA: source,
  GITHUB_RUN_ID: "13",
  GITHUB_RUN_ATTEMPT: "1",
  GITHUB_JOB: "publish",
  GITHUB_ACTOR_ID: "65671483",
  GITHUB_TOKEN: "synthetic-unused-token",
  PUBLIC_RELEASE_VERIFICATION: "1",
};
const hash = (bytes) => createHash("sha256").update(bytes).digest("hex");
function fixture() {
  const run = (id, path) => ({
    id,
    run_attempt: 1,
    repository: { full_name: "pulkitxm/edith", id: 1289153439 },
    actor: { id: 65671483 },
    head_sha: source,
    head_branch: "main",
    event: "workflow_dispatch",
    path,
    status: "in_progress",
    conclusion: null,
  });
  const hostRun = run(12, ".github/workflows/ci.yml");
  const steps = [
    [
      "Build DMG",
      [
        "Record the source-bound static host release proof",
        "Generate the signed appcast",
        "Verify code signatures",
      ],
    ],
    ["Publish release", ["Commit and tag the release", "Publish the release"]],
  ];
  const jobs = {
    total_count: 2,
    jobs: steps.map(([name, steps], index) => ({
      id: 20 + index,
      run_id: 12,
      run_attempt: 1,
      head_sha: source,
      name,
      status: "completed",
      conclusion: "success",
      steps: steps.map((name) => ({
        name,
        status: "completed",
        conclusion: "success",
      })),
    })),
  };
  const files = new Map([
    ["Edith.dmg", Buffer.from("synthetic sealed DMG bytes")],
    ["appcast.xml", Buffer.from("synthetic inspected signed appcast")],
    ["build-metadata.json", Buffer.from("{}")],
  ]);
  const proof = {
    sourceCommit: source,
    version: template.hosts.current.version,
    build: template.hosts.current.build,
    dmgSHA256: hash(files.get("Edith.dmg")),
    hostExecutableSHA256: "4".repeat(64),
  };
  files.set("host-release-proof.json", Buffer.from(JSON.stringify(proof)));
  files.set(
    "toolchain-provenance.json",
    Buffer.from(
      JSON.stringify({
        schema: 1,
        sourceCommit: source,
        hostExecutableSHA256: proof.hostExecutableSHA256,
        xcode: "Xcode 16.0\nBuild version 16A242d",
        sdk: "14.0",
        builderSignature: "ad-hoc",
      }),
    ),
  );
  const release = {
    id: 101,
    tag_name: template.hosts.current.tag,
    target_commitish: continuation,
    draft: false,
    prerelease: true,
    assets: [...files].map(([name, bytes], index) => ({
      id: 30 + index,
      name,
      size: bytes.length,
      digest: `sha256:${hash(bytes)}`,
      state: "uploaded",
      browser_download_url: `https://github.com/pulkitxm/edith/releases/download/${template.hosts.current.tag}/${name}`,
    })),
  };
  const tag = {
    ref: `refs/tags/${template.hosts.current.tag}`,
    object: { type: "commit", sha: continuation },
  };
  const documents = new Map([
    ["/actions/runs/12", hostRun],
    ["/actions/runs/13", run(13, ".github/workflows/extensions.yml")],
    ["/actions/runs/12/attempts/1/jobs?per_page=100", jobs],
    [
      "/git/ref/heads/main",
      { ref: "refs/heads/main", object: { type: "commit", sha: source } },
    ],
    [`/releases/tags/${template.hosts.current.tag}`, release],
    [`/git/ref/tags/${template.hosts.current.tag}`, tag],
  ]);
  const fetchMetadata = async (path) => {
    assert(documents.has(path), path);
    return structuredClone(documents.get(path));
  };
  const finish = () => {
    hostRun.status = "completed";
    hostRun.conclusion = "success";
    documents.get("/git/ref/heads/main").object.sha = continuation;
  };
  return {
    hostRun,
    jobs,
    release,
    tag,
    files,
    documents,
    fetchMetadata,
    finish,
    facts: () => ({ run: hostRun, jobs, release, tag }),
  };
}
async function pending(f) {
  return admitHostBootstrapIntent(JSON.stringify(template), environment, f);
}
test("completed publication facts remain plain non-authority even when all actual identities match", async () => {
  const f = fixture(),
    cap = await pending(f);
  f.finish();
  const value = completedHostPublication(cap, f.facts());
  assert.equal(value.run.id, 12);
  assert.equal(value.release.assets.length, 5);
  assert(Object.isFrozen(value.release.assets[0]));
  assert.throws(() => completedHostBootstrap(value));
  assert.throws(() => completedHostBootstrap(cap));
  assert.throws(() => completedHostPublication({}, f.facts()));
  retireHostBootstrapIntent(cap);
  assert.throws(() => completedHostPublication(cap, f.facts()));
});
test("pending failed canceled foreign stale replayed or unsigned publication facts never qualify", async () => {
  const edits = [
    (f) => (f.hostRun.status = "in_progress"),
    (f) => (f.hostRun.conclusion = "failure"),
    (f) => (f.hostRun.conclusion = "cancelled"),
    (f) => (f.hostRun.repository.id = 1),
    (f) => (f.hostRun.run_attempt = 2),
    (f) => (f.hostRun.head_sha = "c".repeat(40)),
    (f) => (f.hostRun.actor.id = 1),
    (f) => (f.jobs.jobs[0].run_attempt = 2),
    (f) => (f.jobs.jobs[0].head_sha = "c".repeat(40)),
    (f) => (f.jobs.jobs[0].id = f.jobs.jobs[1].id),
    (f) => (f.jobs.jobs[0].conclusion = "skipped"),
    (f) => (f.jobs.jobs[0].steps[0].conclusion = "failure"),
    (f) => f.jobs.jobs[0].steps.push(f.jobs.jobs[0].steps[0]),
    (f) => (f.jobs.total_count = 3),
    (f) => (f.release.draft = true),
    (f) => (f.release.prerelease = false),
    (f) => (f.release.target_commitish = source),
    (f) => (f.tag.object.type = "tag"),
    (f) => (f.release.assets[0].state = "new"),
    (f) => (f.release.assets[0].digest = "sha256:invalid"),
    (f) =>
      (f.release.assets[0].browser_download_url =
        "https://example.com/Edith.dmg"),
    (f) => (f.release.assets[0].id = f.release.assets[1].id),
    (f) => f.release.assets.pop(),
    (f) => (f.release.assets[0].size = 512 * 1024 ** 2 + 1),
  ];
  for (const edit of edits) {
    const f = fixture(),
      cap = await pending(f);
    f.finish();
    edit(f);
    assert.throws(() => completedHostPublication(cap, f.facts()));
  }
});
function stamp(f) {
  const row = (path, type, mode, sha) => ({ path, type, mode, sha });
  const blob = (bytes) => {
    const sha = createHash("sha1")
      .update(`blob ${bytes.length}\0`)
      .update(bytes)
      .digest("hex");
    f.documents.set(`/git/blobs/${sha}`, {
      sha,
      size: bytes.length,
      encoding: "base64",
      content: bytes.toString("base64"),
    });
    return sha;
  };
  const plist = (version, build) =>
    Buffer.from(
      `<plist version="1.0"><dict><key>CFBundleShortVersionString</key><string>${version}</string><key>CFBundleVersion</key><string>${build}</string><key>CFBundleExecutable</key><string>Edith</string></dict></plist>`,
    );
  const before = blob(plist("0.0.401", 1)),
    after = blob(
      plist(template.hosts.current.version, template.hosts.current.build),
    );
  const oldRoot = "c".repeat(40),
    newRoot = "d".repeat(40),
    oldResources = "e".repeat(40),
    newResources = "f".repeat(40);
  for (const [root, resources] of [
    [oldRoot, oldResources],
    [newRoot, newResources],
  ])
    f.documents.set(`/git/trees/${root}`, {
      sha: root,
      truncated: false,
      tree: [
        row("Resources", "tree", "040000", resources),
        row("Casks", "tree", "040000", "2".repeat(40)),
        row("Sources", "tree", "040000", "3".repeat(40)),
      ],
    });
  for (const [resources, sha] of [
    [oldResources, before],
    [newResources, after],
  ])
    f.documents.set(`/git/trees/${resources}`, {
      sha: resources,
      truncated: false,
      tree: [
        row("Info.plist", "blob", "100644", sha),
        row("HelperInfo.plist", "blob", "100644", sha),
        row("icon.png", "blob", "100644", "4".repeat(40)),
      ],
    });
  f.documents.set(`/git/commits/${source}`, {
    sha: source,
    tree: { sha: oldRoot },
    parents: [],
    message: "Reviewed implementation",
  });
  f.documents.set(`/git/commits/${continuation}`, {
    sha: continuation,
    tree: { sha: newRoot },
    parents: [{ sha: source }],
    message: `Release ${template.hosts.current.tag} [skip ci]`,
  });
}
async function privateProducer(directory) {
  const original = fileURLToPath(
    new URL("./production-completed-host.mjs", import.meta.url),
  );
  let code = await readFile(original, "utf8");
  const rootBinding =
    'const root = resolve(dirname(fileURLToPath(import.meta.url)), "../..");';
  assert.equal(code.split(rootBinding).length, 2);
  code = code.replace(
    rootBinding,
    `const root = ${JSON.stringify(resolve(dirname(original), "../.."))};`,
  );
  const start = code.indexOf("async function nativeContext(");
  const end = code.indexOf("function validateMeasuredHost(", start);
  assert(start > 0 && end > start);
  code =
    code.slice(0, start) +
    `async function nativeContext() { return { directory: globalThis.__completedHostNative.directory, checkSource: () => {}, prepareTag: () => {} }; }\nfunction nativeMeasure(context, environment) { assert.equal(environment.PUBLISH, "false"); assert.equal(environment.REBUILD, ""); assert.equal(environment.GH_TOKEN, undefined); assert.equal(environment.EXTENSION_CATALOG_PRIVATE_KEY, undefined); globalThis.__completedHostNative.calls++; return structuredClone(globalThis.__completedHostNative.measured); }\n` +
    code.slice(end);
  code = code.replace(
    /(?:from\s+|import\(\s*)"(\.[^"]+)"/g,
    (match, relative) => {
      const target =
        relative === "../extension-stage-continuity.mjs"
          ? (process.env.COHORT_STAMP_HELPER_SOURCE ??
            resolve(dirname(original), relative))
          : resolve(dirname(original), relative);
      assert(target);
      return match.replace(relative, pathToFileURL(target).href);
    },
  );
  const path = join(directory, "producer.mjs");
  await writeFile(path, code, { mode: 0o600 });
  return import(`${pathToFileURL(path).href}?synthetic=${Date.now()}`);
}
async function withProducer(action) {
  const directory = await mkdtemp(
    join(resolve(tmpdir()), "completed-host-pure-"),
  );
  await chmod(directory, 0o700);
  const f = fixture(),
    cap = await pending(f);
  f.finish();
  stamp(f);
  const files = f.files;
  const host = {
    ...prepared.hosts.current,
    source,
    run: 12,
    tag: template.hosts.current.tag,
    version: template.hosts.current.version,
    build: template.hosts.current.build,
    proofSHA256: hash(files.get("host-release-proof.json")),
    dmgURL: `https://github.com/pulkitxm/edith/releases/download/${template.hosts.current.tag}/Edith.dmg`,
    dmgSHA256: hash(files.get("Edith.dmg")),
    dmgBytes: files.get("Edith.dmg").length,
    appcastSHA256: hash(files.get("appcast.xml")),
    hostExecutableSHA256: "4".repeat(64),
    normalizedUnsignedSHA256: "5".repeat(64),
  };
  const channel = Object.fromEntries(
    ["id", "tag_name", "target_commitish", "draft", "prerelease"].map((key) => [
      key,
      f.release[key],
    ]),
  );
  const native = {
    calls: 0,
    directory,
    measured: { host, qualification: { releaseChannel: channel } },
  };
  const oldFetch = globalThis.fetch,
    oldNative = globalThis.__completedHostNative;
  const previous = Object.fromEntries(
    Object.keys(environment).map((key) => [key, process.env[key]]),
  );
  const downloads = [];
  try {
    Object.assign(process.env, environment);
    globalThis.__completedHostNative = native;
    globalThis.fetch = async (url) => {
      const parsed = new URL(url);
      if (parsed.origin === "https://api.github.com") {
        const path =
          parsed.pathname.replace("/repos/pulkitxm/edith", "") + parsed.search;
        if (path === f.failedMetadata)
          return new Response(
            new ReadableStream({
              cancel() {
                f.errorBodyCancelled++;
              },
            }),
            { status: 500 },
          );
        return new Response(JSON.stringify(await f.fetchMetadata(path)), {
          status: 200,
        });
      }
      assert.equal(parsed.origin, "https://github.com");
      const name = parsed.pathname.split("/").at(-1);
      assert(files.has(name));
      downloads.push(name);
      return new Response(files.get(name), { status: 200 });
    };
    const producer = await privateProducer(directory);
    await action({ f, cap, producer, native, directory, downloads });
  } finally {
    globalThis.fetch = oldFetch;
    globalThis.__completedHostNative = oldNative;
    for (const [key, value] of Object.entries(previous)) {
      if (value === undefined) delete process.env[key];
      else process.env[key] = value;
    }
    await rm(directory, { recursive: true, force: true });
  }
}
test("actual opaque producer admits only completed sealed API files plus exact release continuation", async () => {
  await withProducer(async ({ cap, producer, downloads }) => {
    const completed = await producer.prepareCompletedHostBootstrap(cap);
    const value = producer.completedHostBootstrap(completed);
    assert.deepEqual(downloads.toSorted(), [
      "Edith.dmg",
      "appcast.xml",
      "build-metadata.json",
      "host-release-proof.json",
      "toolchain-provenance.json",
    ]);
    assert.equal(value.continuation, continuation);
    assert.equal(value.proof.sourceCommit, source);
    assert.equal(value.host.normalizedUnsignedSHA256, "5".repeat(64));
    assert.equal(value.release.prerelease, true);
    assert.throws(() => producer.completedHostBootstrap({ ...completed }));
    assert.throws(() => completedHostBootstrap(completed));
    await value.revalidate();
  });
});
test("post-inspection asset replay cancellation file substitution and source continuation revoke completed authority", async () => {
  const edits = [
    ({ f }) => (f.hostRun.run_attempt = 2),
    ({ f }) => (f.hostRun.conclusion = "cancelled"),
    ({ f }) => (f.release.assets[0].id += 100),
    ({ f }) => (f.release.assets[0].digest = `sha256:${"9".repeat(64)}`),
    ({ f }) =>
      (f.documents.get("/git/ref/heads/main").object.sha = "9".repeat(40)),
    async ({ directory }) =>
      writeFile(join(directory, "appcast.xml"), "changed", { mode: 0o600 }),
    async ({ directory }) => {
      const path = join(directory, "appcast.xml"),
        bytes = await readFile(path);
      await rm(path);
      await writeFile(path, bytes, { mode: 0o600 });
    },
    async ({ directory }) =>
      writeFile(join(directory, "context.json"), "{}", { mode: 0o600 }),
    ({ cap }) => retireHostBootstrapIntent(cap),
  ];
  for (const edit of edits)
    await withProducer(async (values) => {
      const completed = await values.producer.prepareCompletedHostBootstrap(
        values.cap,
      );
      const value = values.producer.completedHostBootstrap(completed);
      await edit(values);
      await assert.rejects(value.revalidate());
      assert.throws(() => values.producer.completedHostBootstrap(completed));
      await assert.rejects(value.revalidate());
    });
});
test("native measurement identity mismatches and equal implementation never mint completed host", async () => {
  for (const edit of [
    (value) =>
      (value.host.normalizedUnsignedSHA256 =
        prepared.hosts.previous.normalizedUnsignedSHA256),
    (value) => (value.host.teamIdentifier = "ZZZZZZZZZZ"),
    (value) => (value.host.deepStrictSignatureVerified = false),
    (value) => (value.host.publicationVerified = false),
    (value) => (value.host.proofSHA256 = "9".repeat(64)),
    (value) => (value.host.dmgSHA256 = "9".repeat(64)),
    (value) => (value.qualification.releaseChannel.prerelease = false),
  ])
    await withProducer(async ({ producer, cap, native }) => {
      edit(native.measured);
      await assert.rejects(producer.prepareCompletedHostBootstrap(cap));
      assert.equal(native.calls, 1);
    });
});

test("failed API bodies are retired before error without downloads or completed authority", async () => {
  await withProducer(async ({ f, producer, cap, native, downloads }) => {
    f.failedMetadata = "/actions/runs/12";
    f.errorBodyCancelled = 0;
    await assert.rejects(producer.prepareCompletedHostBootstrap(cap));
    assert.equal(f.errorBodyCancelled, 1);
    assert.equal(native.calls, 0);
    assert.deepEqual(downloads, []);
    assert.throws(() => producer.completedHostBootstrap({}));
  });
});
