import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { constants } from "node:fs";
import { lstat, open, realpath, rm } from "node:fs/promises";
import { resolve } from "node:path";
import { parseExpression } from "@babel/parser";
import {
  managedNativeBuildSteps,
  managedNativeTestSteps,
} from "../hosted-managed-views/native-ci-contract.mjs";
import { validateCIArtifactSet } from "../hosted-managed-views/package-preparation.mjs";

export const repository = "pulkitxm/edith";
const hash = /^[a-f0-9]{64}$/;
const commit = /^[a-f0-9]{40}$/;
export const digest = (bytes) =>
  createHash("sha256").update(bytes).digest("hex");
const integer = (value, maximum = Number.MAX_SAFE_INTEGER) =>
  assert(Number.isSafeInteger(value) && value > 0 && value <= maximum);

export function request(value) {
  assert(typeof value === "string" && Buffer.byteLength(value) <= 4096);
  const result = JSON.parse(value);
  const tree = parseExpression(value);
  function unique(node) {
    if (node.type === "ObjectExpression") {
      const keys = node.properties.map((property) => property.key.value);
      assert.equal(
        new Set(keys).size,
        keys.length,
        "Duplicate decoded request key",
      );
      for (const property of node.properties) unique(property.value);
    } else if (node.type === "ArrayExpression") {
      for (const entry of node.elements) unique(entry);
    }
  }
  unique(tree);
  assert.deepEqual(Object.keys(result).sort(), [
    "hostRun",
    "packagesRun",
    "retainedRuns",
    "source",
    "tag",
    "updateIDs",
  ]);
  assert.match(result.source, commit);
  assert.match(
    result.tag,
    /^v(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)$/,
  );
  for (const key of ["packagesRun", "hostRun"]) integer(result[key]);
  assert(Array.isArray(result.updateIDs) && result.updateIDs.length <= 39);
  assert.equal(new Set(result.updateIDs).size, result.updateIDs.length);
  for (const id of result.updateIDs)
    assert.match(id, /^[A-Za-z][A-Za-z0-9_-]{0,63}$/);
  assert(
    result.retainedRuns &&
      typeof result.retainedRuns === "object" &&
      !Array.isArray(result.retainedRuns),
  );
  assert(Object.keys(result.retainedRuns).length <= 39);
  for (const [id, runID] of Object.entries(result.retainedRuns)) {
    assert.match(id, /^[A-Za-z][A-Za-z0-9_-]{0,63}$/);
    integer(runID);
    assert.notEqual(runID, result.packagesRun);
  }
  return result;
}

export function hosted(environment, expectedSHA) {
  assert.match(expectedSHA, commit);
  for (const [key, expected] of Object.entries({
    GITHUB_ACTIONS: "true",
    RUNNER_ENVIRONMENT: "github-hosted",
    RUNNER_OS: "macOS",
    GITHUB_REPOSITORY: repository,
    GITHUB_EVENT_NAME: "workflow_dispatch",
    GITHUB_REF: "refs/heads/main",
    GITHUB_SHA: expectedSHA,
    PUBLIC_RELEASE_VERIFICATION: "1",
    PUBLISH: "false",
    REBUILD: "",
  }))
    assert.equal(environment[key], expected);
  assert(["65671483", "320458784"].includes(environment.GITHUB_ACTOR_ID));
}

export function successfulRun(run, source, path) {
  assert.equal(run.repository?.full_name, repository);
  integer(run.id);
  integer(run.run_attempt);
  assert.equal(run.head_sha, source);
  assert.equal(run.path, path);
  assert.equal(run.status, "completed");
  assert.equal(run.conclusion, "success");
}

export function artifact(artifacts, name, run, source) {
  const matches = artifacts.filter((value) => value.name === name);
  assert.equal(matches.length, 1, `Require one immutable ${name} artifact`);
  const value = matches[0];
  integer(value.id);
  integer(value.size_in_bytes, 2 * 1024 ** 3);
  assert.equal(value.expired, false);
  assert.equal(value.workflow_run?.id, run.id);
  assert.equal(value.workflow_run?.head_sha, source);
  assert.match(value.digest, /^sha256:[a-f0-9]{64}$/);
  return {
    artifactID: value.id,
    artifactBytes: value.size_in_bytes,
    artifactSHA256: value.digest.slice(7),
  };
}

export function nativeRun({
  run,
  jobs,
  artifacts,
  source,
  definitions,
  fingerprints,
}) {
  successfulRun(run, source, ".github/workflows/extensions.yml");
  assert(["pull_request", "workflow_dispatch"].includes(run.event));
  return validateCIArtifactSet({
    repository,
    run,
    jobs,
    artifacts,
    sourceCommit: source,
    definitions,
    fingerprints,
  });
}

export function productionRun({
  run,
  jobs,
  artifacts,
  source,
  definitions,
  fingerprints,
  plannedIDs = definitions.map(({ id }) => id),
}) {
  successfulRun(run, source, ".github/workflows/extensions.yml");
  assert(["push", "workflow_dispatch"].includes(run.event));
  assert.equal(run.head_branch, "main");
  assert.equal(definitions.length, 39);
  assert.equal(new Set(definitions.map(({ id }) => id)).size, 39);
  assert.deepEqual(
    Object.keys(fingerprints).sort(),
    definitions.map(({ id }) => id).sort(),
  );
  assert(plannedIDs.length > 0 && plannedIDs.length <= 39);
  assert.equal(new Set(plannedIDs).size, plannedIDs.length);
  assert(
    plannedIDs.every((id) =>
      definitions.some((definition) => definition.id === id),
    ),
  );
  const expected = [
    "plan",
    "frozen-host",
    "tests",
    "publish",
    ...plannedIDs.map((id) => `build (${id})`),
  ];
  assert.equal(jobs.length, plannedIDs.length + 4);
  assert.equal(new Set(jobs.map(({ id }) => id)).size, plannedIDs.length + 4);
  assert.deepEqual(jobs.map(({ name }) => name).sort(), expected.sort());
  for (const job of jobs) {
    integer(job.id);
    assert.equal(job.run_id, run.id);
    assert.equal(job.status, "completed");
    assert.equal(job.conclusion, "success");
    const names =
      job.name === "tests"
        ? managedNativeTestSteps
        : job.name.startsWith("build (")
          ? managedNativeBuildSteps
          : job.name === "publish"
            ? ["Publish immutable extension releases and the signed catalog"]
            : [];
    for (const name of names) {
      const matching = job.steps.filter((step) => step.name === name);
      assert.equal(matching.length, 1);
      assert.equal(matching[0].status, "completed");
      assert.equal(matching[0].conclusion, "success");
    }
  }
  return plannedIDs.map((id) => ({
    extensionID: id,
    sourceFingerprint: fingerprints[id],
    ...artifact(artifacts, `extension-${id}`, run, source),
  }));
}

export function hostRun({ run, jobs, artifacts, source }) {
  successfulRun(run, source, ".github/workflows/ci.yml");
  assert(["push", "workflow_dispatch"].includes(run.event));
  assert.equal(run.head_branch, "main");
  for (const name of ["Build DMG", "Publish release"]) {
    const matching = jobs.filter((job) => job.name === name);
    assert.equal(matching.length, 1);
    assert.equal(matching[0].run_id, run.id);
    assert.equal(matching[0].status, "completed");
    assert.equal(matching[0].conclusion, "success");
    const steps =
      name === "Build DMG"
        ? [
            "Record the source-bound static host release proof",
            "Generate the signed appcast",
            "Verify code signatures",
          ]
        : ["Commit and tag the release", "Publish the release"];
    for (const stepName of steps) {
      const steps_ = matching[0].steps.filter((step) => step.name === stepName);
      assert.equal(steps_.length, 1);
      assert.equal(steps_[0].status, "completed");
      assert.equal(steps_[0].conclusion, "success");
    }
  }
  return {
    bytes: artifact(artifacts, "release-macos", run, source),
    proof: artifact(artifacts, "host-release-proof", run, source),
  };
}

export function currentPackages(catalog, definitions, fingerprints) {
  return definitions.map((definition) => {
    const matching = catalog.packages.filter(
      (row) =>
        row.id === definition.id &&
        row.hostABI === definition.hostABI &&
        row.architecture === "arm64" &&
        row.sourceFingerprint === fingerprints[definition.id],
    );
    assert.equal(
      matching.length,
      1,
      `Require one current published ${definition.id} package`,
    );
    const row = matching[0];
    assert.deepEqual(row.dependencies, definition.dependencies ?? []);
    assert.equal(row.minimumSystemVersion, definition.minimumSystemVersion);
    assert.equal(
      row.downloadURL,
      `https://github.com/${repository}/releases/download/${encodeURIComponent(`extensions/${row.id}/${row.version}-${row.sourceFingerprint.slice(0, 20)}`)}/${row.id}.zip`,
    );
    return row;
  });
}
export function publicURL(value, initial = true) {
  const url = new URL(value);
  assert.equal(url.protocol, "https:");
  assert(!url.username && !url.password && !url.port && !url.hash);
  assert.equal(url.href, value);
  if (initial) {
    assert.equal(url.hostname, "github.com");
    assert(!url.search);
    assert(
      /^\/pulkitxm\/edith\/releases\/download\/(?:[A-Za-z0-9._-]|%2F)+\/[A-Za-z0-9._-]+$/.test(
        url.pathname,
      ),
    );
  } else {
    assert(
      [
        "github.com",
        "release-assets.githubusercontent.com",
        "objects.githubusercontent.com",
      ].includes(url.hostname),
    );
    assert(value.length <= 16384);
    if (url.hostname === "github.com") publicURL(value);
  }
  return url;
}
export async function downloadPublic({
  url,
  bytes,
  sha256,
  destination,
  fetch: fetch_ = fetch,
}) {
  publicURL(url);
  integer(bytes, 1024 ** 3);
  assert.match(sha256, hash);
  assert.equal(resolve(destination), destination);
  assert.equal(
    await realpath(resolve(destination, "..")),
    resolve(destination, ".."),
  );
  const parent = await lstat(resolve(destination, ".."));
  assert(
    parent.isDirectory() &&
      parent.uid === process.getuid() &&
      (parent.mode & 0o7777) === 0o700,
  );
  const signal = AbortSignal.timeout(15 * 60 * 1000);
  let current = url,
    file,
    reader;
  try {
    let response;
    for (let index = 0; index < 6; index++) {
      publicURL(current, index === 0);
      response = await fetch_(current, {
        redirect: "manual",
        credentials: "omit",
        signal,
      });
      if (![301, 302, 303, 307, 308].includes(response.status)) break;
      const location = response.headers.get("location");
      assert(location);
      current = new URL(location, current).href;
      await response.body?.cancel();
      response = undefined;
    }
    assert.equal(response?.status, 200);
    assert(response.body);
    const length = response.headers.get("content-length");
    if (length !== null) assert.equal(length, String(bytes));
    file = await open(
      destination,
      constants.O_WRONLY |
        constants.O_CREAT |
        constants.O_EXCL |
        constants.O_NOFOLLOW,
      0o600,
    );
    reader = response.body.getReader();
    const checksum = createHash("sha256");
    let actual = 0;
    while (true) {
      let timer;
      const next = await Promise.race([
        reader.read(),
        new Promise((_, reject) => {
          timer = setTimeout(
            () => reject(new Error("Public download stalled")),
            60000,
          );
        }),
      ]).finally(() => clearTimeout(timer));
      if (next.done) break;
      actual += next.value.length;
      assert(actual <= bytes);
      checksum.update(next.value);
      await file.writeFile(next.value);
    }
    assert.equal(actual, bytes);
    assert.equal(checksum.digest("hex"), sha256);
    await file.sync();
    const info = await file.stat();
    assert(
      info.isFile() &&
        info.nlink === 1 &&
        info.uid === process.getuid() &&
        (info.mode & 0o7777) === 0o600 &&
        info.size === bytes,
    );
    await file.close();
    file = undefined;
    return {
      url,
      finalOrigin: new URL(current).origin,
      bytes,
      sha256,
      unauthenticatedHTTPS: true,
      matchesPinnedBytes: true,
    };
  } catch (error) {
    await reader?.cancel(error).catch(() => {});
    await file?.close().catch(() => {});
    if (file) await rm(destination, { force: true });
    throw error;
  }
}

export function composeLineage({
  definitions,
  fingerprints,
  current,
  retained,
  requestedRuns,
}) {
  const changed = new Set(current.plan.plannedIDs);
  assert.equal(changed.size, current.plan.plannedIDs.length);
  const remaining = definitions
    .map(({ id }) => id)
    .filter((id) => !changed.has(id));
  assert.deepEqual(Object.keys(requestedRuns).sort(), remaining.sort());
  return definitions.map(({ id }) => {
    const admission = changed.has(id)
      ? current
      : retained.get(requestedRuns[id]);
    assert(admission, `Missing immutable production lineage for ${id}`);
    assert.equal(admission.value.run.head_sha, admission.source);
    assert.equal(
      admission.value.run.id,
      changed.has(id) ? current.value.run.id : requestedRuns[id],
    );
    assert.equal(admission.metadata.sourceCommit, admission.source);
    assert.equal(admission.metadata.sourceTreeDirty, false);
    const matches = admission.rows.filter((row) => row.extensionID === id);
    assert.equal(
      matches.length,
      1,
      `Require an actual successful planned build for ${id}`,
    );
    const row = matches[0];
    assert.equal(row.sourceFingerprint, fingerprints[id]);
    return {
      ...row,
      sourceCommit: admission.source,
      runID: admission.value.run.id,
      frozen: admission.frozen,
      frozenSHA: admission.frozenSHA,
      qualification: changed.has(id)
        ? "current-source-build"
        : "retained-unchanged-fingerprint",
    };
  });
}
