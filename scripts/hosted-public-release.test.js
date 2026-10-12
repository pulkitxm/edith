import { describe, expect, test } from "bun:test";
import { mkdtemp, readFile, realpath, rm, stat } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  managedNativeBuildSteps,
  managedNativeTestSteps,
  shippingNativeTestSteps,
} from "./hosted-managed-views/native-ci-contract.mjs";
import {
  artifact,
  digest,
  downloadPublic,
  hosted,
  nativeRun,
  productionRun,
  publicURL,
  request,
  toolchainProvenance,
} from "./hosted-public-release/contract.mjs";

import { validateInstallerProof } from "./hosted-public-release/verify.mjs";

const source = "a".repeat(40);
const fingerprints = Object.fromEntries(
  Array.from({ length: 39 }, (_, index) => [`owner${index}`, "b".repeat(64)]),
);
const definitions = Object.keys(fingerprints).map((id) => ({ id }));
function fixture(publishing) {
  const run = {
    id: 71,
    run_attempt: 1,
    repository: { full_name: "pulkitxm/edith" },
    head_sha: source,
    head_branch: "main",
    path: ".github/workflows/extensions.yml",
    event: publishing ? "push" : "pull_request",
    status: "completed",
    conclusion: "success",
  };
  const jobs = [
    "plan",
    "frozen-host",
    "tests",
    "publish",
    ...definitions.map(({ id }) => `build (${id})`),
  ].map((name, index) => ({
    id: index + 1,
    name,
    run_id: 71,
    status: "completed",
    conclusion: name === "publish" && !publishing ? "skipped" : "success",
    steps: (name === "tests"
      ? publishing
        ? shippingNativeTestSteps
        : managedNativeTestSteps
      : name.startsWith("build (")
        ? managedNativeBuildSteps
        : name === "publish" && publishing
          ? ["Publish immutable extension releases and the signed catalog"]
          : []
    ).map((name) => ({ name, status: "completed", conclusion: "success" })),
  }));
  const artifacts = definitions.map(({ id }, index) => ({
    id: index + 101,
    name: `extension-${id}`,
    size_in_bytes: 20,
    digest: `sha256:${"c".repeat(64)}`,
    expired: false,
    workflow_run: { id: 71, head_sha: source },
  }));
  return { run, jobs, artifacts, source, definitions, fingerprints };
}

describe("Public release admission", () => {
  test("all43 publishing native jobs are required independently of the nonpublishing tier", () => {
    expect(productionRun(fixture(true))).toHaveLength(39);
    expect(nativeRun(fixture(false)).originals).toHaveLength(39);
    expect(() => nativeRun(fixture(true))).toThrow();
    expect(() => productionRun(fixture(false))).toThrow();
  });
  test("partial, failed, skipped, cancelled, historical and missing actual steps fail closed", () => {
    for (const conclusion of ["failure", "skipped", "cancelled"]) {
      for (const name of [
        "plan",
        "tests",
        "frozen-host",
        "publish",
        "build (owner3)",
      ]) {
        const value = fixture(true);
        value.jobs.find((job) => job.name === name).conclusion = conclusion;
        expect(() => productionRun(value)).toThrow();
      }
    }
    for (const change of [
      (value) => value.jobs.pop(),
      (value) => (value.run.head_sha = "d".repeat(40)),
      (value) => (value.run.run_attempt = 0),
      (value) => (value.run.repository.full_name = "foreign/repo"),
      (value) => (value.run.head_branch = "foreign"),
      (value) => value.jobs[4].steps.pop(),
      (value) => (value.artifacts[0].expired = true),
      (value) => (value.artifacts[0].workflow_run.head_sha = "d".repeat(40)),
      (value) => (value.artifacts[0].digest = "sha256:wrong"),
      (value) => value.artifacts.push(value.artifacts[0]),
    ]) {
      const value = fixture(true);
      change(value);
      expect(() => productionRun(value)).toThrow();
    }
  });
  test("the request is bounded and closed with exact source and separate immutable runs", () => {
    const value = {
      source,
      packagesRun: 2,
      hostRun: 3,
      tag: "v1.2.3",
      updateIDs: [],
      retainedRuns: {},
    };
    expect(request(JSON.stringify(value))).toEqual(value);
    const duplicate = JSON.stringify(value).replace(
      '"source":',
      `"\\u0073ource":"${"d".repeat(40)}","source":`,
    );
    expect(() => request(duplicate)).toThrow();
    for (const change of [
      { extra: true },
      { source: "main" },
      { tag: "v01.2.3" },
      { updateIDs: ["owner0", "owner0"] },
      { packagesRun: 0 },
    ])
      expect(() => request(JSON.stringify({ ...value, ...change }))).toThrow();
    expect(() =>
      request(
        JSON.stringify(value).replace('"source":', '"source":"x","source":'),
      ),
    ).toThrow();
  });
  test("the runtime guard rejects local, untrusted and mutable dispatch contexts", () => {
    const environment = {
      GITHUB_ACTIONS: "true",
      RUNNER_ENVIRONMENT: "github-hosted",
      RUNNER_OS: "macOS",
      GITHUB_REPOSITORY: "pulkitxm/edith",
      GITHUB_EVENT_NAME: "workflow_dispatch",
      GITHUB_REF: "refs/heads/main",
      GITHUB_SHA: source,
      GITHUB_ACTOR_ID: "65671483",
      PUBLIC_RELEASE_VERIFICATION: "1",
      PUBLISH: "false",
      REBUILD: "",
    };
    hosted(environment, source);
    for (const [key, value] of Object.entries(environment)) {
      expect(() =>
        hosted({ ...environment, [key]: `${value}other` }, source),
      ).toThrow();
    }
  });
  test("artifact IDs, digests and exact source remain pinned", () => {
    const value = fixture(true);
    expect(
      artifact(value.artifacts, "extension-owner0", value.run, source)
        .artifactID,
    ).toBe(101);
  });
  test("public URLs cannot be authenticated API assets or token query substitutions", () => {
    publicURL(
      "https://github.com/pulkitxm/edith/releases/download/extensions%2Fowner%2F1.2.3-abc/owner.zip",
    );
    for (const url of [
      "http://github.com/pulkitxm/edith/releases/download/v1/Edith.dmg",
      "https://api.github.com/repos/pulkitxm/edith/releases/assets/1",
      "https://github.com/pulkitxm/edith/releases/download/v1/Edith.dmg?token=synthetic",
      "https://user:pass@github.com/pulkitxm/edith/releases/download/v1/Edith.dmg",
      "https://github.com/foreign/repo/releases/download/v1/a.zip",
    ])
      expect(() => publicURL(url)).toThrow();
    expect(() => publicURL("https://foreign.invalid/file", false)).toThrow();
  });
  test("unauthenticated exact public bytes survive a bounded allowed redirect", async () => {
    const root = await realpath(
      await mkdtemp(join(tmpdir(), "public-download-")),
    );
    const bytes = Buffer.from("synthetic public release");
    const url =
      "https://github.com/pulkitxm/edith/releases/download/v1.2.3/Edith.dmg";
    const options = [];
    try {
      const fetch_ = async (_url, configuration) => {
        options.push(configuration);
        return options.length === 1
          ? new Response(null, {
              status: 302,
              headers: {
                location:
                  "https://release-assets.githubusercontent.com/synthetic?signature=bounded",
              },
            })
          : new Response(bytes, {
              headers: { "content-length": String(bytes.length) },
            });
      };
      const receipt = await downloadPublic({
        url,
        bytes: bytes.length,
        sha256: digest(bytes),
        destination: join(root, "bytes"),
        fetch: fetch_,
      });
      expect(receipt.unauthenticatedHTTPS).toBe(true);
      expect(await readFile(join(root, "bytes"))).toEqual(bytes);
      expect((await stat(join(root, "bytes"))).mode & 0o777).toBe(0o600);
      for (const option of options) {
        expect(option.credentials).toBe("omit");
        expect(option.headers).toBeUndefined();
        expect(option.redirect).toBe("manual");
      }
      expect(receipt.finalOrigin).not.toContain("signature");
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });
  test("wrong hash, too many bytes, forbidden redirects and existing destinations reject", async () => {
    const root = await realpath(
      await mkdtemp(join(tmpdir(), "public-negative-")),
    );
    const bytes = Buffer.from("synthetic");
    const url =
      "https://github.com/pulkitxm/edith/releases/download/v1.2.3/Edith.dmg";
    try {
      for (const [index, changes] of [
        { sha256: "d".repeat(64) },
        { bytes: bytes.length - 1 },
        {
          fetch: async () =>
            new Response(null, {
              status: 302,
              headers: { location: "https://foreign.invalid/file" },
            }),
        },
      ].entries()) {
        await expect(
          downloadPublic({
            url,
            bytes: bytes.length,
            sha256: digest(bytes),
            destination: join(root, `bytes${index}`),
            fetch: async () => new Response(bytes),
            ...changes,
          }),
        ).rejects.toThrow();
      }
      const destination = join(root, "existing");
      await downloadPublic({
        url,
        bytes: bytes.length,
        sha256: digest(bytes),
        destination,
        fetch: async () => new Response(bytes),
      });
      await expect(
        downloadPublic({
          url,
          bytes: bytes.length,
          sha256: digest(bytes),
          destination,
          fetch: async () => new Response(bytes),
        }),
      ).rejects.toThrow();
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });
});

test("selective current publication still requires every planned native job and global gate", () => {
  const value = fixture(true);
  value.jobs = value.jobs.filter(
    ({ name }) => !name.startsWith("build (") || name === "build (owner0)",
  );
  value.artifacts = value.artifacts.filter(
    ({ name }) => name === "extension-owner0",
  );
  expect(productionRun({ ...value, plannedIDs: ["owner0"] })).toHaveLength(1);
  for (const conclusion of ["failure", "skipped", "cancelled"]) {
    for (const name of [
      "plan",
      "frozen-host",
      "tests",
      "publish",
      "build (owner0)",
    ]) {
      const changed = structuredClone(value);
      changed.jobs.find((job) => job.name === name).conclusion = conclusion;
      expect(() =>
        productionRun({ ...changed, plannedIDs: ["owner0"] }),
      ).toThrow();
    }
  }
});

test("recorded toolchain provenance binds the successful source and final signed executable without relabeling its builder phase", () => {
  const value = {
    schema: 1,
    sourceCommit: source,
    hostExecutableSHA256: "c".repeat(64),
    xcode: "Xcode 26.6\nBuild version 17G100",
    sdk: "26.6",
    builderSignature: "ad-hoc",
  };
  expect(toolchainProvenance(value, source, "c".repeat(64))).toEqual(value);
  for (const changed of [
    { sourceCommit: "d".repeat(40) },
    { hostExecutableSHA256: "d".repeat(64) },
    { xcode: "unmeasured" },
    { sdk: "26.6-extra" },
    { builderSignature: "Developer ID" },
    { certificateCategory: "Developer ID" },
    { schema: true },
  ])
    expect(() =>
      toolchainProvenance({ ...value, ...changed }, source, "c".repeat(64)),
    ).toThrow();
});

function installerFixture(updateIDs = ["owner3"]) {
  return {
    schema: 1,
    sourceCommit: source,
    owners: 39,
    installationVerified: true,
    productionSignaturesVerified: true,
    storeSelectionVerified: true,
    offlineCatalogAndSelectionVerified: true,
    removalVerified: true,
    removedIDs: definitions.map(({ id }) => id).sort(),
    busyRemovalAndLeaseDrainVerified: true,
    removalDataPreserved: true,
    reinstallationVerified: true,
    reinstalledIDs: definitions.map(({ id }) => id).sort(),
    reinstalledSelectionVerified: true,
    reinstallationDataPreserved: true,
    pendingRemovalsDrained: true,
    persistentSyntheticDataPreserved: true,
    preservationChecks: 45,
    publicVersionUpdateVerified: updateIDs.length > 0,
    updatedIDs: updateIDs,
    workerEnableDisableExecuted: false,
    workerProcessesStarted: 0,
    featureCodeExecuted: false,
  };
}

describe("Public installer removal and reinstallation proof", () => {
  const context = { source, current: definitions, updateIDs: ["owner3"] };

  test("a complete filesystem lifecycle admits an explicit subset update", () => {
    expect(() =>
      validateInstallerProof(installerFixture(), context),
    ).not.toThrow();
  });

  test("every lifecycle observation is independently required", () => {
    for (const field of [
      "installationVerified",
      "productionSignaturesVerified",
      "storeSelectionVerified",
      "offlineCatalogAndSelectionVerified",
      "removalVerified",
      "busyRemovalAndLeaseDrainVerified",
      "removalDataPreserved",
      "reinstallationVerified",
      "reinstalledSelectionVerified",
      "reinstallationDataPreserved",
      "pendingRemovalsDrained",
      "persistentSyntheticDataPreserved",
    ]) {
      const missing = installerFixture();
      delete missing[field];
      expect(() => validateInstallerProof(missing, context)).toThrow();
      for (const value of [false, 1, "true", null])
        expect(() =>
          validateInstallerProof(
            { ...installerFixture(), [field]: value },
            context,
          ),
        ).toThrow();
    }
  });

  test("partial or substituted removal and reinstall identities reject", () => {
    for (const field of ["removedIDs", "reinstalledIDs"]) {
      const ids = installerFixture()[field];
      for (const value of [
        undefined,
        [],
        ids.slice(1),
        [...ids.slice(1), ids[1]],
        [...ids.slice(1), "foreign"].sort(),
      ])
        expect(() =>
          validateInstallerProof(
            { ...installerFixture(), [field]: value },
            context,
          ),
        ).toThrow();
    }
  });

  test("filesystem proof rejects native execution claims and unpinned receipts", () => {
    for (const changed of [
      { workerEnableDisableExecuted: true },
      { workerProcessesStarted: 1 },
      { featureCodeExecuted: true },
      { workerEnableDisableExecuted: undefined },
      { workerProcessesStarted: undefined },
      { featureCodeExecuted: undefined },
      { sourceCommit: "d".repeat(40) },
      { owners: 38 },
      { schema: true },
      { preservationChecks: 44 },
      { preservationChecks: "45" },
    ])
      expect(() =>
        validateInstallerProof({ ...installerFixture(), ...changed }, context),
      ).toThrow();
  });
});
