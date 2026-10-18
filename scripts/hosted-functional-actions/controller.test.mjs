import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { EventEmitter } from "node:events";
import { readFile } from "node:fs/promises";
import { PassThrough, Writable } from "node:stream";
import test from "node:test";
import * as vm from "node:vm";
import { definition } from "./cases/keepAwake.mjs";
import { functionalCanonicalJSON, functionalDigest } from "./contract.mjs";
import {
  admitFunctionalProducerAuthority,
  cancelFunctionalProducer,
  FunctionalJourneyOrder,
  FunctionalProducerChannel,
  finishFunctionalProducer,
  functionalActiveJobBuildPins,
  functionalActiveJobContextBinding,
  functionalControllerMain,
  functionalInstalledXCTestProject,
  functionalInstalledXCTestRunConfiguration,
  functionalLiteralJSON,
  functionalPresentationID,
  observeFunctionalProducer,
  requireFunctionalActiveJob,
  runFunctionalPool,
  validateFunctionalActiveJob,
  validateFunctionalLiteralPolicies,
  validateFunctionalObservationPolicy,
  validateFunctionalOriginalCaseSource,
  validateFunctionalPreparationPolicy,
  validateFunctionalSavedReaderPolicy,
  validateFunctionalSourceModuleExports,
} from "./controller.mjs";
import { functionalFixtureRolePolicySource } from "./fixture-trust.mjs";
import { functionalActionOwners } from "./owners.mjs";

const session = "12345678-1234-4123-8123-123456789abc";
const root = `/private/synthetic/functional-fixture-${session}`;
const birth = (pid, generation) => ({
  pid,
  birthSeconds: 1000 + generation,
  birthMicroseconds: pid,
  uid: 501,
  executableSHA256: "a".repeat(64),
});
const capability = (phase, generation) => ({
  schema: 1,
  sourceCommit: "a".repeat(40),
  session,
  owner: "keepAwake",
  uid: 501,
  fixtureRoot: root,
  hostIdentifier: `com.pulkit.edith.tests.worker-${session}`,
  home: `${root}/keepAwake-home`,
  dataDirectory: `${root}/Edith Tests/worker-${session}/Data/keepAwake`,
  hostABI: "edith-host-2",
  caseSHA256: functionalDigest(definition),
  activationOperation: definition.activation.operation,
  phase,
  pairScope: "synthetic-development",
  previousVersion: "1.0.0",
  currentVersion: "1.1.0",
  version: phase === "initial" ? "1.0.0" : "1.1.0",
  packageSHA256: (phase === "initial" ? "b" : "c").repeat(64),
  engine: birth(12 + generation * 2, generation),
  ui: birth(13 + generation * 2, generation),
  operations: definition.operations,
  ownedPaths: [
    {
      name: "data",
      path: `${root}/Edith Tests/worker-${session}/Data/keepAwake`,
      kind: "directory",
    },
  ],
});
const drain = (cap) => ({
  births: [cap.engine, cap.ui],
  allTasksJoined: true,
  birthsAbsent: true,
  leasesReleased: true,
  signalsSent: 0,
});
const removal = () => ({
  physicallyAbsentVersions: ["1.0.0", "1.1.0"],
  pendingRemoval: false,
  leasesReleased: true,
  sentinelBytesPreserved: true,
  semanticDataPreserved: true,
});

test("portable lifecycle model holds each phase until actual drain and retained baseline", () => {
  const order = new FunctionalJourneyOrder();
  const saved = Buffer.from('{"preventSleep":true}');
  for (const [index, phase] of [
    "initial",
    "updated",
    "reinstalled",
  ].entries()) {
    if (index === 2) order.remove(removal());
    order.captureBaseline(
      index === 0 ? Buffer.from('{"preventSleep":false}') : saved,
    );
    const cap = capability(phase, index);
    const binding = order.hold(cap, definition);
    assert.equal(binding.presentationID, functionalPresentationID(cap));
    assert.match(
      binding.presentationID,
      /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/,
    );
    order.completeSaved(saved);
    order.drain(drain(cap));
  }
  order.finish();
});

test("construction cannot precede baseline and transitions cannot skip natural join or physical removal", () => {
  const order = new FunctionalJourneyOrder();
  assert.throws(() => order.hold(capability("initial", 0), definition));
  order.captureBaseline(null);
  const cap = capability("initial", 0);
  order.hold(cap, definition);
  assert.throws(() => order.captureBaseline(null));
  assert.throws(() => order.drain(drain(cap)));
  order.completeSaved(null);
  for (const field of ["allTasksJoined", "birthsAbsent", "leasesReleased"])
    assert.throws(() => order.drain({ ...drain(cap), [field]: false }));
  assert.throws(() => order.drain({ ...drain(cap), signalsSent: 1 }));
  order.drain(drain(cap));
  assert.throws(() => order.remove(removal()));
  assert.throws(() => order.finish());
});

test("retained saved state must exist before any updated mutation and final restore must match initial saved bytes", () => {
  const order = new FunctionalJourneyOrder();
  const cap = capability("initial", 0);
  order.captureBaseline(Buffer.from("before"));
  order.hold(cap, definition);
  order.completeSaved(Buffer.from("saved"));
  order.drain(drain(cap));
  assert.throws(() => order.captureBaseline(Buffer.from("seeded")));
  order.captureBaseline(Buffer.from("saved"));
  order.hold(capability("updated", 1), definition);
  assert.throws(() => order.completeSaved(Buffer.from("repair")));
});

test("bounded pool aborts all owned work and awaits retirement before reporting failure", async () => {
  let active = 0,
    maximum = 0,
    retired = 0,
    cleanup = 0,
    started = 0;
  let release;
  const bothStarted = new Promise((resolve) => {
    release = resolve;
  });
  await assert.rejects(
    runFunctionalPool(
      [1, 2, 3, 4],
      2,
      async (item, signal) => {
        active++;
        maximum = Math.max(maximum, active);
        try {
          if (++started === 2) release();
          await bothStarted;
          if (item === 1) throw new Error("synthetic failure");
          await new Promise((resolve) =>
            signal.addEventListener("abort", resolve, { once: true }),
          );
        } finally {
          active--;
          retired++;
        }
      },
      async () => {
        assert.equal(active, 0);
        cleanup++;
      },
    ),
    AggregateError,
  );
  assert.equal(maximum, 2);
  assert.equal(retired, 2);
  assert.equal(cleanup, 1);
  await assert.rejects(
    runFunctionalPool(
      [],
      4,
      async () => {},
      async () => {},
    ),
  );
});

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

test("active admission binds the genuine same repository PR source merge attempt and hosted job", () => {
  const { value, environment } = activeJobFixture();
  assert.equal(validateFunctionalActiveJob(value, environment), value);
  const changes = [
    (v) => {
      v.sourceCommit = "d".repeat(40);
    },
    (v) => {
      v.run.event = "workflow_dispatch";
    },
    (v) => {
      v.run.repository.id += 1;
    },
    (v) => {
      v.run.repository.full_name = "synthetic/fork";
    },
    (v) => {
      v.run.head_repository.id += 1;
    },
    (v) => {
      v.run.head_sha = "d".repeat(40);
    },
    (v) => {
      v.run.head_branch = "unreviewed";
    },
    (v) => {
      v.run.actor.id = 99;
    },
    (v) => {
      v.run.triggering_actor.id = 99;
    },
    (v) => {
      v.run.triggering_actor.login = "foreign";
    },
    (v) => {
      v.run.id += 1;
    },
    (v) => {
      v.run.run_attempt += 1;
    },
    (v) => {
      v.run.workflow_id += 1;
    },
    (v) => {
      v.run.status = "completed";
      v.run.conclusion = "success";
    },
    (v) => {
      v.run.path = ".github/workflows/ci.yml";
    },
    (v) => {
      v.run.pull_requests = [];
    },
    (v) => {
      v.run.pull_requests[0].head.repo.id += 1;
    },
    (v) => {
      v.run.pull_requests[0].base.sha = "d".repeat(40);
    },
    (v) => {
      v.job.id += 1;
    },
    (v) => {
      v.job.run_id += 1;
    },
    (v) => {
      v.job.run_attempt += 1;
    },
    (v) => {
      v.job.head_sha = "d".repeat(40);
    },
    (v) => {
      v.job.runner_name = "foreign";
    },
    (v) => {
      v.job.name = "counterfeit";
    },
    (v) => {
      v.job.status = "completed";
      v.job.conclusion = "success";
    },
    (v) => {
      v.job.labels = ["self-hosted", "macos-26"];
    },
    (v) => {
      v.context.event.number = 1015;
    },
    (v) => {
      v.context.event.action = "closed";
    },
    (v) => {
      v.context.event.repository.id += 1;
    },
    (v) => {
      v.context.event.pull_request.head.repo.id += 1;
    },
    (v) => {
      v.context.pullRequest.head.repo.id += 1;
    },
    (v) => {
      v.context.pullRequest.base.repo.id += 1;
    },
    (v) => {
      v.context.pullRequest.state = "closed";
    },
    (v) => {
      v.context.pullRequest.merged = true;
    },
    (v) => {
      v.context.pullRequest.head.sha = "d".repeat(40);
    },
    (v) => {
      v.context.pullRequest.base.sha = "d".repeat(40);
    },
    (v) => {
      v.context.mergeCommit.parents.reverse();
    },
    (v) => {
      v.context.mergeCommit.parents.pop();
    },
    (v) => {
      v.context.mergeCommit.sha = v.sourceCommit;
    },
    (v) => {
      v.context.workflow.state = "disabled_manually";
    },
    (v) => {
      v.context.runAttempt += 1;
    },
    (v) => {
      v.artifactID = 3;
    },
  ];
  for (const change of changes) {
    const altered = structuredClone(value);
    change(altered);
    assert.throws(() => validateFunctionalActiveJob(altered, environment));
  }
});

test("raw API documents and completed artifacts cannot bypass observed job and same live producer brands", async () => {
  const { value, environment } = activeJobFixture();
  assert.throws(() => requireFunctionalActiveJob(value));
  assert.throws(() => functionalActiveJobBuildPins(value));
  assert.throws(() => observeFunctionalProducer({ ownedBirth: { pid: 42 } }));
  await assert.rejects(
    admitFunctionalProducerAuthority({
      receipt: {},
      plan: {},
      channel: {},
      activeJob: value,
      environment,
    }),
  );
});

function literalPolicyFixture() {
  const sourceCommit = "a".repeat(40);
  const hash = (bytes) => createHash("sha256").update(bytes).digest("hex");
  const helpers = new Set([
    "keepAwake",
    "focusDim",
    "windowSweaters",
    "micMute",
    "keystrokeHighlight",
    "presenter",
    "colorPicker",
    "systemStats",
    "emoji",
    "notchShelf",
    "clipboard",
  ]);
  const cases = [],
    recipes = {},
    nativeSources = {},
    literalPolicies = {};
  const manifestBytes = Buffer.from(
    JSON.stringify(
      functionalActionOwners.map((id) => ({
        id,
        roles: { [helpers.has(id) ? "helper" : "app"]: [] },
      })),
    ),
  );
  for (const owner of functionalActionOwners) {
    const operations =
      owner === "notchShelf"
        ? [
            "notch.settings.read",
            "notch.settings.write",
            "notchShelf.cli.catalog",
          ]
        : [`${owner}.change`];
    const operation =
      owner === "notchShelf" ? "notch.settings.write" : operations[0];
    const definition = {
      schema: 1,
      owner,
      activation: {
        kind: "native-accessibility",
        control: "Synthetic checkbox",
        operation,
        mutation: { kind: "state-transition", payloadKeys: ["value"] },
        sources: [
          {
            path: `Extensions/${owner}/Synthetic.swift`,
            sha256: "b".repeat(64),
          },
        ],
      },
      operations,
      observation: { kind: "checked-engine-readback", name: "synthetic state" },
      persistence: { applicable: true, name: "synthetic-saved" },
      limits: ["synthetic-platform-adapter"],
    };
    nativeSources[owner] = Buffer.from(
      `struct Synthetic${owner}Case { static let owner = "${owner}" }`,
    );
    cases.push({
      definition,
      sourceCommit,
      sourcePins: [
        {
          path: `Tests/HostedFunctionalActions/OwnerCases/${owner}ActionCase.swift`,
          sha256: hash(nativeSources[owner]),
        },
      ],
    });
    recipes[owner] = {
      recipe: {
        schema: 1,
        owner,
        location: "main",
        section: owner,
        operation,
        steps: [
          {
            role: "checkBox",
            label: "Synthetic checkbox",
            action: "set-checkbox",
            value: true,
          },
        ],
        sources: definition.activation.sources,
      },
    };
    literalPolicies[owner] = {
      owner,
      primaryRole: helpers.has(owner) ? "helper" : "app",
      operations,
      presentations: [{ location: "main", section: owner }],
      inputs: [],
      outputs: [],
      fileScopes: [],
    };
  }
  return {
    cases,
    recipes,
    manifestBytes,
    nativeSources,
    literalPolicies,
    sourceCommit,
  };
}

test("source readiness compiles all39 literal policies against actual case and manifest bytes", () => {
  const fixture = literalPolicyFixture();
  const admitted = validateFunctionalLiteralPolicies(fixture);
  const result = functionalFixtureRolePolicySource(
    admitted.policyBytes,
    admitted.admittedPolicies,
  );
  assert.equal(result.sourceCommit, fixture.sourceCommit);
  assert.equal(admitted.admittedPolicies.cases.length, 39);
  assert.equal(JSON.parse(admitted.policyBytes.toString()).length, 39);
  assert(!Object.hasOwn(admitted, "nativeProof"));
  for (const mutate of [
    (f) => {
      delete f.literalPolicies.studio;
    },
    (f) => {
      f.literalPolicies.studio.operations = ["studio.foreign"];
    },
    (f) => {
      delete f.literalPolicies.plugins.fileScopes;
    },
    (f) => {
      f.literalPolicies.plugins.fileScopes = null;
    },
    (f) => {
      f.literalPolicies.docs.presentations = [
        { location: "settings", section: "foreign" },
      ];
    },
    (f) => {
      f.literalPolicies.calendar.unrestricted = true;
    },
    (f) => {
      f.nativeSources.docs = Buffer.from("foreign case");
    },
    (f) => {
      f.recipes.docs.recipe.steps[0].ownedLabel = {
        name: "uncompiled",
        component: "basename",
      };
      f.recipes.docs.recipe.steps[0].label = "";
    },
  ]) {
    const changed = literalPolicyFixture();
    mutate(changed);
    assert.throws(() => validateFunctionalLiteralPolicies(changed));
  }
});

test("source module admission checks maintained exports without importing or running module code", () => {
  validateFunctionalSourceModuleExports(
    Buffer.from(
      "export async function original() { throw new Error('must never execute during source checking'); }",
    ),
    ["original"],
  );
  for (const text of [
    "export const original = false;",
    "export function original() {}",
    "export function foreign() { return 1; }",
  ])
    assert.throws(() =>
      validateFunctionalSourceModuleExports(Buffer.from(text), ["original"]),
    );
});

test("controller CLI rejects obsolete and ambiguous modes before native or signing work", async () => {
  for (const arguments_ of [
    [],
    ["--admit-source"],
    ["--run", "--check-source-ready"],
    ["--unknown"],
  ])
    await assert.rejects(
      functionalControllerMain({ arguments_, environment: {} }),
    );
});

test("installed XCTest project builds one signed independent actuator with no replacement Host target", () => {
  const generated = functionalInstalledXCTestProject({
    directory: "/private/synthetic/XCTest",
    sourceSHA256: "b".repeat(64),
    certificateIdentity: "synthetic reviewed signer",
  });
  const targets = Object.values(generated.project.objects).filter(
    ({ isa }) => isa === "PBXNativeTarget",
  );
  assert.equal(targets.length, 1);
  assert.equal(
    targets[0].productType,
    "com.apple.product-type.bundle.ui-testing",
  );
  assert(!generated.scheme.includes("LaunchAction"));
  assert(generated.scheme.includes('parallelizeBuildables="NO"'));
  for (const patch of [
    { directory: "relative" },
    { sourceSHA256: "foreign" },
    { certificateIdentity: "-" },
  ])
    assert.throws(() =>
      functionalInstalledXCTestProject({
        directory: "/private/synthetic/XCTest",
        sourceSHA256: "b".repeat(64),
        certificateIdentity: "synthetic reviewed signer",
        ...patch,
      }),
    );
});

function memoryProducer(operationResponse) {
  const child = new EventEmitter();
  child.pid = 42;
  child.exitCode = null;
  child.signalCode = null;
  child.stdout = new PassThrough();
  child.stderr = new PassThrough();
  const commands = [];
  const emit = (value) =>
    child.stdout.write(`${functionalCanonicalJSON(value)}\n`);
  child.stdin = new Writable({
    write(bytes, _encoding, callback) {
      const command = JSON.parse(bytes.toString());
      commands.push(command);
      callback();
      queueMicrotask(() =>
        emit({
          requestID: command.requestID,
          operation: command.operation,
          ...operationResponse(command),
        }),
      );
    },
    final(callback) {
      callback();
      queueMicrotask(() => {
        child.exitCode = 0;
        child.emit("exit", 0, null);
      });
    },
  });
  const expected = {
    sourceCommit: "a".repeat(40),
    session,
    producer: {
      path: `${root}/Producer/functional-producer`,
      executableSHA256: "c".repeat(64),
    },
  };
  const bootstrap = {
    schema: 1,
    kind: "bootstrap",
    sourceCommit: expected.sourceCommit,
    session,
    issuerPublicKey: Buffer.alloc(32, 1).toString("base64"),
    producer: {
      ...birth(42, 1),
      executable: expected.producer.path,
      executableSHA256: expected.producer.executableSHA256,
    },
  };
  const channel = new FunctionalProducerChannel(child, expected);
  return { child, channel, bootstrap, emit, commands };
}

test("producer channel correlates actual messages and joins close after finish rather than exit alone", async () => {
  const memory = memoryProducer(() => ({}));
  memory.emit(memory.bootstrap);
  assert.equal((await memory.channel.bootstrap()).producer.pid, 42);
  let joined = false;
  const completion = memory.channel.finish().then(() => {
    joined = true;
  });
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(memory.child.exitCode, 0);
  assert.equal(joined, false);
  assert.equal(memory.commands[0].operation, "finish");
  memory.child.emit("close", 0, null);
  await completion;
  assert.equal(joined, true);
});

test("producer channel rejects counterfeit bootstrap, uncorrelated replies, and cleanup without proof", async () => {
  const foreign = memoryProducer(() => ({}));
  foreign.emit({ ...foreign.bootstrap, issuerPrivateKey: "forged" });
  await assert.rejects(foreign.channel.bootstrap());
  const pending = memoryProducer(() => ({}));
  pending.emit(pending.bootstrap);
  await pending.channel.bootstrap();
  pending.emit({ requestID: "foreign", operation: "finish" });
  await assert.rejects(pending.channel.request("authority-metadata"));
  const cleanup = memoryProducer(() => ({ ownedCleanupComplete: false }));
  cleanup.emit(cleanup.bootstrap);
  await cleanup.channel.bootstrap();
  await assert.rejects(cleanup.channel.cancelAndJoin());
  await assert.rejects(cancelFunctionalProducer(cleanup.channel));
  await assert.rejects(finishFunctionalProducer(cleanup.channel));
});

test("current authority context ignores unrelated PR metadata while preserving every binding field", () => {
  const { value } = activeJobFixture();
  const context = structuredClone(value.context);
  context.pullRequest.updated_at = "2099-01-01T00:00:00Z";
  context.pullRequest.comments = 5;
  context.workflow.updated_at = "2099-01-01T00:00:00Z";
  assert.deepEqual(
    functionalActiveJobContextBinding(context),
    functionalActiveJobContextBinding(value.context),
  );
  context.pullRequest.head.sha = "d".repeat(40);
  assert.notDeepEqual(
    functionalActiveJobContextBinding(context),
    functionalActiveJobContextBinding(value.context),
  );
});

test("maintained literal authority files reject duplicate nested fields and executable syntax", () => {
  assert.deepEqual(
    functionalLiteralJSON(
      Buffer.from('{"fileScopes":[],"nested":{"present":false}}'),
    ),
    { fileScopes: [], nested: { present: false } },
  );
  for (const value of [
    '{"fileScopes":[],"fileScopes":[]}',
    '{"nested":{"present":true,"present":false}}',
    '{"scope": (() => [])()}',
    '{"scope":undefined}',
    '{"scope":[,]}',
  ])
    assert.throws(() => functionalLiteralJSON(Buffer.from(value)));
});

function savedReaderFixture() {
  const reader = {
    schema: 1,
    owner: "plugins",
    reads: [
      {
        name: "ui-preferences",
        root: "owner-home",
        components: ["Library", "Preferences", { derived: "ui-suite-plist" }],
        format: "property-list",
        maximumBytes: 4096,
        selections: [
          {
            name: "selections",
            path: ["plugins.agentSelections"],
            codec: "data-property-list",
          },
        ],
      },
    ],
    sentinels: [],
    initial: {
      "ui-preferences": {
        selections: { present: true, value: { amp: true, zed: true } },
      },
    },
    final: {
      "ui-preferences": {
        selections: { present: true, value: { amp: false, zed: true } },
      },
    },
  };
  const policy = {
    owner: "plugins",
    fileScopes: [
      {
        name: "preferences",
        root: "owner-home",
        kind: "file",
        purpose: "mutable-state",
        components: [
          { literal: "Library" },
          { literal: "Preferences" },
          { workerDefaultsPlist: "ui" },
        ],
        maximumBytes: 4096,
        maximumEntries: 1,
        initialState: "present",
        allowedStates: ["present"],
        immutableFiles: [],
        mutableFiles: [],
      },
    ],
  };
  return { reader, policy };
}

test("saved readers bind exact original engine and UI suites finite files and raw semantic fields", () => {
  const { reader, policy } = savedReaderFixture();
  assert.equal(validateFunctionalSavedReaderPolicy(reader, policy), reader);
  const engine = savedReaderFixture();
  engine.reader.reads[0].components[2].derived = "engine-suite-plist";
  engine.policy.fileScopes[0].components[2].workerDefaultsPlist = "engine";
  assert.equal(
    validateFunctionalSavedReaderPolicy(engine.reader, engine.policy),
    engine.reader,
  );
  for (const mutate of [
    (f) => {
      f.reader.owner = "foreign";
    },
    (f) => {
      f.reader.reads[0].components[2] = "arbitrary-suite.plist";
    },
    (f) => {
      f.reader.reads[0].components[2].derived = "engine-suite-plist";
    },
    (f) => {
      f.reader.reads[0].root = "owner-data";
    },
    (f) => {
      f.reader.reads[0].components[0] = "..";
    },
    (f) => {
      f.reader.reads[0].maximumBytes = 4097;
    },
    (f) => {
      f.reader.reads[0].maximumBytes = 0;
    },
    (f) => {
      f.reader.reads[0].format = "arbitrary";
    },
    (f) => {
      f.reader.reads[0].selections[0].codec = "arbitrary";
    },
    (f) => {
      f.reader.reads[0].selections[0].path = [];
    },
    (f) => {
      f.reader.reads[0].selections.push(f.reader.reads[0].selections[0]);
    },
    (f) => {
      f.reader.sentinels = [
        {
          name: "duplicate-path",
          root: "owner-home",
          components: f.reader.reads[0].components,
          maximumBytes: 4096,
        },
      ];
    },
    (f) => {
      f.reader.initial = null;
    },
    (f) => {
      f.reader.final["ui-preferences"].selections.present = 1;
    },
    (f) => {
      f.reader.final["ui-preferences"].selections.foreign = true;
    },
    (f) => {
      f.reader.final["ui-preferences"].selections.value = {
        $binding: "arbitrary",
      };
    },
    (f) => {
      f.policy.fileScopes = [];
    },
  ]) {
    const changed = savedReaderFixture();
    mutate(changed);
    assert.throws(() =>
      validateFunctionalSavedReaderPolicy(changed.reader, changed.policy),
    );
  }
});

test("stateless saved readers require finite retained files and owned path bindings cannot widen grants", () => {
  const f = savedReaderFixture();
  f.reader.reads = [];
  f.reader.initial = null;
  f.reader.final = null;
  assert.throws(() => validateFunctionalSavedReaderPolicy(f.reader, f.policy));
  f.reader.sentinels = [
    {
      name: "retained-source",
      root: "owner-home",
      components: ["Library", "Preferences", { derived: "ui-suite-plist" }],
      maximumBytes: 4096,
    },
  ];
  assert.equal(
    validateFunctionalSavedReaderPolicy(f.reader, f.policy),
    f.reader,
  );
  const binding = savedReaderFixture();
  binding.policy.fileScopes.push({
    name: "input-folder",
    root: "owner-inputs",
    kind: "directory",
    components: [{ literal: "folder" }],
    maximumBytes: 0,
    immutableFiles: [],
    mutableFiles: [],
  });
  binding.reader.final["ui-preferences"].selections.value = {
    $binding: "owned-path",
    root: "owner-inputs",
    components: ["folder"],
  };
  assert.equal(
    validateFunctionalSavedReaderPolicy(binding.reader, binding.policy),
    binding.reader,
  );
  binding.reader.final["ui-preferences"].selections.value.components = [
    "foreign",
  ];
  assert.throws(() =>
    validateFunctionalSavedReaderPolicy(binding.reader, binding.policy),
  );
});

test("saved readers admit source-bound phase filenames and decoded embedded fields without generic selection paths", () => {
  const f = savedReaderFixture();
  f.reader.reads[0].selections[0].decodedPath = ["entries", "0", "character"];
  assert.equal(
    validateFunctionalSavedReaderPolicy(f.reader, f.policy),
    f.reader,
  );
  f.reader.reads[0].selections[0].codec = "value";
  assert.throws(() => validateFunctionalSavedReaderPolicy(f.reader, f.policy));
  f.reader.reads[0].selections[0].codec = "data-json";
  f.reader.reads[0].selections[0].decodedPath = [];
  assert.throws(() => validateFunctionalSavedReaderPolicy(f.reader, f.policy));
  const phase = savedReaderFixture();
  phase.reader.reads[0].root = "owner-data";
  phase.reader.reads[0].components = [{ derived: "phase" }, "state.json"];
  phase.policy.fileScopes[0].root = "owner-data";
  phase.policy.fileScopes[0].components = [
    { phase: true },
    { literal: "state.json" },
  ];
  assert.equal(
    validateFunctionalSavedReaderPolicy(phase.reader, phase.policy),
    phase.reader,
  );
  phase.reader.reads[0].components[0].derived = "arbitrary-phase";
  assert.throws(() =>
    validateFunctionalSavedReaderPolicy(phase.reader, phase.policy),
  );
});

test("initial preparations require source literal bytes and exact initial-present file grants", () => {
  const { policy } = savedReaderFixture();
  const preparation = {
    schema: 1,
    owner: "plugins",
    files: [
      {
        root: "owner-home",
        components: structuredClone(policy.fileScopes[0].components),
        maximumBytes: 4096,
        bytesBase64: Buffer.from("synthetic original raw bytes").toString(
          "base64",
        ),
      },
    ],
  };
  assert.equal(
    validateFunctionalPreparationPolicy(preparation, policy),
    preparation,
  );
  for (const mutate of [
    (p) => {
      p.files[0].components[2].workerDefaultsPlist = "engine";
    },
    (p) => {
      p.files[0].components[0] = "Library";
    },
    (p) => {
      p.files[0].root = "owner-data";
    },
    (p) => {
      p.files[0].maximumBytes = 4097;
    },
    (p) => {
      p.files[0].bytesBase64 = "invalid=";
    },
    (p) => {
      p.files[0].expected = true;
    },
    (p) => {
      p.files.push(p.files[0]);
    },
  ]) {
    const changed = structuredClone(preparation);
    mutate(changed);
    assert.throws(() => validateFunctionalPreparationPolicy(changed, policy));
  }
  const absent = structuredClone(policy);
  absent.fileScopes[0].initialState = "absent";
  assert.throws(() => validateFunctionalPreparationPolicy(preparation, absent));
  assert.throws(() =>
    validateFunctionalPreparationPolicy(
      { schema: 1, owner: "plugins", files: [] },
      policy,
    ),
  );
  assert.equal(
    validateFunctionalPreparationPolicy(
      { schema: 1, owner: "plugins", files: [] },
      { owner: "plugins", fileScopes: [] },
    ).files.length,
    0,
  );
});

test("actual single XCTest configuration preserves framework metadata and admits only one signed invocation selector", () => {
  const source = {
    __xctestrun_metadata__: { FormatVersion: 1 },
    HostedFunctionalInstalledUITests: {
      IsUITestBundle: true,
      EnvironmentVariables: { SYNTHETIC_EXISTING: "retained" },
      TestHostPath: "__TESTROOT__/Release/Synthetic.app",
    },
  };
  const configured = functionalInstalledXCTestRunConfiguration(
    source,
    "/private/synthetic/XCTest/invocations/plugins-initial.json",
    activeJobFixture().environment,
  );
  assert.equal(
    configured.HostedFunctionalInstalledUITests.EnvironmentVariables
      .SYNTHETIC_EXISTING,
    "retained",
  );
  assert.equal(
    configured.HostedFunctionalInstalledUITests.EnvironmentVariables
      .EDITH_FUNCTIONAL_XCTEST_INVOCATION,
    "/private/synthetic/XCTest/invocations/plugins-initial.json",
  );
  assert.equal(
    configured.HostedFunctionalInstalledUITests.TestHostPath,
    source.HostedFunctionalInstalledUITests.TestHostPath,
  );
  assert.equal(
    source.HostedFunctionalInstalledUITests.EnvironmentVariables
      .EDITH_FUNCTIONAL_XCTEST_INVOCATION,
    undefined,
  );
  assert.throws(() =>
    functionalInstalledXCTestRunConfiguration(
      { ...source, ForeignTarget: {} },
      "/private/synthetic/invocation",
      {},
    ),
  );
});

test("typed original preparation allows only finite source bindings and property-list data cells", () => {
  const { policy } = savedReaderFixture();
  const file = {
    root: "owner-home",
    components: structuredClone(policy.fileScopes[0].components),
    maximumBytes: 4096,
    codec: "property-list",
    value: {
      "plugins.agentSelections": {
        $data: { codec: "property-list", value: { amp: true, zed: true } },
      },
      marker: { $binding: "session" },
    },
  };
  const preparation = { schema: 1, owner: "plugins", files: [file] };
  assert.equal(
    validateFunctionalPreparationPolicy(preparation, policy),
    preparation,
  );
  for (const mutate of [
    (f) => {
      f.files[0].codec = "json";
    },
    (f) => {
      f.files[0].value.marker.$binding = "arbitrary";
    },
    (f) => {
      f.files[0].value.marker.suffix = ".plist";
    },
    (f) => {
      f.files[0].value.marker = {
        $binding: "owned-path",
        root: "owner-inputs",
        components: [{ literal: "ungranted" }],
      };
    },
    (f) => {
      f.files[0].value["plugins.agentSelections"].$data.codec = "arbitrary";
    },
  ]) {
    const altered = structuredClone(preparation);
    mutate(altered);
    assert.throws(() => validateFunctionalPreparationPolicy(altered, policy));
  }
});

test("only explicit source-fixed stateless owners with zero mutable grants admit empty raw readers", () => {
  const reader = {
    schema: 1,
    owner: "calendar",
    reads: [],
    sentinels: [],
    initial: null,
    final: null,
  };
  assert.equal(
    validateFunctionalSavedReaderPolicy(reader, {
      owner: "calendar",
      outputs: [],
      fileScopes: [],
    }),
    reader,
  );
  assert.throws(() =>
    validateFunctionalSavedReaderPolicy(
      { ...reader, owner: "plugins" },
      { owner: "plugins", fileScopes: [] },
    ),
  );
  assert.throws(() =>
    validateFunctionalSavedReaderPolicy(reader, {
      owner: "calendar",
      outputs: ["arbitrary"],
      fileScopes: [],
    }),
  );
  assert.throws(() =>
    validateFunctionalSavedReaderPolicy(
      { ...reader, final: {} },
      { owner: "calendar", fileScopes: [] },
    ),
  );
});

test("actual source readback selectors preserve scalar roots and property-list decoding with closed native bounds", () => {
  const definition = { owner: "synthetic", operations: ["synthetic.read"] };
  const policy = (field) => ({
    schema: 1,
    owner: "synthetic",
    readback: {
      operation: "synthetic.read",
      payload: {},
      normalizer: { kind: "select-object", fields: { preferences: field } },
    },
    phases: ["initial", "updated", "reinstalled"].map((phase) => ({
      phase,
      before: { kind: "literal", value: "auto" },
      after: { kind: "literal", value: "custom" },
    })),
  });
  for (const field of [
    { path: [], transform: "identity" },
    { path: ["preferences"], transform: "base64-property-list" },
    { path: ["history", 0], transform: "base64-json" },
    { path: ["preferences"], transform: "sha256-string" },
  ]) {
    const value = policy(field);
    assert.equal(validateFunctionalObservationPolicy(value, definition), value);
  }
  for (const field of [
    { path: [], transform: "expected-value" },
    { path: ["invalid\0key"], transform: "identity" },
    { path: [-1], transform: "identity" },
    { path: [true], transform: "identity" },
    { path: Array(17).fill("nested"), transform: "identity" },
    { path: [], transform: "identity", expected: "auto" },
  ])
    assert.throws(() =>
      validateFunctionalObservationPolicy(policy(field), definition),
    );
  for (const key of ["invalid\0key", "x".repeat(129)]) {
    const value = policy({ path: [], transform: "identity" });
    value.readback.normalizer.fields = {
      [key]: { path: [], transform: "identity" },
    };
    assert.throws(() => validateFunctionalObservationPolicy(value, definition));
  }
  const foreign = policy({ path: [], transform: "identity" });
  foreign.readback.operation = "foreign.read";
  assert.throws(() => validateFunctionalObservationPolicy(foreign, definition));
  const reordered = policy({ path: [], transform: "identity" });
  reordered.phases.reverse();
  assert.throws(() =>
    validateFunctionalObservationPolicy(reordered, definition),
  );
});

test("provider literal expectations bind only exact owned source paths and the admitted session", () => {
  const definition = { owner: "synthetic", operations: ["synthetic.read"] };
  const policy = {
    owner: "synthetic",
    fileScopes: [
      {
        kind: "directory",
        root: "owner-home",
        components: [{ literal: "mirror" }],
        immutableFiles: [{ components: ["source.swift"] }],
        mutableFiles: [],
      },
    ],
  };
  const binding = {
    $binding: "owned-path",
    root: "owner-home",
    components: ["mirror"],
  };
  const observation = (value) => ({
    schema: 1,
    owner: "synthetic",
    readback: {
      operation: "synthetic.read",
      payload: {},
      normalizer: { kind: "identity" },
    },
    phases: ["initial", "updated", "reinstalled"].map((phase) => ({
      phase,
      before: {
        kind: "object",
        fields: { folder: { kind: "literal", value } },
      },
      after: { kind: "oneOf", values: [{ $binding: "session" }, value] },
    })),
  });
  for (const value of [
    binding,
    { ...binding, components: ["mirror", "source.swift"] },
  ]) {
    const input = observation(value);
    assert.equal(
      validateFunctionalObservationPolicy(input, definition, policy),
      input,
    );
    assert.throws(() => validateFunctionalObservationPolicy(input, definition));
    assert.throws(() =>
      validateFunctionalObservationPolicy(input, definition, {
        ...policy,
        owner: "foreign",
      }),
    );
  }
  for (const value of [
    { ...binding, root: "owner-data" },
    { ...binding, components: ["mirror", "foreign.swift"] },
    { ...binding, components: ["mirror", ".."] },
    { ...binding, components: [{ derived: "session" }] },
    { ...binding, components: [] },
    { ...binding, expected: "caller" },
    { $binding: "session", expected: "caller" },
    { ...binding, $binding: "caller-path" },
  ])
    assert.throws(() =>
      validateFunctionalObservationPolicy(
        observation(value),
        definition,
        policy,
      ),
    );
});

test("Downloads preparation reserves only the actual native generator's exact immutable audio input", () => {
  const scope = {
    name: "audio-library",
    kind: "directory",
    purpose: "immutable-input",
    root: "owner-home",
    components: [{ literal: "audio-library" }],
    maximumBytes: 16777216,
    maximumEntries: 1,
    initialState: "present",
    allowedStates: ["present"],
    immutableFiles: [
      { components: ["Synthetic saved download.m4a"], maximumBytes: 16777216 },
    ],
    mutableFiles: [],
  };
  const policy = { owner: "downloads", fileScopes: [scope] };
  const preparation = { schema: 1, owner: "downloads", files: [] };
  assert.equal(
    validateFunctionalPreparationPolicy(preparation, policy),
    preparation,
  );
  for (const patch of [
    { name: "foreign" },
    { purpose: "mutable-state" },
    { root: "owner-inputs" },
    { components: [{ literal: "foreign" }] },
    { allowedStates: ["present", "absent"] },
    {
      immutableFiles: [{ components: ["foreign.m4a"], maximumBytes: 16777216 }],
    },
    {
      immutableFiles: [
        { components: ["Synthetic saved download.m4a"], maximumBytes: 1024 },
      ],
    },
  ])
    assert.throws(() =>
      validateFunctionalPreparationPolicy(preparation, {
        ...policy,
        fileScopes: [{ ...scope, ...patch }],
      }),
    );
  const encoded = {
    ...preparation,
    files: [
      {
        root: "owner-home",
        components: [
          { literal: "audio-library" },
          { literal: "Synthetic saved download.m4a" },
        ],
        bytesBase64: Buffer.from("synthetic encoded media").toString("base64"),
        maximumBytes: 16777216,
      },
    ],
  };
  assert.throws(() => validateFunctionalPreparationPolicy(encoded, policy));
});

test("source readiness rejects the explicit original native blocked-case scaffold before hosted execution", async () => {
  const source = await readFile(
    new URL(
      "../../Tests/HostedFunctionalActions/OwnerCases/keepAwakeActionCase.swift",
      import.meta.url,
    ),
  );
  assert.equal(validateFunctionalOriginalCaseSource(source, definition), true);
  for (const marker of [
    'static let blockingReason = "Unfinished original details callback"',
    "throw Blocked()",
    "try fail(context)",
  ])
    assert.throws(() =>
      validateFunctionalOriginalCaseSource(
        Buffer.concat([source, Buffer.from(`\n${marker}`)]),
        definition,
      ),
    );
  assert.throws(() =>
    validateFunctionalOriginalCaseSource(source, {
      ...definition,
      owner: "foreign",
    }),
  );
  assert.throws(() =>
    validateFunctionalOriginalCaseSource(
      Buffer.concat([source, Buffer.from([0xff])]),
      definition,
    ),
  );
  assert.throws(() =>
    validateFunctionalOriginalCaseSource(
      Buffer.concat([source, Buffer.from([0])]),
      definition,
    ),
  );
});

test("large original retained Studio tables use exact native document caps while literal role defaults remain bounded", () => {
  const signed = { x: -0.25, firstFrame: -1, zero: -0 };
  assert.deepEqual(
    functionalLiteralJSON(Buffer.from(JSON.stringify(signed))),
    JSON.parse(JSON.stringify(signed)),
  );
  assert(Object.is(functionalLiteralJSON(Buffer.from("-0")), -0));
  for (const nonfinite of ["1e999", "-1e999", '{"duration":1e999}'])
    assert.throws(() => functionalLiteralJSON(Buffer.from(nonfinite)));
  const project = {
    clips: Array.from({ length: 120 }, (_, index) => ({
      id: `clip-${index}`,
      frames: 30,
      source: "source.mp4",
      retained: "synthetic".repeat(80),
    })),
  };
  const bytes = Buffer.from(JSON.stringify(project));
  assert(bytes.length > 32768 && bytes.length < 262144);
  assert.throws(() => functionalLiteralJSON(bytes));
  assert.deepEqual(functionalLiteralJSON(bytes, 262144), project);
  assert.deepEqual(functionalLiteralJSON(bytes, 1048576), project);
  assert.throws(() => functionalLiteralJSON(bytes, 8388608));
  for (const cap of [32768, 262144, 1048576]) {
    const tooLarge = Buffer.from(JSON.stringify({ retained: "x".repeat(cap) }));
    assert.throws(() => functionalLiteralJSON(tooLarge, cap));
    const duplicate = Buffer.from(
      `{"retained":"${"x".repeat(Math.floor(cap / 2))}","retained":true}`,
    );
    assert.throws(() => functionalLiteralJSON(duplicate, cap));
  }
});

test("live producer observations retain the compiler capability independently of its observer projection", {
  skip: typeof vm.SourceTextModule !== "function",
}, async () => {
  const url = new URL("./controller.mjs", import.meta.url);
  const source = await readFile(url, "utf8");
  assert.match(source, /compilerCapability: built\.compilation/);
  const module = new vm.SourceTextModule(
    `${source}\nexport { producerChannels };`,
    {
      initializeImportMeta(meta) {
        meta.url = url.href;
      },
    },
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
  const compilerCapability = Object.freeze({});
  const plan = Object.freeze({});
  const dependency = Object.freeze({});
  const owned = Object.freeze({});
  const birth = Object.freeze({ pid: 4001 });
  const events = [];
  let current = true;
  const compilation = {
    observer: {
      requireCurrentSync(value) {
        assert.equal(value, owned);
        events.push("birth");
        return birth;
      },
    },
  };
  const channel = Object.freeze({});
  module.namespace.producerChannels.set(channel, {
    compilerCapability,
    compilation,
    plan,
    docsDependency: dependency,
    owned,
    observeDocs(input) {
      assert.equal(input.compilation, compilerCapability);
      assert.notEqual(input.compilation, compilation);
      assert.equal(input.plan, plan);
      assert.equal(input.dependency, dependency);
      assert(current, "Docs dependency lifetime ended");
      events.push("docs");
    },
  });
  assert.equal(module.namespace.observeFunctionalProducer(channel), birth);
  assert.deepEqual(events, ["docs", "birth"]);
  current = false;
  assert.throws(
    () => module.namespace.observeFunctionalProducer(channel),
    /lifetime ended/,
  );
  assert.deepEqual(events, ["docs", "birth"]);
  assert.throws(
    () => module.namespace.observeFunctionalProducer({}),
    /independently launched source-built producer/,
  );
});
