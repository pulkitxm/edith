import { expect, test } from "bun:test";
import { readFile } from "node:fs/promises";
import {
  readManagedChunkArtifacts,
  validateManagedChunkArtifacts,
} from "./hosted-managed-views/chunk-intake.mjs";
import {
  managedNativeBuildSteps,
  managedNativeTestSteps,
  validateNonpublishingNativeJobs,
} from "./hosted-managed-views/native-ci-contract.mjs";

const source = "a".repeat(40);
const definitions = JSON.parse(await readFile("Extensions/manifest.json"));
function nativeJobs() {
  return [
    "plan",
    "frozen-host",
    "tests",
    "publish",
    ...definitions.map(({ id }) => `build (${id})`),
  ].map((name, index) => ({
    id: index + 1,
    run_id: 42,
    name,
    status: "completed",
    conclusion: name === "publish" ? "skipped" : "success",
    steps: (name === "tests"
      ? managedNativeTestSteps
      : name.startsWith("build (")
        ? managedNativeBuildSteps
        : []
    ).map((name) => ({ name, status: "completed", conclusion: "success" })),
  }));
}
function input() {
  return {
    runID: 42,
    sourceCommit: source,
    run: {
      id: 42,
      head_sha: source,
      path: ".github/workflows/ci.yml",
      event: "workflow_dispatch",
      status: "in_progress",
    },
    jobs: [0, 1, 2].map((chunk) => ({
      id: chunk + 100,
      name: `hosted-managed-views / managed views (${chunk})`,
      run_id: 42,
      status: "completed",
      conclusion: "success",
    })),
    artifacts: [0, 1, 2].map((chunk) => ({
      id: chunk + 200,
      name: `hosted-managed-original-view-chunk-${chunk}`,
      size_in_bytes: 1000,
      expired: false,
      digest: `sha256:${"b".repeat(64)}`,
      workflow_run: { id: 42, head_sha: source },
    })),
  };
}

test("all43 native source jobs and every required lifecycle step must actually pass", () => {
  expect(() =>
    validateNonpublishingNativeJobs(nativeJobs(), definitions, 42),
  ).not.toThrow();
  for (const change of [
    (x) => x.pop(),
    (x) => x.push(x[0]),
    (x) => {
      x[0].id = x[1].id;
    },
    (x) => {
      x[0].run_id++;
    },
    (x) => {
      x[1].conclusion = "skipped";
    },
    (x) => {
      x[2].steps.pop();
    },
    (x) => {
      x[2].steps.push(x[2].steps[0]);
    },
    (x) => {
      x[3].conclusion = "success";
    },
    (x) => {
      x[4].steps[0].conclusion = "skipped";
    },
    (x) => {
      x[4].steps[0].conclusion = "failure";
    },
    (x) => {
      x[4].steps[0].status = "in_progress";
    },
  ]) {
    const jobs = nativeJobs();
    change(jobs);
    expect(() =>
      validateNonpublishingNativeJobs(jobs, definitions, 42),
    ).toThrow();
  }
});

test("aggregate binds allthree successful chunk jobs to unique current source artifacts", () => {
  const value = input();
  expect(
    validateManagedChunkArtifacts(value).map(({ chunk }) => chunk),
  ).toEqual([0, 1, 2]);
  for (const change of [
    (x) => {
      x.run.head_sha = "c".repeat(40);
    },
    (x) => {
      x.run.event = "pull_request";
    },
    (x) => {
      x.run.status = "completed";
      x.run.conclusion = "failure";
    },
    (x) => x.jobs.pop(),
    (x) => {
      x.jobs[0].conclusion = "skipped";
    },
    (x) => {
      x.jobs[0].conclusion = "failure";
    },
    (x) => {
      x.jobs[0].run_id++;
    },
    (x) => {
      x.jobs[0].id = x.jobs[1].id;
    },
    (x) => x.artifacts.pop(),
    (x) => x.artifacts.push(x.artifacts[0]),
    (x) => {
      x.artifacts[0].workflow_run.head_sha = "d".repeat(40);
    },
    (x) => {
      x.artifacts[0].workflow_run.id++;
    },
    (x) => {
      x.artifacts[0].expired = true;
    },
    (x) => {
      x.artifacts[0].size_in_bytes = 4 * 1024 ** 2 + 1;
    },
    (x) => {
      x.artifacts[0].digest = "bad";
    },
    (x) => {
      x.artifacts[0].id = x.artifacts[1].id;
    },
  ]) {
    const changed = input();
    change(changed);
    expect(() => validateManagedChunkArtifacts(changed)).toThrow();
  }
});

test("aggregate metadata uses only bounded current-run API inventories and aborts stalled reads", async () => {
  const value = input(),
    urls = [];
  const fetch = async (url) => {
    urls.push(url);
    const kind = url.includes("/jobs?")
      ? "jobs"
      : url.includes("/artifacts?")
        ? "artifacts"
        : null;
    return Response.json(
      kind
        ? { total_count: value[kind].length, [kind]: value[kind] }
        : value.run,
    );
  };
  expect(
    await readManagedChunkArtifacts({ fetch, runID: 42, sourceCommit: source }),
  ).toHaveLength(3);
  expect(urls.sort()).toEqual(
    [
      "https://api.github.com/repos/pulkitxm/edith/actions/runs/42",
      "https://api.github.com/repos/pulkitxm/edith/actions/runs/42/artifacts?per_page=100&page=1",
      "https://api.github.com/repos/pulkitxm/edith/actions/runs/42/jobs?per_page=100&page=1",
    ].sort(),
  );
  await expect(
    readManagedChunkArtifacts({
      fetch: async () => new Promise(() => {}),
      runID: 42,
      sourceCommit: source,
      signal: AbortSignal.timeout(10),
    }),
  ).rejects.toThrow();
  await expect(
    readManagedChunkArtifacts({
      fetch: async () => new Response(new ReadableStream({ start() {} })),
      runID: 42,
      sourceCommit: source,
      signal: AbortSignal.timeout(10),
    }),
  ).rejects.toThrow();
  await expect(
    readManagedChunkArtifacts({
      fetch: async () => Response.json({ total_count: 1001, jobs: [] }),
      runID: 42,
      sourceCommit: source,
    }),
  ).rejects.toThrow();
});
