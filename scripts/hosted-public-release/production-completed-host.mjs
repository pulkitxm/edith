import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { lstat, mkdtemp, open, realpath } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import {
  closedJSON,
  downloadPublic,
  successfulRun,
  toolchainProvenance,
} from "./contract.mjs";
import { verifiedHostBootstrapIntent } from "./production-bootstrap.mjs";
import { productionReadonlyEnvironment } from "./production-catalog-channel.mjs";
import {
  boundedProductionFile,
  closedProductionAsset,
} from "./production-inputs.mjs";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const admissions = new WeakMap();
const names = [
  "Edith.dmg",
  "appcast.xml",
  "build-metadata.json",
  "host-release-proof.json",
  "toolchain-provenance.json",
];
const positive = (value) => assert(Number.isSafeInteger(value) && value > 0);
const immutable = (value) => {
  if (value && typeof value === "object") {
    for (const item of Object.values(value)) immutable(item);
    Object.freeze(value);
  }
  return value;
};
const projection = (value, fields) =>
  Object.fromEntries(
    fields.map((field) => {
      assert(Object.hasOwn(value, field));
      return [field, value[field]];
    }),
  );
export function completedHostPublication(capability, facts) {
  const intent = verifiedHostBootstrapIntent(capability);
  assert.equal(intent.role, "extensions");
  const { run, jobs, release, tag } = facts;
  successfulRun(run, intent.source, ".github/workflows/ci.yml");
  assert.equal(run.repository.id, 1289153439);
  assert.equal(run.id, intent.host.run);
  assert.equal(run.run_attempt, intent.host.runAttempt);
  assert.equal(run.head_branch, "main");
  assert.equal(run.event, "workflow_dispatch");
  assert([65671483, 320458784].includes(run.actor?.id));
  if (run.triggering_actor)
    assert([65671483, 320458784].includes(run.triggering_actor.id));
  assert(
    Number.isSafeInteger(jobs.total_count) &&
      jobs.total_count > 0 &&
      jobs.total_count <= 100,
  );
  assert.equal(jobs.jobs.length, jobs.total_count);
  assert.equal(new Set(jobs.jobs.map(({ id }) => id)).size, jobs.total_count);
  for (const job of jobs.jobs) {
    positive(job.id);
    assert.equal(job.run_id, run.id);
    assert.equal(job.run_attempt, run.run_attempt);
    assert.equal(job.head_sha, run.head_sha);
  }
  for (const [name, steps] of [
    [
      "Build DMG",
      [
        "Record the source-bound static host release proof",
        "Generate the signed appcast",
        "Verify code signatures",
      ],
    ],
    ["Publish release", ["Commit and tag the release", "Publish the release"]],
  ]) {
    const matching = jobs.jobs.filter((job) => job.name === name);
    assert.equal(matching.length, 1);
    assert.equal(matching[0].status, "completed");
    assert.equal(matching[0].conclusion, "success");
    for (const step of steps) {
      const rows = matching[0].steps.filter(
        ({ name: actual }) => actual === step,
      );
      assert.equal(rows.length, 1);
      assert.equal(rows[0].status, "completed");
      assert.equal(rows[0].conclusion, "success");
    }
  }
  positive(release.id);
  assert.equal(release.tag_name, intent.host.tag);
  assert.equal(release.draft, false);
  assert.equal(release.prerelease, true);
  assert.equal(tag.ref, `refs/tags/${intent.host.tag}`);
  assert.equal(tag.object.type, "commit");
  assert.match(tag.object.sha, /^[a-f0-9]{40}$/);
  assert.notEqual(tag.object.sha, intent.source);
  assert.equal(release.target_commitish, tag.object.sha);
  assert(
    Array.isArray(release.assets) && release.assets.length === names.length,
  );
  assert.deepEqual(
    release.assets.map(({ name }) => name).toSorted(),
    names.toSorted(),
  );
  assert.equal(new Set(release.assets.map(({ id }) => id)).size, names.length);
  for (const asset of release.assets) {
    positive(asset.id);
    assert.equal(asset.state, "uploaded");
    const value = closedProductionAsset(release, asset.name);
    assert(
      value.bytes <= (asset.name === "Edith.dmg" ? 512 * 1024 ** 2 : 1024 ** 2),
    );
  }
  return immutable({
    run: {
      ...projection(run, [
        "id",
        "run_attempt",
        "head_sha",
        "head_branch",
        "event",
        "path",
        "status",
        "conclusion",
      ]),
      repository: projection(run.repository, ["id", "full_name"]),
      actor: projection(run.actor, ["id"]),
    },
    jobs: {
      total_count: jobs.total_count,
      jobs: jobs.jobs.map((job) =>
        projection(job, [
          "id",
          "run_id",
          "run_attempt",
          "head_sha",
          "name",
          "status",
          "conclusion",
        ]),
      ),
    },
    release: {
      ...projection(release, [
        "id",
        "tag_name",
        "target_commitish",
        "draft",
        "prerelease",
      ]),
      assets: release.assets
        .map((asset) =>
          projection(asset, [
            "id",
            "name",
            "size",
            "digest",
            "state",
            "browser_download_url",
          ]),
        )
        .sort((a, b) => a.name.localeCompare(b.name)),
    },
    tag: { ref: tag.ref, object: projection(tag.object, ["type", "sha"]) },
  });
}
async function metadata(path, environment) {
  assert(
    /^\/(?:actions\/runs\/[0-9]+(?:\/attempts\/[0-9]+\/jobs\?per_page=100)?|releases\/tags\/v[0-9.]+|git\/(?:ref\/(?:heads\/main|tags\/v[0-9.]+)|(?:commits|trees|blobs)\/[a-f0-9]{40}))$/.test(
      path,
    ),
  );
  const response = await fetch(
    `https://api.github.com/repos/pulkitxm/edith${path}`,
    {
      headers: {
        Accept: "application/vnd.github+json",
        Authorization: `Bearer ${environment.GITHUB_TOKEN}`,
        "Cache-Control": "no-cache",
      },
      signal: AbortSignal.timeout(15000),
      cache: "no-store",
      redirect: "error",
    },
  );
  const reader = response.body?.getReader();
  assert(reader);
  const chunks = [];
  let size = 0;
  try {
    assert.equal(response.status, 200);
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      size += value.length;
      assert(size <= 2 * 1024 ** 2);
      chunks.push(value);
    }
  } finally {
    await reader.cancel();
  }
  return closedJSON(
    new TextDecoder("utf-8", { fatal: true }).decode(Buffer.concat(chunks)),
    2 * 1024 ** 2,
  );
}
async function nativeContext(intent, environment) {
  assert.equal(process.platform, "darwin");
  assert.equal(process.arch, "arm64");
  const checkSource = () => {
    assert.equal(
      execFileSync("git", ["rev-parse", "HEAD"], {
        cwd: root,
        env: environment,
        encoding: "utf8",
      }).trim(),
      intent.source,
    );
    assert.equal(
      execFileSync(
        "git",
        ["status", "--porcelain", "--untracked-files=normal"],
        { cwd: root, env: environment, encoding: "utf8" },
      ),
      "",
    );
  };
  checkSource();
  const local = join(root, "local");
  const info = await lstat(local);
  assert(
    info.isDirectory() &&
      info.uid === process.getuid() &&
      !info.isSymbolicLink(),
  );
  assert.equal(await realpath(local), local);
  const directory = await mkdtemp(join(local, "completed-public-host-"));
  assert.equal(await realpath(directory), directory);
  const prepareTag = (target) => {
    execFileSync(
      "git",
      [
        "fetch",
        "--no-tags",
        "--depth=2",
        "origin",
        `refs/tags/${intent.host.tag}:refs/tags/${intent.host.tag}`,
        "+refs/heads/main:refs/remotes/origin/main",
        intent.source,
      ],
      { cwd: root, env: environment, timeout: 60000, stdio: "pipe" },
    );
    assert.equal(
      execFileSync("git", ["rev-parse", `refs/tags/${intent.host.tag}`], {
        cwd: root,
        env: environment,
        encoding: "utf8",
      }).trim(),
      target,
    );
    assert.equal(
      execFileSync("git", ["rev-parse", "refs/remotes/origin/main"], {
        cwd: root,
        env: environment,
        encoding: "utf8",
      }).trim(),
      target,
    );
  };
  return { directory, checkSource, prepareTag };
}
function nativeMeasure(context, environment) {
  return closedJSON(
    execFileSync(
      "python3",
      [
        "-I",
        "-B",
        join(root, "scripts/hosted-public-release/production-static-inputs.py"),
        "measure-host",
        context,
      ],
      { cwd: root, env: environment, timeout: 300000, maxBuffer: 1024 ** 2 },
    ).toString(),
    1024 ** 2,
  );
}
function validateMeasuredHost(value, environment) {
  execFileSync(
    "python3",
    [
      "-I",
      "-B",
      "-c",
      "import importlib.util,json,sys;s=importlib.util.spec_from_file_location('cohort',sys.argv[1]);m=importlib.util.module_from_spec(s);s.loader.exec_module(m);m.host(json.load(sys.stdin))",
      join(root, "scripts/hosted-public-release/production-cohort.py"),
    ],
    {
      input: JSON.stringify(value),
      stdio: "pipe",
      env: environment,
      timeout: 60000,
      maxBuffer: 65536,
    },
  );
}
export function completedHostBootstrap(capability) {
  const state = admissions.get(capability);
  assert(state && !state.closed, "Unknown or retired completed host bootstrap");
  verifiedHostBootstrapIntent(state.pending);
  return state.identity;
}
export async function prepareCompletedHostBootstrap(pending) {
  const intent = verifiedHostBootstrapIntent(pending);
  assert.equal(intent.role, "extensions");
  const environment = Object.freeze({
    ...productionReadonlyEnvironment(process.env),
    PUBLISH: "false",
    REBUILD: "",
  });
  for (const [key, value] of Object.entries({
    GITHUB_SHA: intent.source,
    GITHUB_RUN_ID: String(intent.extensions.run),
    GITHUB_RUN_ATTEMPT: String(intent.extensions.runAttempt),
    GITHUB_JOB: "publish",
    RUNNER_OS: "macOS",
  }))
    assert.equal(environment[key], value);
  assert(environment.GITHUB_TOKEN);
  await intent.completed();
  const { directory, checkSource, prepareTag } = await nativeContext(
    intent,
    environment,
  );
  const facts = async () => {
    await intent.completed();
    const run = await metadata(`/actions/runs/${intent.host.run}`, environment);
    const jobs = await metadata(
      `/actions/runs/${intent.host.run}/attempts/${intent.host.runAttempt}/jobs?per_page=100`,
      environment,
    );
    const release = await metadata(
      `/releases/tags/${intent.host.tag}`,
      environment,
    );
    const tag = await metadata(`/git/ref/tags/${intent.host.tag}`, environment);
    return completedHostPublication(pending, { run, jobs, release, tag });
  };
  const publication = await facts();
  const files = [];
  for (const name of names) {
    await intent.completed();
    const asset = closedProductionAsset(publication.release, name);
    const target = join(directory, name);
    await downloadPublic({ ...asset, destination: target });
    await intent.completed();
    const actual = await boundedProductionFile(
      target,
      asset.bytes,
      false,
      name !== "Edith.dmg",
    );
    assert.equal(actual.sha256, asset.sha256);
    assert.equal(actual.byteCount, asset.bytes);
    files.push({ target, ...asset, dev: actual.dev, ino: actual.ino });
  }
  const document = async (name) =>
    closedJSON(
      (
        await boundedProductionFile(join(directory, name), 1024 ** 2)
      ).bytes.toString(),
      1024 ** 2,
    );
  const rawProof = await document("host-release-proof.json");
  assert.equal(rawProof.sourceCommit, intent.source);
  assert.equal(rawProof.version, intent.host.version);
  assert.equal(String(rawProof.build), String(intent.host.build));
  const proof = immutable(
    projection(rawProof, ["sourceCommit", "version", "build", "dmgSHA256"]),
  );
  toolchainProvenance(
    await document("toolchain-provenance.json"),
    intent.source,
    rawProof.hostExecutableSHA256,
  );
  prepareTag(publication.tag.object.sha);
  const releaseChannel = immutable(
    projection(publication.release, [
      "id",
      "tag_name",
      "target_commitish",
      "draft",
      "prerelease",
    ]),
  );
  const context = join(directory, "context.json");
  const handle = await open(context, "wx", 0o600);
  try {
    await handle.writeFile(
      JSON.stringify({
        template: intent.template,
        generation: "current",
        directory,
        releaseChannel,
        publication,
      }),
    );
    await handle.sync();
  } finally {
    await handle.close();
  }
  const contextSeal = await boundedProductionFile(context, 1024 ** 2);
  checkSource();
  const measured = nativeMeasure(context, environment);
  assert.deepEqual(Object.keys(measured).sort(), ["host", "qualification"]);
  validateMeasuredHost(measured.host, environment);
  for (const [key, value] of Object.entries({
    source: intent.source,
    run: intent.host.run,
    tag: intent.host.tag,
    version: intent.host.version,
    build: intent.host.build,
    proofSHA256: files.find(({ target }) =>
      target.endsWith("/host-release-proof.json"),
    ).sha256,
    dmgSHA256: proof.dmgSHA256,
    dmgBytes: files.find(({ target }) => target.endsWith("/Edith.dmg")).bytes,
    dmgURL: files.find(({ target }) => target.endsWith("/Edith.dmg")).url,
    appcastSHA256: files.find(({ target }) => target.endsWith("/appcast.xml"))
      .sha256,
    hostExecutableSHA256: rawProof.hostExecutableSHA256,
  }))
    assert.equal(measured.host[key], value);
  for (const key of [
    "teamIdentifier",
    "certificateCategory",
    "designatedRequirement",
    "hostABI",
    "architecture",
  ])
    assert.equal(measured.host[key], intent.template.hosts.previous[key]);
  assert.notEqual(
    measured.host.normalizedUnsignedSHA256,
    intent.template.hosts.previous.normalizedUnsignedSHA256,
  );
  assert.deepEqual(measured.qualification.releaseChannel, releaseChannel);
  const { verifyCohortReleaseStamp } = await import(
    "../extension-stage-continuity.mjs"
  );
  const state = { closed: false, pending };
  const revalidate = async () => {
    try {
      assert(!state.closed);
      checkSource();
      const fresh = await facts();
      assert.deepEqual(fresh, publication);
      for (const file of files) {
        const current = await boundedProductionFile(
          file.target,
          file.bytes,
          false,
          false,
        );
        assert.equal(current.byteCount, file.bytes);
        assert.equal(current.sha256, file.sha256);
        assert.equal(current.dev, file.dev);
        assert.equal(current.ino, file.ino);
      }
      const currentContext = await boundedProductionFile(
        context,
        contextSeal.byteCount,
      );
      for (const key of ["sha256", "byteCount", "dev", "ino"])
        assert.equal(currentContext[key], contextSeal[key]);
      const stamp = await verifyCohortReleaseStamp(
        {
          source: intent.source,
          host: intent.host,
          proof,
          release: releaseChannel,
        },
        { fetchMetadata: (path) => metadata(`/${path}`, environment) },
      );
      await intent.completed();
      checkSource();
      assert(!state.closed);
      return immutable({
        intent,
        release: releaseChannel,
        proof,
        host: measured.host,
        qualification: measured.qualification,
        continuation: stamp.continuation,
        directory,
      });
    } catch (error) {
      state.closed = true;
      throw error;
    }
  };
  const value = await revalidate();
  state.identity = immutable({ ...value, revalidate });
  const capability = Object.freeze({});
  admissions.set(capability, state);
  return capability;
}
