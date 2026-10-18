import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import * as vm from "node:vm";
import {
  admitFunctionalRunner,
  admitFunctionalSourceEnvironment,
  functionalHostedRunPinsSwift,
  functionalObservationRuleSwift,
  functionalProducerBootstrapSource,
  functionalProducerBuildForLaunch,
  functionalProducerCatalogSources,
  functionalProducerPlanForBuild,
} from "./producer-project.mjs";

const sourceCommit = "a".repeat(40);
function activeJobFixture() {
  const sourceCommit = "a".repeat(40);
  const repository = { id: 1289153439, full_name: "pulkitxm/edith" };
  const pull = {
    number: 1014,
    state: "open",
    merged: false,
    merge_commit_sha: "c".repeat(40),
    head: {
      sha: sourceCommit,
      ref: "feat/extension-marketplace",
      repo: { ...repository },
    },
    base: { sha: "b".repeat(40), ref: "main", repo: { ...repository } },
  };
  const value = {
    sourceCommit,
    run: {
      id: 10,
      run_attempt: 1,
      head_sha: sourceCommit,
      head_branch: "feat/extension-marketplace",
      repository: { ...repository },
      head_repository: { ...repository },
      actor: { id: 65671483 },
      triggering_actor: { id: 65671483, login: "pulkitxm" },
      event: "pull_request",
      path: ".github/workflows/hosted-functional-actions.yml",
      workflow_id: 20,
      status: "in_progress",
      conclusion: null,
      pull_requests: [
        {
          number: 1014,
          head: structuredClone(pull.head),
          base: structuredClone(pull.base),
        },
      ],
    },
    job: {
      id: 11,
      run_id: 10,
      run_attempt: 1,
      head_sha: sourceCommit,
      name: "functional-build",
      runner_name: "synthetic-hosted-runner",
      status: "in_progress",
      conclusion: null,
      labels: ["macos-26", "ARM64"],
    },
    context: {
      event: {
        action: "synchronize",
        number: 1014,
        repository: { ...repository },
        pull_request: structuredClone(pull),
      },
      pullRequest: structuredClone(pull),
      mergeCommit: {
        sha: "c".repeat(40),
        parents: [{ sha: "b".repeat(40) }, { sha: sourceCommit }],
      },
      workflow: {
        id: 20,
        path: ".github/workflows/hosted-functional-actions.yml",
        state: "active",
      },
      runAttempt: 1,
    },
  };
  const environment = {
    GITHUB_ACTIONS: "true",
    RUNNER_ENVIRONMENT: "github-hosted",
    RUNNER_OS: "macOS",
    GITHUB_REPOSITORY: "pulkitxm/edith",
    GITHUB_REPOSITORY_ID: "1289153439",
    GITHUB_EVENT_NAME: "pull_request",
    GITHUB_REF: "refs/pull/1014/merge",
    GITHUB_JOB: "functional-build",
    GITHUB_SHA: value.context.mergeCommit.sha,
    EXPECTED_SOURCE_SHA: sourceCommit,
    GITHUB_ACTOR_ID: "65671483",
    GITHUB_TRIGGERING_ACTOR: "pulkitxm",
    GITHUB_RUN_ID: "10",
    GITHUB_RUN_ATTEMPT: "1",
    FUNCTIONAL_JOB_ID: "11",
    RUNNER_NAME: "synthetic-hosted-runner",
    GITHUB_EVENT_PATH: "/private/synthetic/event.json",
    EDITH_HOSTED_FUNCTIONAL_ACTIONS: "1",
    EXTENSION_SWIFT_JOBS: "1",
    EXTENSION_SIGN_IDENTITY: "synthetic reviewed signer",
    DEVELOPER_DIR: "/Applications/Xcode.app/Contents/Developer",
    RUNNER_TEMP: "/private/synthetic",
  };
  return { value, environment };
}

const environment = activeJobFixture().environment;

test("producer builds cannot run on local, unreviewed, unsigned, different source or unbounded build environments", () => {
  admitFunctionalRunner(environment, sourceCommit);
  for (const [key, value] of Object.entries({
    GITHUB_ACTIONS: "false",
    RUNNER_ENVIRONMENT: "self-hosted",
    GITHUB_EVENT_NAME: "push",
    GITHUB_SHA: sourceCommit,
    GITHUB_REPOSITORY_ID: "1",
    GITHUB_RUN_ATTEMPT: "0",
    GITHUB_JOB: "build",
    GITHUB_TRIGGERING_ACTOR: "foreign",
    CAMERA_CARRIER_PROFILE: "unadmitted",
    EXPECTED_SOURCE_SHA: "b".repeat(40),
    GITHUB_ACTOR_ID: "1",
    GITHUB_REF: "refs/heads/unreviewed",
    EXTENSION_SIGN_IDENTITY: "-",
    EXTENSION_SWIFT_JOBS: "4",
    DEVELOPER_DIR: "/Library/Developer/CommandLineTools",
    RUNNER_TEMP: "relative",
  }))
    assert.throws(() =>
      admitFunctionalRunner({ ...environment, [key]: value }, sourceCommit),
    );
});

test("source-built producer pins issuer scope, exact independently reviewed operation arrays and actual original role map before Host build", () => {
  const plan = {
    sourceCommit,
    hostedRunPins: {
      sourceCommit,
      mergeCommit: "c".repeat(40),
      baseCommit: "b".repeat(40),
      runID: 10,
      jobID: 11,
      runAttempt: 1,
      runnerName: "synthetic-hosted-runner",
      workflowSHA256: "d".repeat(64),
    },
    sourceSHA256: "e".repeat(64),
    toolchainSHA256: "f".repeat(64),
    sourcePins: { sourceCommit, files: [] },
    observationPolicies: {
      synthetic: {
        schema: 1,
        owner: "synthetic",
        readback: {
          operation: "synthetic.read",
          payload: {},
          normalizer: { kind: "identity" },
        },
        phases: ["initial", "updated", "reinstalled"].map((phase) => ({
          phase,
          before: { kind: "literal", value: false },
          after: { kind: "literal", value: true },
        })),
      },
    },
    session: "12345678-1234-4123-8123-123456789abc",
    root: "/private/synthetic/functional-fixture-12345678-1234-4123-8123-123456789abc",
    hostIdentifier:
      "com.pulkit.edith.tests.worker-12345678-1234-4123-8123-123456789abc",
    producerIdentifier:
      "com.pulkit.edith.tests.functional-producer-12345678-1234-4123-8123-123456789abc",
    certificateSHA256: Buffer.alloc(32, 9).toString("base64"),
    definitions: [
      {
        owner: "synthetic",
        operations: ["synthetic.change"],
        activation: { operation: "synthetic.change" },
      },
    ],
    roles: { synthetic: ["helper"] },
    recipes: { synthetic: { location: "main", section: "synthetic" } },
    preparationPolicies: {
      synthetic: { schema: 1, owner: "synthetic", files: [] },
    },
    savedReaderPolicies: {
      synthetic: {
        schema: 1,
        owner: "synthetic",
        reads: [],
        sentinels: [{ name: "retained" }],
        initial: null,
        final: null,
      },
    },
    policySHA256: "b".repeat(64),
    rolePolicySwiftExpression: "[]",
  };
  const source = functionalProducerBootstrapSource(
    plan,
    "/private/synthetic/repository",
  );

  assert(
    source.includes(
      'static let operations: [String: [String]] = ["synthetic": ["synthetic.change"]]',
    ),
  );
  assert(
    source.includes(
      'static let roles: [String: [String]] = ["synthetic": ["helper"]]',
    ),
  );
  assert(!source.includes("hostExecutableSHA256"));
  assert(!source.includes("privateKey"));
  assert(!source.includes("descriptorPath"));
  assert.equal(source.match(/relation: nil/g).length, 3);
  const colorPlan = {
    ...plan,
    definitions: [{ ...plan.definitions[0], owner: "colorPicker" }],
    observationPolicies: {
      colorPicker: {
        ...plan.observationPolicies.synthetic,
        owner: "colorPicker",
      },
    },
    savedReaderPolicies: {
      colorPicker: {
        ...plan.savedReaderPolicies.synthetic,
        owner: "colorPicker",
      },
    },
  };
  const color = functionalProducerBootstrapSource(
    colorPlan,
    "/private/synthetic/repository",
  );
  assert.equal(color.match(/relation: \.colorPickerHistory/g).length, 3);
  assert(!color.includes("relation: nil"));
  const calendarPlan = {
    ...plan,
    definitions: [
      {
        ...plan.definitions[0],
        owner: "calendar",
        operations: [
          "calendar.ui.metadata",
          "calendar.ui.list",
          "calendar.ui.loadMore",
        ],
        activation: { kind: "original-calendar-details", operation: null },
      },
    ],
    observationPolicies: {
      calendar: { ...plan.observationPolicies.synthetic, owner: "calendar" },
    },
    savedReaderPolicies: {
      calendar: { ...plan.savedReaderPolicies.synthetic, owner: "calendar" },
    },
  };
  const calendar = functionalProducerBootstrapSource(
    calendarPlan,
    "/private/synthetic/repository",
  );
  assert(
    calendar.includes(
      'static let activationOperations: [String: String?] = ["calendar": nil]',
    ),
  );
  for (const operation of [
    "calendar.ui.action",
    "calendar.ui.list",
    undefined,
  ]) {
    const invalid = structuredClone(calendarPlan);
    invalid.definitions[0].activation.operation = operation;
    assert.throws(() =>
      functionalProducerBootstrapSource(
        invalid,
        "/private/synthetic/repository",
      ),
    );
  }
  const boundPlan = {
    ...plan,
    observationPolicies: {
      synthetic: {
        ...plan.observationPolicies.synthetic,
        phases: plan.observationPolicies.synthetic.phases.map((rule) => ({
          ...rule,
          before: {
            kind: "literal",
            value: {
              $binding: "owned-path",
              root: "owner-home",
              components: ["mirror"],
            },
          },
          after: { kind: "oneOf", values: [{ $binding: "session" }] },
        })),
      },
    },
  };
  const bound = functionalProducerBootstrapSource(
    boundPlan,
    "/private/synthetic/repository",
  );
  for (const actual of [`${plan.root}/synthetic-home/mirror`, plan.session])
    assert(
      bound.includes(
        `Data(base64Encoded: "${Buffer.from(actual).toString("base64")}")`,
      ),
    );
  assert.equal(bound.match(/before: \.literal\(\.string/g).length, 3);
  assert.equal(bound.match(/after: \.oneOf\(\[\.string/g).length, 3);
});

test("source admission precedes signing and cannot accept production publication inputs", () => {
  const unsigned = { ...environment };
  delete unsigned.EXTENSION_SIGN_IDENTITY;
  admitFunctionalSourceEnvironment(unsigned, sourceCommit);
  assert.throws(() => admitFunctionalRunner(unsigned, sourceCommit));
  for (const key of [
    "EXTENSION_CATALOG_PRIVATE_KEY",
    "EXTENSION_RELEASE_TAG",
    "CAMERA_EXTENSION_PROFILE",
  ])
    assert.throws(() =>
      admitFunctionalSourceEnvironment(
        { ...unsigned, [key]: "foreign" },
        sourceCommit,
      ),
    );
  assert.throws(() => functionalProducerPlanForBuild({ sourceCommit }));
  assert.throws(() =>
    functionalProducerBuildForLaunch({
      sourceCommit,
      producer: { path: "/private/synthetic/producer" },
    }),
  );
});

test("generated native run pins reject omitted source and unbound job or workflow", () => {
  const pins = {
    sourceCommit,
    mergeCommit: "c".repeat(40),
    baseCommit: "b".repeat(40),
    runID: 10,
    jobID: 11,
    runAttempt: 1,
    runnerName: "synthetic-hosted-runner",
    workflowSHA256: "d".repeat(64),
  };
  assert(functionalHostedRunPinsSwift(pins).includes("runAttempt: 1"));
  for (const key of Object.keys(pins)) {
    const omitted = { ...pins };
    delete omitted[key];
    assert.throws(() => functionalHostedRunPinsSwift(omitted));
  }
  for (const patch of [
    { runID: 0 },
    { runAttempt: 1.5 },
    { workflowSHA256: "foreign" },
    { sourceCommit: "foreign" },
    { runnerName: "synthetic\nforeign" },
  ])
    assert.throws(() => functionalHostedRunPinsSwift({ ...pins, ...patch }));
});

test("producer catalog signing reuses the maintained marketplace validator source graph", () => {
  assert.deepEqual(functionalProducerCatalogSources, [
    "Packages/ExtensionMarketplace/Sources/ExtensionMarketplace/ExtensionCatalog.swift",
    "Packages/ExtensionMarketplace/Sources/ExtensionMarketplace/ExtensionSystemVersion.swift",
  ]);
  assert(Object.isFrozen(functionalProducerCatalogSources));
});

test("finite source observation rules preserve strict timing bounds and reject widened or malformed predicates", () => {
  assert.equal(
    functionalObservationRuleSwift({ kind: "number", minimum: 0, maximum: 30 }),
    ".number(minimum: 0, maximum: 30)",
  );
  for (const rule of [
    { kind: "number", minimum: 30, maximum: 0 },
    { kind: "integer", minimum: 0.5, maximum: 30 },
    {
      kind: "array",
      minimumCount: 0,
      maximumCount: 65537,
      element: { kind: "uuid" },
    },
    { kind: "oneOf", values: [] },
    { kind: "uuid", passed: true },
    { kind: "arbitrary" },
  ])
    assert.throws(() => functionalObservationRuleSwift(rule));
});

test("producer launch retains the original opaque compilation for live Docs admission", {
  skip: typeof vm.SourceTextModule !== "function",
}, async () => {
  const url = new URL("./producer-project.mjs", import.meta.url);
  const source = await readFile(url, "utf8");
  assert.match(
    source,
    /retainFunctionalProducerBuild\(\s*receipt,\s*plan,\s*compilation,/,
    "Producer build must retain the original opaque compilation",
  );
  const module = new vm.SourceTextModule(
    `${source}\nexport { retainFunctionalProducerBuild };`,
  );
  await module.link(async (specifier) => {
    const namespace = await import(
      specifier.startsWith(".") ? new URL(specifier, url).href : specifier
    );
    return new vm.SyntheticModule(Object.keys(namespace), function () {
      for (const [name, value] of Object.entries(namespace))
        this.setExport(name, value);
    });
  });
  await module.evaluate();
  const compilation = Object.freeze({});
  const projection = Object.freeze({ sourceCommit, root: "/synthetic" });
  const plan = Object.freeze({});
  const dependency = Object.freeze({});
  const receipt = Object.freeze({});
  let live = true;
  const calls = [];
  const observe = (input) => {
    assert.equal(input.compilation, compilation);
    assert.notEqual(input.compilation, projection);
    assert.equal(input.plan, plan);
    assert.equal(input.dependency, dependency);
    assert(live, "Docs dependency lifetime ended");
    calls.push(input);
  };
  module.namespace.retainFunctionalProducerBuild(
    receipt,
    plan,
    compilation,
    dependency,
    observe,
  );
  assert.equal(
    module.namespace.functionalProducerBuildForLaunch(receipt).compilation,
    compilation,
  );
  module.namespace.functionalProducerBuildForLaunch(receipt);
  assert.equal(calls.length, 2);
  live = false;
  assert.throws(
    () => module.namespace.functionalProducerBuildForLaunch(receipt),
    /lifetime ended/,
  );
  assert.throws(
    () => module.namespace.functionalProducerBuildForLaunch({}),
    /source-built signed producer receipt/,
  );
});
