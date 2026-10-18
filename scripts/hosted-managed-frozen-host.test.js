import { expect, test } from "bun:test";
import {
  readFrozenHostArtifact,
  validateFrozenHostArtifact,
  validateFrozenHostMetadata,
} from "./hosted-managed-views/frozen-host.mjs";

const source = "a".repeat(40),
  hash = "b".repeat(64);
const input = () => ({
  runID: 42,
  sourceCommit: source,
  run: {
    id: 42,
    head_sha: source,
    path: ".github/workflows/extensions.yml",
    status: "completed",
    conclusion: "success",
  },
  jobs: [
    {
      id: 10,
      run_id: 42,
      name: "frozen-host",
      status: "completed",
      conclusion: "success",
    },
  ],
  artifacts: [
    {
      id: 11,
      name: "frozen-extension-host",
      size_in_bytes: 100,
      digest: `sha256:${hash}`,
      expired: false,
      workflow_run: { id: 42, head_sha: source },
    },
  ],
});
test("frozen host receipt binds actual successful source, job and immutable artifact independently of test Host", () => {
  expect(validateFrozenHostArtifact(input())).toMatchObject({
    sourceCommit: source,
    artifactID: 11,
    jobID: 10,
    artifactSHA256: hash,
  });
  for (const change of [
    (v) => (v.run.head_sha = "c".repeat(40)),
    (v) => (v.run.conclusion = "failure"),
    (v) => (v.jobs[0].conclusion = "skipped"),
    (v) => v.jobs.push(v.jobs[0]),
    (v) => (v.artifacts[0].expired = true),
    (v) => (v.artifacts[0].workflow_run.head_sha = "d".repeat(40)),
    (v) => v.artifacts.push(v.artifacts[0]),
    (v) => (v.artifacts[0].digest = "unknown"),
  ]) {
    const value = input();
    change(value);
    expect(() => validateFrozenHostArtifact(value)).toThrow();
  }
  const metadata = {
    sourceCommit: source,
    sourceTreeDirty: false,
    hostExecutableSHA256: hash,
    architecture: "arm64",
    configuration: "Release",
    optimization: "Osize",
    linkTimeOptimization: "full",
    signature: "ad-hoc",
    xcode: "Xcode synthetic",
    sdk: "synthetic",
  };
  expect(validateFrozenHostMetadata(metadata, source, hash)).toEqual(metadata);
  for (const changed of [
    { sourceTreeDirty: true },
    { hostExecutableSHA256: "c".repeat(64) },
    { sourceCommit: "c".repeat(40) },
    { architecture: "x86_64" },
  ])
    expect(() =>
      validateFrozenHostMetadata({ ...metadata, ...changed }, source, hash),
    ).toThrow();
});
test("bounded GitHub metadata reads fail closed on auth errors and truncated pagination", async () => {
  const value = input();
  const fetch = async (url) =>
    new Response(
      JSON.stringify(
        url.includes("/jobs?")
          ? { total_count: 1, jobs: value.jobs }
          : url.includes("/artifacts?")
            ? { total_count: 1, artifacts: value.artifacts }
            : value.run,
      ),
    );
  expect(
    await readFrozenHostArtifact({ fetch, runID: 42, sourceCommit: source }),
  ).toMatchObject({ artifactID: 11 });
  await expect(
    readFrozenHostArtifact({
      fetch: async () => new Response("denied", { status: 403 }),
      runID: 42,
      sourceCommit: source,
    }),
  ).rejects.toThrow();
  await expect(
    readFrozenHostArtifact({
      fetch: async (url) =>
        url.includes("/jobs?")
          ? new Response(JSON.stringify({ total_count: 2, jobs: value.jobs }))
          : fetch(url),
      runID: 42,
      sourceCommit: source,
    }),
  ).rejects.toThrow();
});
