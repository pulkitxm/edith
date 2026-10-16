import { describe, expect, test } from "bun:test";
import { readFile } from "node:fs/promises";
import {
  absentExtensionsPathRoute,
  currentExtensionsRuns,
  unchangedCatalogPublication,
  unchangedExtensionsRun,
} from "./hosted-public-release/contract.mjs";

import { validateInstallerProof } from "./hosted-public-release/verify.mjs";

const source = "a".repeat(40);
const fingerprint = "b".repeat(64);
function catalogFixture() {
  const definitions = Array.from({ length: 39 }, (_, index) => ({
    id: `owner${index}`,
    hostABI: "syntheticABI",
    minimumSystemVersion: "14.0.0",
    dependencies: [],
  }));
  const fingerprints = Object.fromEntries(
    definitions.map(({ id }) => [id, fingerprint]),
  );
  return {
    catalog: {
      schemaVersion: 1,
      revision: 7,
      packages: definitions.map((definition) => ({
        ...definition,
        version: "1.0.0",
        architecture: "arm64",
        sourceFingerprint: fingerprint,
        sha256: "c".repeat(64),
        downloadBytes: 20,
        installedBytes: 30,
        downloadURL: `https://github.com/pulkitxm/edith/releases/download/${encodeURIComponent(`extensions/${definition.id}/1.0.0-${fingerprint.slice(0, 20)}`)}/${definition.id}.zip`,
      })),
    },
    definitions,
    fingerprints,
    priorDefinitions: structuredClone(definitions),
    priorFingerprints: structuredClone(fingerprints),
    plan: { include: [] },
  };
}
function noChangeFixture(id = 71) {
  const run = {
    id,
    run_attempt: 1,
    repository: { full_name: "pulkitxm/edith" },
    head_sha: source,
    head_branch: "main",
    path: ".github/workflows/extensions.yml",
    event: "push",
    status: "completed",
    conclusion: "success",
  };
  const jobs = ["plan", "frozen-host", "tests", "build", "publish"].map(
    (name, index) => ({
      id: index + 1,
      run_id: id,
      name,
      status: "completed",
      conclusion: name === "plan" ? "success" : "skipped",
      steps:
        name === "plan"
          ? [
              "Check portable publication and selective planning",
              "Require production publication from main",
              "Plan against the exact PR base or last trusted catalog",
            ].map((name) => ({
              name,
              status: "completed",
              conclusion: "success",
            }))
          : [],
    }),
  );
  return {
    run,
    jobs,
    artifacts: [
      {
        id: 101,
        name: "extension-plan",
        size_in_bytes: 20,
        digest: `sha256:${"c".repeat(64)}`,
        expired: false,
        workflow_run: { id, head_sha: source },
      },
    ],
    source,
  };
}
const workflow = {
  on: {
    push: {
      branches: ["main"],
      paths: [
        "Extensions/**",
        "scripts/*extension*",
        ".github/workflows/extensions.yml",
      ],
    },
  },
};

describe("Host-only reuse of an unchanged signed catalog publication", () => {
  test("all39 current contracts and exact empty plan match the publication source", () => {
    expect(() => unchangedCatalogPublication(catalogFixture())).not.toThrow();
    for (const mutate of [
      (value) => value.definitions.pop(),
      (value) => value.definitions.push(value.definitions[0]),
      (value) => {
        value.fingerprints.owner0 = "d".repeat(64);
      },
      (value) => {
        value.priorFingerprints.owner0 = "d".repeat(64);
      },
      (value) => {
        value.definitions[0].hostABI = "changedABI";
      },
      (value) => {
        value.definitions[0].minimumSystemVersion = "15.0.0";
      },
      (value) => {
        value.definitions[0].dependencies = ["owner1"];
      },
      (value) => {
        value.priorDefinitions[0].hostABI = "changedABI";
      },
      (value) => {
        value.plan.include.push({ id: "owner0" });
      },
      (value) => {
        value.catalog.packages[0].downloadURL =
          "https://github.com/pulkitxm/edith/releases/download/other/owner0.zip";
      },
    ]) {
      const value = catalogFixture();
      mutate(value);
      expect(() => unchangedCatalogPublication(value)).toThrow();
    }
  });

  test("every exact current run is queried across all pages before reuse", async () => {
    const runs = Array.from(
      { length: 101 },
      (_, index) => noChangeFixture(index + 1).run,
    );
    const paths = [];
    const result = await currentExtensionsRuns(source, async (path) => {
      paths.push(path);
      return {
        total_count: 101,
        workflow_runs:
          paths.length === 1 ? runs.slice(0, 100) : runs.slice(100),
      };
    });
    expect(result).toEqual(runs);
    expect(paths).toEqual(
      [1, 2].map(
        (page) =>
          `/actions/workflows/extensions.yml/runs?head_sha=${source}&per_page=100&page=${page}`,
      ),
    );
  });

  test("absence requires a successful empty exact query and rejects auth or malformed pages", async () => {
    const paths = [];
    expect(
      await currentExtensionsRuns(source, async (path) => {
        paths.push(path);
        return { total_count: 0, workflow_runs: [] };
      }),
    ).toEqual([]);
    expect(paths).toEqual([
      `/actions/workflows/extensions.yml/runs?head_sha=${source}&per_page=100&page=1`,
    ]);
    await expect(
      currentExtensionsRuns(source, async () => {
        throw new Error("401 synthetic authorization failure");
      }),
    ).rejects.toThrow("401");
    for (const response of [
      { total_count: 1, workflow_runs: [] },
      { total_count: 0, workflow_runs: [noChangeFixture().run] },
      { total_count: 1001, workflow_runs: [] },
      { total_count: -1, workflow_runs: [] },
      { total_count: 0 },
    ])
      await expect(
        currentExtensionsRuns(source, async () => response),
      ).rejects.toThrow();
  });

  test("failed, pending, cancelled, unrelated or nonproduction current runs cannot be ignored", async () => {
    for (const changes of [
      { conclusion: "failure" },
      { conclusion: "cancelled" },
      { conclusion: "timed_out" },
      { status: "in_progress", conclusion: null },
      { head_sha: "d".repeat(40) },
      { path: ".github/workflows/ci.yml" },
      { event: "pull_request" },
      { head_branch: "other" },
      { repository: { full_name: "synthetic/other" } },
      { run_attempt: 0 },
    ]) {
      const run = { ...noChangeFixture().run, ...changes };
      await expect(
        currentExtensionsRuns(source, async () => ({
          total_count: 1,
          workflow_runs: [run],
        })),
      ).rejects.toThrow();
    }
  });

  test("duplicate identities and changing totals fail a paginated query", async () => {
    const runs = Array.from(
      { length: 100 },
      (_, index) => noChangeFixture(index + 1).run,
    );
    for (const response of [
      { total_count: 101, workflow_runs: [runs[0]] },
      { total_count: 102, workflow_runs: [noChangeFixture(101).run] },
    ]) {
      let page = 0;
      await expect(
        currentExtensionsRuns(source, async () =>
          ++page === 1 ? { total_count: 101, workflow_runs: runs } : response,
        ),
      ).rejects.toThrow();
    }
  });

  test("actual whole success with only planning and skipped native jobs qualifies", () => {
    expect(unchangedExtensionsRun(noChangeFixture())).toEqual({
      artifactID: 101,
      artifactBytes: 20,
      artifactSHA256: "c".repeat(64),
    });
    const dispatch = noChangeFixture();
    dispatch.run.event = "workflow_dispatch";
    dispatch.jobs[0].steps[1].conclusion = "skipped";
    expect(() => unchangedExtensionsRun(dispatch)).not.toThrow();
    for (const mutate of [
      (value) => {
        value.run.conclusion = "failure";
      },
      (value) => {
        value.jobs[1].conclusion = "success";
      },
      (value) =>
        value.jobs[1].steps.push({
          name: "native work",
          status: "completed",
          conclusion: "success",
        }),
      (value) => {
        value.jobs[0].steps[0].conclusion = "skipped";
      },
      (value) => {
        value.jobs[0].steps[1].conclusion = "skipped";
      },
      (value) => value.jobs[0].steps.pop(),
      (value) => value.jobs[0].steps.push(value.jobs[0].steps[0]),
      (value) => {
        value.jobs[4].name = "build (owner0)";
      },
      (value) => {
        value.jobs[1].id = value.jobs[0].id;
      },
      (value) => {
        value.artifacts[0].expired = true;
      },
      (value) => {
        value.artifacts[0].size_in_bytes = 8 * 1024 ** 2 + 1;
      },
      (value) =>
        value.artifacts.push({
          ...value.artifacts[0],
          name: "extension-owner0",
        }),
    ]) {
      const value = noChangeFixture();
      mutate(value);
      expect(() => unchangedExtensionsRun(value)).toThrow();
    }
  });

  test("ordinary production skips exact-source validation admission", () => {
    for (const event of ["push", "workflow_dispatch"]) {
      const value = noChangeFixture();
      value.run.event = event;
      value.jobs[0].steps.splice(2, 0, {
        name: "Admit exact-source all-extension validation",
        status: "completed",
        conclusion: "skipped",
      });
      if (event === "workflow_dispatch")
        value.jobs[0].steps[1].conclusion = "skipped";
      expect(() => unchangedExtensionsRun(value)).not.toThrow();
    }
  });

  test("validation admission and failed current work cannot qualify production", () => {
    for (const mutate of [
      (value) => {
        value.jobs[0].steps[2].conclusion = "success";
      },
      (value) => {
        value.jobs[0].steps[2].conclusion = "failure";
      },
      (value) => {
        value.jobs[0].steps[2].conclusion = "cancelled";
      },
      (value) => {
        value.jobs[0].steps[2].status = "in_progress";
      },
      (value) => {
        value.jobs[0].steps[2].name = "Unknown validation admission";
      },
      (value) => value.jobs[0].steps.push(value.jobs[0].steps[2]),
      (value) => {
        value.jobs[3].conclusion = "failure";
      },
      (value) => {
        value.jobs[3].conclusion = "cancelled";
      },
      (value) => {
        value.jobs[3].conclusion = "success";
      },
      (value) => {
        value.run.conclusion = "failure";
      },
      (value) => {
        value.run.conclusion = "cancelled";
      },
    ]) {
      for (const event of ["push", "workflow_dispatch"]) {
        const value = noChangeFixture();
        value.run.event = event;
        value.jobs[0].steps.splice(2, 0, {
          name: "Admit exact-source all-extension validation",
          status: "completed",
          conclusion: "skipped",
        });
        if (event === "workflow_dispatch")
          value.jobs[0].steps[1].conclusion = "skipped";
        mutate(value);
        expect(() => unchangedExtensionsRun(value)).toThrow();
      }
    }
  });

  test("absent runs need a real source path-filter exclusion", async () => {
    expect(() =>
      absentExtensionsPathRoute(
        workflow,
        [source],
        ["scripts/publish-host-release.mjs"],
      ),
    ).not.toThrow();
    const actual = Bun.YAML.parse(
      await readFile(
        new URL("../.github/workflows/extensions.yml", import.meta.url),
        "utf8",
      ),
    );
    expect(actual.on.push).toBeUndefined();
    expect(() =>
      absentExtensionsPathRoute(
        actual,
        [source],
        ["scripts/publish-host-release.mjs"],
      ),
    ).toThrow();
    for (const paths of [
      ["Extensions/owner/file.swift"],
      ["Extensions/owner/.hidden"],
      ["scripts/extension-native-evidence.mjs"],
      [".github/workflows/extensions.yml"],
      ["../outside"],
      ["/absolute"],
      [],
      ["host.swift", "host.swift"],
    ])
      expect(() =>
        absentExtensionsPathRoute(workflow, [source], paths),
      ).toThrow();
    for (const parents of [[], [source, source], ["main"]])
      expect(() =>
        absentExtensionsPathRoute(workflow, parents, ["host.swift"]),
      ).toThrow();
    for (const push of [
      { branches: ["other"], paths: ["Extensions/**"] },
      { branches: ["main"], paths: ["!Extensions/**"] },
      { branches: ["main"], paths: [] },
      {
        branches: ["main"],
        paths: ["Extensions/**"],
        "paths-ignore": ["docs/**"],
      },
    ])
      expect(() =>
        absentExtensionsPathRoute({ on: { push } }, [source], ["host.swift"]),
      ).toThrow();
  });
});

function reusedInstallerFixture(updateIDs) {
  const current = catalogFixture().catalog.packages;
  const ids = current.map(({ id }) => id).sort();
  return {
    context: { source, current, updateIDs },
    proof: {
      schema: 1,
      sourceCommit: source,
      owners: 39,
      installationVerified: true,
      productionSignaturesVerified: true,
      storeSelectionVerified: true,
      offlineCatalogAndSelectionVerified: true,
      removalVerified: true,
      removedIDs: ids,
      busyRemovalAndLeaseDrainVerified: true,
      removalDataPreserved: true,
      reinstallationVerified: true,
      reinstalledIDs: [...ids],
      reinstalledSelectionVerified: true,
      reinstallationDataPreserved: true,
      pendingRemovalsDrained: true,
      persistentSyntheticDataPreserved: true,
      preservationChecks: 45,
      publicVersionUpdateVerified: updateIDs.length > 0,
      updatedIDs: [...updateIDs],
      workerEnableDisableExecuted: false,
      workerProcessesStarted: 0,
      featureCodeExecuted: false,
    },
  };
}

describe("Reused public packages retain explicit lifecycle and update scope", () => {
  test("zero, subset and full updates remain independent from all39 reinstall", () => {
    for (const updateIDs of [
      [],
      ["owner3"],
      ["owner7", "owner2"],
      catalogFixture().catalog.packages.map(({ id }) => id),
    ]) {
      const { proof, context } = reusedInstallerFixture(updateIDs);
      expect(() => validateInstallerProof(proof, context)).not.toThrow();
      expect(proof.updatedIDs).toEqual(updateIDs);
      expect(proof.reinstalledIDs).toHaveLength(39);
      for (const changed of [
        { updatedIDs: undefined },
        { updatedIDs: [...updateIDs, "foreign"] },
        { publicVersionUpdateVerified: !proof.publicVersionUpdateVerified },
      ])
        expect(() =>
          validateInstallerProof({ ...proof, ...changed }, context),
        ).toThrow();
    }
  });

  test("subset or zero updates cannot be broadened into all39 public updates", () => {
    for (const updateIDs of [[], ["owner3"]]) {
      const { proof, context } = reusedInstallerFixture(updateIDs);
      expect(() =>
        validateInstallerProof(
          { ...proof, updatedIDs: proof.reinstalledIDs },
          context,
        ),
      ).toThrow();
    }
  });

  test("prior install plus removal never substitutes for actual reinstall", () => {
    const { proof, context } = reusedInstallerFixture([]);
    for (const field of [
      "reinstallationVerified",
      "reinstalledIDs",
      "reinstalledSelectionVerified",
      "reinstallationDataPreserved",
      "pendingRemovalsDrained",
    ]) {
      const old = { ...proof };
      delete old[field];
      expect(() => validateInstallerProof(old, context)).toThrow();
    }
  });

  test("duplicate update IDs and incomplete or duplicate current owners reject", () => {
    const { proof, context } = reusedInstallerFixture(["owner3"]);
    for (const changed of [
      { updateIDs: ["owner3", "owner3"] },
      { updateIDs: ["foreign"] },
      { current: context.current.slice(1) },
      { current: [...context.current.slice(1), context.current[1]] },
    ])
      expect(() =>
        validateInstallerProof(proof, { ...context, ...changed }),
      ).toThrow();
  });
});
