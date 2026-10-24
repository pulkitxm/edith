import { expect, test } from "bun:test";
import {
  managedNativeBuildSteps,
  shippingNativeTestSteps,
} from "./hosted-managed-views/native-ci-contract.mjs";
import { productionRun } from "./hosted-public-release/contract.mjs";
import {
  admitEvidence,
  publicationComposition,
} from "./hosted-public-release/evidence.mjs";
import {
  shippingFingerprints,
  shippingHosted,
  shippingProductionPlan,
  shippingReleaseDefinitions,
  shippingRequest,
  shippingUpdateVersions,
} from "./hosted-public-release/shipping-scope.mjs";
import { validateInstallerProof } from "./hosted-public-release/verify.mjs";

const source = "a".repeat(40);
const hash = "b".repeat(64);
const definitions = Array.from({ length: 40 }, (_, index) => ({
  id: index ? `owner${index}` : "keepAwake",
  dependencies: [],
}));
const fingerprints = Object.fromEntries(
  definitions.map(({ id }) => [id, hash]),
);
const options = {
  source,
  tag: "v1.0.1",
  packagesRun: 10,
  hostRun: 20,
  retainedRuns: {},
  updateIDs: ["keepAwake"],
};
const environment = {
  GITHUB_ACTIONS: "true",
  RUNNER_ENVIRONMENT: "github-hosted",
  RUNNER_OS: "macOS",
  GITHUB_REPOSITORY: "pulkitxm/edith",
  GITHUB_REPOSITORY_ID: "1289153439",
  GITHUB_EVENT_NAME: "workflow_dispatch",
  GITHUB_REF: "refs/heads/main",
  GITHUB_SHA: source,
  GITHUB_ACTOR_ID: "65671483",
  PUBLIC_RELEASE_VERIFICATION: "1",
  PUBLISH: "false",
  REBUILD: "",
};
function versions() {
  const current = {
    id: "keepAwake",
    version: "1.0.1",
    dependencies: [],
    hostABI: hash,
    architecture: "arm64",
    minimumSystemVersion: "26.0",
    sha256: "c".repeat(64),
    sourceFingerprint: "d".repeat(64),
  };
  return {
    current: [current],
    previous: [
      {
        ...current,
        version: "1.0.0",
        sha256: "e".repeat(64),
        sourceFingerprint: "f".repeat(64),
      },
    ],
  };
}
function installer() {
  return {
    schema: 1,
    sourceCommit: source,
    owners: 1,
    installationVerified: true,
    productionSignaturesVerified: true,
    storeSelectionVerified: true,
    offlineCatalogAndSelectionVerified: true,
    removalVerified: true,
    busyRemovalAndLeaseDrainVerified: true,
    removalDataPreserved: true,
    reinstallationVerified: true,
    reinstalledSelectionVerified: true,
    reinstallationDataPreserved: true,
    pendingRemovalsDrained: true,
    persistentSyntheticDataPreserved: true,
    removedIDs: ["keepAwake"],
    reinstalledIDs: ["keepAwake"],
    updatedIDs: ["keepAwake"],
    publicVersionUpdateVerified: true,
    preservationChecks: 7,
    workerEnableDisableExecuted: false,
    workerProcessesStarted: 0,
    featureCodeExecuted: false,
  };
}

test("shipping requests are closed, current-source, and Keep Awake only", () => {
  expect(shippingRequest(JSON.stringify(options), source)).toEqual(options);
  for (const change of [
    { source: "b".repeat(40) },
    { updateIDs: [] },
    { updateIDs: ["keepAwake", "owner1"] },
    { updateIDs: ["owner1"] },
    { retainedRuns: { owner1: 1 } },
    { extra: true },
  ])
    expect(() =>
      shippingRequest(JSON.stringify({ ...options, ...change }), source),
    ).toThrow();
  expect(() =>
    shippingRequest(
      JSON.stringify(options).replace(
        '"hostRun":20',
        '"hostRun":20,"hostRun":20',
      ),
      source,
    ),
  ).toThrow();
});

test("shipping hosting rejects every changed trust and publication field", () => {
  expect(() => shippingHosted(environment, source)).not.toThrow();
  expect(() =>
    shippingHosted({ ...environment, GITHUB_ACTOR_ID: "320458784" }, source),
  ).not.toThrow();
  for (const key of Object.keys(environment))
    expect(() =>
      shippingHosted({ ...environment, [key]: "foreign" }, source),
    ).toThrow();
});

test("all39 metadata remains validated while release fingerprints select only Keep Awake", () => {
  expect(shippingReleaseDefinitions(definitions)).toEqual([definitions[0]]);
  expect(shippingFingerprints(definitions, fingerprints)).toEqual({
    keepAwake: hash,
  });
  for (const changed of [
    definitions.slice(1),
    [...definitions.slice(0, 39), definitions[0]],
    definitions.map((row, index) =>
      index ? row : { ...row, dependencies: ["owner1"] },
    ),
    definitions.map((row, index) =>
      index ? row : { ...row, dependencies: ["keepAwake"] },
    ),
  ])
    expect(() => shippingReleaseDefinitions(changed)).toThrow();
  expect(() =>
    shippingFingerprints(definitions, { keepAwake: hash }),
  ).toThrow();
  expect(() =>
    shippingFingerprints(definitions, { ...fingerprints, owner1: "invalid" }),
  ).toThrow();
});

test("shipping production requires an actual sole Keep Awake native build", () => {
  expect(() => shippingProductionPlan([{ id: "keepAwake" }])).not.toThrow();
  for (const plan of [
    [],
    [{ id: "owner1" }],
    [{ id: "keepAwake" }, { id: "owner1" }],
  ])
    expect(() => shippingProductionPlan(plan)).toThrow();
});

test("shipping public update requires distinct compatible 1.0.0 and 1.0.1 payloads", () => {
  const value = versions();
  expect(() =>
    shippingUpdateVersions(value.current, value.previous),
  ).not.toThrow();
  for (const change of [
    { version: "1.0.0" },
    { version: "1.0.2" },
    { id: "owner1" },
    { dependencies: ["owner1"] },
    { architecture: "x86_64" },
    { hostABI: "foreign" },
    { minimumSystemVersion: "27.0" },
    { sha256: value.previous[0].sha256 },
    { sourceFingerprint: value.previous[0].sourceFingerprint },
  ])
    expect(() =>
      shippingUpdateVersions(
        [{ ...value.current[0], ...change }],
        value.previous,
      ),
    ).toThrow();
  for (const version of ["1.0.1", "0.9.9", "1.0.2"])
    expect(() =>
      shippingUpdateVersions(value.current, [
        { ...value.previous[0], version },
      ]),
    ).toThrow();
  expect(() => shippingUpdateVersions(value.current, [])).toThrow();
  expect(() =>
    shippingUpdateVersions(
      [...value.current, ...value.current],
      value.previous,
    ),
  ).toThrow();
});

test("shipping installer proof retains every lifecycle and nonexecution guard", () => {
  const context = {
    source,
    current: versions().current,
    updateIDs: ["keepAwake"],
    scope: "shipping",
  };
  const proof = installer();
  expect(() => validateInstallerProof(proof, context)).not.toThrow();
  for (const [field, value] of Object.entries(proof)) {
    const changed =
      typeof value === "boolean"
        ? !value
        : Array.isArray(value)
          ? ["owner1"]
          : typeof value === "number"
            ? -1
            : "foreign";
    expect(() =>
      validateInstallerProof({ ...proof, [field]: changed }, context),
    ).toThrow();
    const missing = { ...proof };
    delete missing[field];
    expect(() => validateInstallerProof(missing, context)).toThrow();
  }
  expect(() =>
    validateInstallerProof({ ...proof, preservationChecks: 6 }, context),
  ).toThrow();
  expect(() =>
    validateInstallerProof(proof, { ...context, scope: "foreign" }),
  ).toThrow();
  expect(() =>
    validateInstallerProof(proof, { ...context, scope: undefined }),
  ).toThrow();
  expect(() =>
    validateInstallerProof(proof, { ...context, updateIDs: [] }),
  ).toThrow();
});

test("shipping composition admits one current fingerprint and rejects another owner", () => {
  const row = {
    package: { id: "keepAwake", sourceFingerprint: hash },
    lineageSHA256: hash,
    lineageBytes: 1,
    sourceCommit: source,
    runID: 10,
    runAttempt: 1,
    evidenceSHA256: hash,
    evidenceBytes: 1,
  };
  const selected = shippingFingerprints(definitions, fingerprints);
  expect(
    publicationComposition(source, 10, 1, [row], selected).packages,
  ).toEqual([row]);
  expect(() =>
    publicationComposition(source, 10, 1, [row], fingerprints),
  ).toThrow();
  expect(() =>
    publicationComposition(
      source,
      10,
      1,
      [{ ...row, package: { id: "owner1", sourceFingerprint: hash } }],
      selected,
    ),
  ).toThrow();
});

test("strict native evidence qualifies only the selected owner and unchanged host suites", () => {
  const run = {
    repository: { full_name: "pulkitxm/edith" },
    id: 10,
    run_attempt: 1,
    path: ".github/workflows/extensions.yml",
    head_sha: source,
    head_branch: "main",
    event: "push",
    status: "completed",
    conclusion: "success",
  };
  const jobs = [
    "plan",
    "frozen-host",
    "tests",
    "publish",
    "build (keepAwake)",
  ].map((name, index) => ({
    id: index + 1,
    name,
    run_id: run.id,
    status: "completed",
    conclusion: "success",
    steps: (name === "tests"
      ? shippingNativeTestSteps
      : name.startsWith("build (")
        ? managedNativeBuildSteps
        : name === "publish"
          ? [
              "Preserve immutable native evidence before publication",
              "Publish immutable extension releases and the signed catalog",
            ]
          : []
    ).map((name, index) => ({
      name,
      number: index + 1,
      status: "completed",
      conclusion: "success",
    })),
  }));
  const payload = {
    schema: 1,
    kind: "extension-native-evidence",
    repository: "pulkitxm/edith",
    workflowPath: run.path,
    event: run.event,
    sourceCommit: source,
    runID: run.id,
    runAttempt: 1,
    plannedIDs: ["keepAwake"],
    fingerprints,
    jobs: jobs
      .map(({ id, name, steps }) => ({
        id,
        name,
        steps: steps
          .filter(
            ({ name }) =>
              name !==
              "Publish immutable extension releases and the signed catalog",
          )
          .map(({ name, number }) => ({ name, number })),
      }))
      .sort((a, b) => a.name.localeCompare(b.name)),
    artifacts: [
      "extension-plan",
      "frozen-extension-host",
      "extension-keepAwake",
    ].map((name, index) => ({
      name,
      artifactID: index + 1,
      artifactBytes: 1,
      artifactSHA256: hash,
      assetName: `${name}-${index + 1}.zip`,
    })),
  };
  const parameters = {
    run,
    jobs,
    artifacts: [],
    source,
    definitions,
    fingerprints,
    plannedIDs: ["keepAwake"],
    resolveArtifact: (name) => ({ artifactID: name }),
  };
  expect(admitEvidence(payload, parameters)).toBe(payload);
  expect(
    productionRun(parameters).map(({ extensionID }) => extensionID),
  ).toEqual(["keepAwake"]);
  for (const name of ["tests", "build (keepAwake)"]) {
    const failed = jobs.map((job) =>
      job.name === name
        ? {
            ...job,
            steps: job.steps.map((step, index) =>
              index ? step : { ...step, conclusion: "failure" },
            ),
          }
        : job,
    );
    expect(() =>
      admitEvidence(payload, { ...parameters, jobs: failed }),
    ).toThrow();
    expect(() => productionRun({ ...parameters, jobs: failed })).toThrow();
  }
  expect(() =>
    admitEvidence(payload, {
      ...parameters,
      jobs: [...jobs, { ...jobs[4], id: 99, name: "build (owner1)" }],
    }),
  ).toThrow();
});
