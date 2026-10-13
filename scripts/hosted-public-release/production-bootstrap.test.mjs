import { test } from "bun:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import {
  admitHostBootstrapIntent,
  parseHostBootstrapTemplate,
  retireHostBootstrapIntent,
  verifiedHostBootstrapIntent,
} from "./production-bootstrap.mjs";

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
const template = {
  ...prepared,
  schema: 2,
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
function fixtures() {
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
  const values = {
    "/actions/runs/12": run(12, ".github/workflows/ci.yml"),
    "/actions/runs/13": run(13, ".github/workflows/extensions.yml"),
    "/git/ref/heads/main": {
      ref: "refs/heads/main",
      object: { type: "commit", sha: source },
    },
    "/actions/runs/12/attempts/1/jobs?per_page=100": {
      total_count: 2,
      jobs: ["Build DMG", "Publish release"].map((name, index) => ({
        id: 20 + index,
        run_id: 12,
        name,
        status: "completed",
        conclusion: "success",
      })),
    },
  };
  const calls = [];
  return {
    values,
    calls,
    fetchMetadata: async (path) => {
      calls.push(path);
      assert(Object.hasOwn(values, path));
      return structuredClone(values[path]);
    },
  };
}
test("pending host fields never satisfy the verified public request constructor", () => {
  assert.deepEqual(
    parseHostBootstrapTemplate(JSON.stringify(template), environment),
    template,
  );
  assert.throws(() =>
    execFileSync(
      "python3",
      [
        "-I",
        "-B",
        "-c",
        "import importlib.util,sys;s=importlib.util.spec_from_file_location('cohort','scripts/hosted-public-release/production-cohort.py');m=importlib.util.module_from_spec(s);s.loader.exec_module(m);m.request(sys.stdin.read())",
      ],
      { input: JSON.stringify(template), stdio: "pipe" },
    ),
  );
  for (const edit of [
    { schema: 1 },
    { application: "/tmp/synthetic.app" },
    { hosts: { ...template.hosts, current: prepared.hosts.current } },
    { packages: prepared.packages },
    { catalogs: prepared.catalogs },
  ])
    assert.throws(() =>
      parseHostBootstrapTemplate(
        JSON.stringify({ ...template, ...edit }),
        environment,
      ),
    );
  assert.throws(() =>
    parseHostBootstrapTemplate(
      JSON.stringify(template).replace('"schema":2', '"schema":2,"schema":2'),
      environment,
    ),
  );
});
test("only real run identity admission mints a frozen revocable capability", async () => {
  const f = fixtures();
  const cap = await admitHostBootstrapIntent(
    JSON.stringify(template),
    environment,
    f,
  );
  const intent = verifiedHostBootstrapIntent(cap);
  assert.equal(intent.host.run, 12);
  assert.deepEqual(intent.extensions, { run: 13, runAttempt: 1 });
  assert.equal(intent.previousCatalog.assetName, "catalog-1.json");
  assert(Object.isFrozen(intent.template.hosts.current));
  assert.throws(() => verifiedHostBootstrapIntent({ ...cap }));
  assert.throws(() => verifiedHostBootstrapIntent({ ...intent }));
  await intent.revalidate();
  retireHostBootstrapIntent(cap);
  assert.throws(() => verifiedHostBootstrapIntent(cap));
  await assert.rejects(intent.revalidate());
  assert(f.calls.filter((path) => path === "/actions/runs/12").length >= 2);
});
test("foreign ref repo actor source workflow and stale attempts reject admission", async () => {
  for (const edit of [
    { repository: { full_name: "other/repository", id: 1289153439 } },
    { repository: { full_name: "pulkitxm/edith", id: 1 } },
    { actor: { id: 1 } },
    { triggering_actor: { id: 1 } },
    { head_sha: "b".repeat(40) },
    { head_branch: "other" },
    { event: "pull_request" },
    { path: ".github/workflows/extensions.yml" },
    { run_attempt: 2 },
    { status: "completed", conclusion: "cancelled" },
  ]) {
    const f = fixtures();
    Object.assign(f.values["/actions/runs/12"], edit);
    await assert.rejects(
      admitHostBootstrapIntent(JSON.stringify(template), environment, f),
    );
  }
});
test("cancelled owner or host main movement during a later readiness poll cannot retain authority", async () => {
  for (const changed of ["host", "owner", "main", "attempt"]) {
    const f = fixtures();
    const cap = await admitHostBootstrapIntent(
      JSON.stringify(template),
      environment,
      f,
    );
    if (changed === "main")
      f.values["/git/ref/heads/main"].object.sha = "b".repeat(40);
    else if (changed === "attempt")
      f.values["/actions/runs/12"].run_attempt = 2;
    else
      Object.assign(
        f.values[changed === "host" ? "/actions/runs/12" : "/actions/runs/13"],
        { status: "completed", conclusion: "cancelled" },
      );
    await assert.rejects(verifiedHostBootstrapIntent(cap).revalidate());
  }
});
test("host self-admission captures its actual run and rejects supplied future run IDs", async () => {
  const pending = structuredClone(template);
  pending.hosts.current.run = null;
  pending.hosts.current.runAttempt = null;
  const hostEnvironment = {
    ...environment,
    RUNNER_OS: "Linux",
    GITHUB_RUN_ID: "12",
    BUILT_SHA: source,
    RELEASE_TAG: "v0.0.402",
    RELEASE_VERSION: "0.0.402",
    RELEASE_BUILD: "2",
    RELEASE_PRERELEASE: "true",
  };
  const cap = await admitHostBootstrapIntent(
    JSON.stringify(pending),
    hostEnvironment,
    fixtures(),
  );
  assert.equal(verifiedHostBootstrapIntent(cap).host.run, 12);
  assert.equal(verifiedHostBootstrapIntent(cap).extensions, null);
  await assert.rejects(
    admitHostBootstrapIntent(
      JSON.stringify(template),
      hostEnvironment,
      fixtures(),
    ),
  );
  await assert.rejects(
    admitHostBootstrapIntent(
      JSON.stringify(pending),
      { ...hostEnvironment, RELEASE_BUILD: "3" },
      fixtures(),
    ),
  );
});
test("completed conversion requires actual terminal success and both unique current-attempt native release jobs", async () => {
  const f = fixtures();
  const cap = await admitHostBootstrapIntent(
    JSON.stringify(template),
    environment,
    f,
  );
  const intent = verifiedHostBootstrapIntent(cap);
  await assert.rejects(intent.completed());
  Object.assign(f.values["/actions/runs/12"], {
    status: "completed",
    conclusion: "success",
  });
  assert.equal((await intent.completed()).id, 12);
  for (const mutate of [
    (jobs) => {
      jobs.jobs[0].conclusion = "failure";
    },
    (jobs) => {
      jobs.jobs[1].run_id = 14;
    },
    (jobs) => {
      jobs.jobs[1].name = "Build DMG";
    },
    (jobs) => {
      jobs.jobs[1].id = jobs.jobs[0].id;
    },
    (jobs) => {
      jobs.total_count = 3;
    },
  ]) {
    const saved = structuredClone(
      f.values["/actions/runs/12/attempts/1/jobs?per_page=100"],
    );
    mutate(f.values["/actions/runs/12/attempts/1/jobs?per_page=100"]);
    await assert.rejects(intent.completed());
    f.values["/actions/runs/12/attempts/1/jobs?per_page=100"] = saved;
  }
});
test("ambient overrides wrong owner and diagnostic modes cannot admit host publication", async () => {
  for (const edit of [
    { GITHUB_REF: "refs/heads/other" },
    { GITHUB_ACTOR_ID: "1" },
    { GITHUB_SHA: "b".repeat(40) },
    { GITHUB_JOB: "dmg" },
    { REBUILD: "v0.0.402" },
    { NODE_OPTIONS: "--synthetic" },
    { EDITH_SYNTHETIC: "1" },
  ])
    await assert.rejects(
      admitHostBootstrapIntent(
        JSON.stringify(template),
        { ...environment, ...edit },
        fixtures(),
      ),
    );
});
