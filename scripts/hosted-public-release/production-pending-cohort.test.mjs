import { test } from "bun:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import {
  admitHostBootstrapIntent,
  verifiedCompletedHostBootstrap,
  verifiedHostBootstrapIntent,
} from "./production-bootstrap.mjs";
import {
  completePendingProductionCohort,
  preparePendingProductionCohort,
  waitForCompletedHostBootstrap,
} from "./production-pending-cohort.mjs";
import { productionPublicationBudget } from "./production-publication-budget.mjs";
import { parseProductionCohortTemplate } from "./production-publication-coordinator.mjs";

const source = "a".repeat(40);
const original = JSON.parse(
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
const template = {
  ...original,
  schema: 2,
  hosts: {
    previous: original.hosts.previous,
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
  packages: { previous: original.packages.previous, current: null },
  catalogs: { previous: original.catalogs.previous, current: null },
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
async function fixture() {
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
    "/actions/runs/13/attempts/1/jobs?per_page=100": {
      total_count: 1,
      jobs: [
        {
          id: 30,
          run_id: 13,
          run_attempt: 1,
          head_sha: source,
          name: "publish",
          status: "in_progress",
          conclusion: null,
          steps: [
            {
              name: "Publish immutable extension releases and the signed catalog",
              status: "in_progress",
              conclusion: null,
            },
          ],
        },
      ],
    },
  };
  let hostReads = 0;
  const pending = await admitHostBootstrapIntent(
    JSON.stringify(template),
    environment,
    {
      fetchMetadata: async (path) => {
        assert(Object.hasOwn(values, path));
        if (path === "/actions/runs/12") hostReads++;
        return structuredClone(values[path]);
      },
    },
  );
  return { pending, values, hostReads: () => hostReads };
}

test("terminal host observation after the stamp does not supply a completed public capability", async () => {
  const f = await fixture();
  f.values["/git/ref/heads/main"].object.sha = "b".repeat(40);
  Object.assign(f.values["/actions/runs/12"], {
    status: "completed",
    conclusion: "success",
  });
  await waitForCompletedHostBootstrap(f.pending, productionPublicationBudget());
  await assert.rejects(verifiedCompletedHostBootstrap(f.pending));
  assert.equal(verifiedHostBootstrapIntent(f.pending).template.schema, 2);
  await assert.rejects(
    completePendingProductionCohort(
      { ...f.pending },
      productionPublicationBudget(),
    ),
  );
});

test("failed hosts and inactive publication jobs fail instead of waiting or retrying", async () => {
  for (const failure of ["host", "job"]) {
    const f = await fixture();
    const row =
      failure === "host"
        ? f.values["/actions/runs/12"]
        : f.values["/actions/runs/13/attempts/1/jobs?per_page=100"].jobs[0];
    Object.assign(row, { status: "completed", conclusion: "cancelled" });
    await assert.rejects(
      waitForCompletedHostBootstrap(f.pending, productionPublicationBudget()),
    );
    assert.throws(() => verifiedHostBootstrapIntent(f.pending));
  }
});

test("a host status response cannot reset a previously consumed shared budget", async () => {
  const f = await fixture();
  let ticks = 0;
  const remaining = productionPublicationBudget({
    now: () => (ticks++ < 2 ? 0 : 180 * 60 * 1000),
  });
  const before = f.hostReads();
  await assert.rejects(
    waitForCompletedHostBootstrap(f.pending, remaining),
    /expired/,
  );
  assert.equal(f.hostReads(), before + 1);
  await assert.rejects(
    waitForCompletedHostBootstrap(f.pending, remaining),
    /retired/,
  );
  assert.equal(f.hostReads(), before + 1);
});

test("exhausted preparation rejects before it can admit an intent or create input authority", async () => {
  let current = 0;
  const remaining = productionPublicationBudget({ now: () => current });
  current = 180 * 60 * 1000;
  await assert.rejects(
    preparePendingProductionCohort(JSON.stringify(template), remaining),
    /expired/,
  );
  await assert.rejects(
    waitForCompletedHostBootstrap({}, productionPublicationBudget()),
    /Unknown/,
  );
});

test("the actual E parser accepts only closed pending templates and does not admit supplied completed facts", () => {
  assert.deepEqual(
    parseProductionCohortTemplate(JSON.stringify(template), environment),
    template,
  );
  for (const changed of [
    { ...template, extraSuccess: true },
    {
      ...template,
      hosts: { ...template.hosts, current: original.hosts.current },
    },
    { ...template, packages: original.packages },
    { ...template, catalogs: original.catalogs },
  ])
    assert.throws(() =>
      parseProductionCohortTemplate(JSON.stringify(changed), environment),
    );
  assert.throws(() =>
    parseProductionCohortTemplate(
      JSON.stringify(template).replace('"schema":2', '"schema":2,"schema":2'),
      environment,
    ),
  );
});
