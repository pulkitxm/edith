import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { closedJSON, successfulRun } from "./contract.mjs";
import { publicationStep } from "./evidence.mjs";
import { productionReadonlyEnvironment } from "./production-catalog-channel.mjs";

const admissions = new WeakMap();
const sourcePattern = /^[a-f0-9]{40}$/;
const actors = [65671483, 320458784];
const integer = (value) => assert(Number.isSafeInteger(value) && value > 0);
const freeze = (value) => {
  if (value && typeof value === "object") {
    for (const item of Object.values(value)) freeze(item);
    Object.freeze(value);
  }
  return value;
};
export function parseHostBootstrapTemplate(text, environment) {
  return closedJSON(
    execFileSync(
      "python3",
      [
        "-I",
        "-B",
        "-c",
        "import importlib.util,json,sys;s=importlib.util.spec_from_file_location('cohort',sys.argv[1]);m=importlib.util.module_from_spec(s);s.loader.exec_module(m);print(json.dumps(m.bootstrap_template(sys.stdin.read())))",
        fileURLToPath(new URL("./production-cohort.py", import.meta.url)),
      ],
      {
        input: text,
        env: productionReadonlyEnvironment(environment),
        timeout: 60000,
        maxBuffer: 65536,
      },
    ).toString(),
    65536,
  );
}
export async function readHostBootstrapAPI(path, environment, fetch_ = fetch) {
  assert(
    /^\/(?:actions\/runs\/[0-9]+(?:\/attempts\/[0-9]+\/jobs\?per_page=100)?|git\/ref\/heads\/main)$/.test(
      path,
    ),
  );
  const response = await fetch_(
    `https://api.github.com/repos/pulkitxm/edith${path}`,
    {
      signal: AbortSignal.timeout(15000),
      headers: {
        Accept: "application/vnd.github+json",
        "Cache-Control": "no-cache",
        Authorization: `Bearer ${environment.GITHUB_TOKEN ?? environment.GH_TOKEN}`,
      },
    },
  );
  assert.equal(response.status, 200);
  const reader = response.body.getReader();
  const chunks = [];
  let used = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      used += value.length;
      assert(used <= 1024 ** 2);
      chunks.push(value);
    }
  } finally {
    await reader.cancel();
  }
  return closedJSON(Buffer.concat(chunks).toString(), 1024 ** 2);
}
function admitEnvironment(environment, source) {
  for (const [key, expected] of Object.entries({
    GITHUB_ACTIONS: "true",
    RUNNER_ENVIRONMENT: "github-hosted",
    GITHUB_REPOSITORY: "pulkitxm/edith",
    GITHUB_REPOSITORY_ID: "1289153439",
    GITHUB_EVENT_NAME: "workflow_dispatch",
    GITHUB_REF: "refs/heads/main",
    PUBLIC_RELEASE_VERIFICATION: "1",
    GITHUB_SHA: source,
    GITHUB_JOB: "publish",
  }))
    assert.equal(environment[key], expected);
  assert(sourcePattern.test(source));
  assert(actors.includes(Number(environment.GITHUB_ACTOR_ID)));
  for (const key of ["GITHUB_RUN_ID", "GITHUB_RUN_ATTEMPT"])
    assert(/^[1-9][0-9]*$/.test(environment[key] ?? ""));
  assert(environment.GITHUB_TOKEN || environment.GH_TOKEN);
  for (const key of [
    "NODE_OPTIONS",
    "NODE_PATH",
    "PYTHONPATH",
    "PYTHONHOME",
    "CFFIXED_USER_HOME",
    "SSH_AUTH_SOCK",
  ])
    assert.equal(environment[key], undefined);
  assert(!Object.keys(environment).some((key) => key.startsWith("EDITH_")));
  assert.equal(environment.REBUILD ?? "", "");
  assert(["Linux", "macOS"].includes(environment.RUNNER_OS));
  return environment.RUNNER_OS === "Linux" ? "host" : "extensions";
}
function runIdentity(run, expected, path) {
  assert.equal(run.repository?.full_name, "pulkitxm/edith");
  assert.equal(run.repository?.id, 1289153439);
  assert.equal(run.id, expected.run);
  assert.equal(run.run_attempt, expected.runAttempt);
  assert.equal(run.head_sha, expected.source);
  assert.equal(run.head_branch, "main");
  assert.equal(run.event, "workflow_dispatch");
  assert.equal(run.path, path);
  assert(actors.includes(run.actor?.id));
  if (run.triggering_actor) assert(actors.includes(run.triggering_actor.id));
}
function activeRun(run) {
  assert(["queued", "in_progress"].includes(run.status));
  assert.equal(run.conclusion, null);
}
export function verifiedHostBootstrapIntent(capability) {
  const value = admissions.get(capability);
  assert(value && !value.closed, "Unknown or retired host bootstrap admission");
  return value.identity;
}
export function retireHostBootstrapIntent(capability) {
  const value = admissions.get(capability);
  assert(value, "Unknown host bootstrap admission");
  value.closed = true;
}
export async function admitHostBootstrapIntent(
  text,
  environment,
  { fetchMetadata = (path) => readHostBootstrapAPI(path, environment) } = {},
) {
  const template = parseHostBootstrapTemplate(text, environment);
  const role = admitEnvironment(environment, template.source);
  const host = template.hosts.current;
  if (role === "host") {
    assert.equal(host.run, null);
    assert.equal(host.runAttempt, null);
    host.run = Number(environment.GITHUB_RUN_ID);
    host.runAttempt = Number(environment.GITHUB_RUN_ATTEMPT);
    for (const [key, value] of Object.entries({
      BUILT_SHA: host.source,
      RELEASE_TAG: host.tag,
      RELEASE_VERSION: host.version,
      RELEASE_BUILD: String(host.build),
      RELEASE_PRERELEASE: "true",
    }))
      assert.equal(environment[key], value);
  } else {
    integer(host.run);
    integer(host.runAttempt);
  }
  const owner = {
    source: template.source,
    run: Number(environment.GITHUB_RUN_ID),
    runAttempt: Number(environment.GITHUB_RUN_ATTEMPT),
  };
  integer(owner.run);
  integer(owner.runAttempt);
  const capability = Object.freeze({});
  const state = { closed: false };
  const current = () => assert(!state.closed);
  const ownerRun = async () => {
    current();
    const run = await fetchMetadata(`/actions/runs/${owner.run}`);
    current();
    runIdentity(
      run,
      owner,
      role === "host"
        ? ".github/workflows/ci.yml"
        : ".github/workflows/extensions.yml",
    );
    assert.equal(String(run.actor.id), environment.GITHUB_ACTOR_ID);
    activeRun(run);
    return run;
  };
  const pending = async () => {
    await ownerRun();
    const run = await fetchMetadata(`/actions/runs/${host.run}`);
    current();
    runIdentity(run, host, ".github/workflows/ci.yml");
    activeRun(run);
    const reference = await fetchMetadata("/git/ref/heads/main");
    current();
    assert.equal(reference.ref, "refs/heads/main");
    assert.equal(reference.object?.type, "commit");
    assert.equal(reference.object.sha, template.source);
    await ownerRun();
    return run;
  };
  const completed = async () => {
    assert.equal(role, "extensions");
    await ownerRun();
    const run = await fetchMetadata(`/actions/runs/${host.run}`);
    current();
    runIdentity(run, host, ".github/workflows/ci.yml");
    successfulRun(run, host.source, ".github/workflows/ci.yml");
    const jobs = await fetchMetadata(
      `/actions/runs/${host.run}/attempts/${host.runAttempt}/jobs?per_page=100`,
    );
    current();
    assert(jobs.total_count <= 100 && jobs.jobs.length === jobs.total_count);
    assert.equal(
      new Set(jobs.jobs.map((job) => job.id)).size,
      jobs.jobs.length,
    );
    for (const name of ["Build DMG", "Publish release"]) {
      const matches = jobs.jobs.filter((job) => job.name === name);
      assert.equal(matches.length, 1);
      integer(matches[0].id);
      assert.equal(matches[0].run_id, host.run);
      assert.equal(matches[0].status, "completed");
      assert.equal(matches[0].conclusion, "success");
    }
    await ownerRun();
    return run;
  };
  let observationJob;
  const observationOwner = async () => {
    await ownerRun();
    const jobs = await fetchMetadata(
      `/actions/runs/${owner.run}/attempts/${owner.runAttempt}/jobs?per_page=100`,
    );
    current();
    assert(jobs.total_count <= 100 && jobs.jobs.length === jobs.total_count);
    assert.equal(
      new Set(jobs.jobs.map((job) => job.id)).size,
      jobs.jobs.length,
    );
    for (const job of jobs.jobs) integer(job.id);
    const matches = jobs.jobs.filter((job) => job.name === "publish");
    assert.equal(matches.length, 1);
    const job = matches[0];
    assert.equal(job.run_id, owner.run);
    assert.equal(job.run_attempt, owner.runAttempt);
    assert.equal(job.head_sha, owner.source);
    assert.equal(job.status, "in_progress");
    assert.equal(job.conclusion, null);
    const steps = job.steps.filter((step) => step.name === publicationStep);
    assert.equal(steps.length, 1);
    assert.equal(steps[0].status, "in_progress");
    assert.equal(steps[0].conclusion, null);
    observationJob ??= job.id;
    assert.equal(job.id, observationJob);
    await ownerRun();
  };
  const hostState = async () => {
    try {
      assert.equal(role, "extensions");
      await observationOwner();
      const run = await fetchMetadata(`/actions/runs/${host.run}`);
      current();
      runIdentity(run, host, ".github/workflows/ci.yml");
      if (run.status === "completed") assert.equal(run.conclusion, "success");
      else activeRun(run);
      await observationOwner();
      return Object.freeze({ status: run.status, conclusion: run.conclusion });
    } catch (error) {
      state.closed = true;
      throw error;
    }
  };
  state.identity = freeze({
    source: template.source,
    host: { ...host },
    extensions:
      role === "extensions"
        ? { run: owner.run, runAttempt: owner.runAttempt }
        : null,
    previousCatalog: {
      schemaVersion: 1,
      assetName: `catalog-${template.catalogs.previous.revision}.json`,
      revision: template.catalogs.previous.revision,
      sha256: template.catalogs.previous.sha256,
      bytes: template.catalogs.previous.bytes,
    },
    template,
    role,
    revalidate: async () => {
      try {
        return await pending();
      } catch (error) {
        state.closed = true;
        throw error;
      }
    },
    completed,
    hostState,
  });
  admissions.set(capability, state);
  try {
    await pending();
    return capability;
  } catch (error) {
    state.closed = true;
    throw error;
  }
}

export async function verifiedCompletedHostBootstrap(capability) {
  const { completedHostBootstrap } = await import(
    "./production-completed-host.mjs"
  );
  return completedHostBootstrap(capability);
}
