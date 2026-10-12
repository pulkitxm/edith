import assert from "node:assert/strict";
import { createHash, generateKeyPairSync, sign } from "node:crypto";
import { readFile } from "node:fs/promises";
import { test } from "node:test";
import { runInNewContext } from "node:vm";
import { definition as keepAwakeDefinition } from "./cases/keepAwake.mjs";
import { functionalCanonicalJSON, functionalDigest } from "./contract.mjs";
import { functionalActionOwners } from "./owners.mjs";
import {
  cancelFunctionalNativeSession,
  captureFunctionalNativeBaseline,
  createFunctionalNativeOwnerAdapter,
  createFunctionalOwnedCleanup,
  decodeFunctionalCanonicalStorage,
  decodeFunctionalPreferenceStorage,
  drainFunctionalNativeGeneration,
  executeFunctionalOriginalSteps,
  executeFunctionalOwners,
  finishFunctionalNativeSession,
  functionalAdmittedPresentations,
  functionalRunRequiredNativeOperations,
  joinFunctionalOwnedProcesses,
  observeFunctionalNativeXCTestGeneration,
  readFunctionalNativeSaved,
  registerFunctionalNativeXCTestActor,
  removeFunctionalNativeOwner,
  requestFunctionalHost,
  runHostedFunctionalActions,
  validateFunctionalDrainObservation,
  validateFunctionalGenerationDescriptor,
  validateFunctionalNativePresentationObservation,
  validateFunctionalOwnerPlanEntry,
  validateFunctionalOwnerProofInventory,
  validateFunctionalPersistenceObservation,
  validateFunctionalQualifiedAuthority,
  validateFunctionalQualifiedSeal,
  validateFunctionalRemovalObservation,
  validateFunctionalRunNativeSourceOperations,
  validateFunctionalSavedByteSequence,
  validateFunctionalSignedCatalog,
  validateFunctionalXCTestArtifact,
  validateFunctionalXCTestGenerationObservations,
  validateFunctionalXCTestStepObservations,
  verifyQualifiedFunctionalEvidence,
} from "./run-functional.mjs";

const sourceCommit = "a".repeat(40);

function fixture() {
  const plan = {
    sourceCommit,
    concurrency: 1,
    pairScope: "synthetic-development",
    owners: functionalActionOwners.map((owner) => ({
      owner,
      definition: { owner },
      recipe: {},
      phases: [
        { phase: "initial", version: "1.0.0" },
        { phase: "updated", version: "1.1.0" },
        { phase: "reinstalled", version: "1.1.0" },
      ],
    })),
  };
  let active = 0;
  let observations = 0;
  let cleanups = 0;
  const visited = [];
  return {
    plan,
    async requireCurrent() {
      observations++;
    },
    async runOwner(owner) {
      assert.equal(active++, 0);
      await Promise.resolve();
      visited.push(owner.owner);
      active--;
      return { owner: owner.owner, sourceCommit };
    },
    async cancelAndJoin() {
      cleanups++;
    },
    counts: () => ({ active, observations, cleanups, visited }),
  };
}

test("all owners execute once with the same current issuer and complete phase plan", async () => {
  const f = fixture();
  const results = await executeFunctionalOwners(f);
  assert.deepEqual(f.counts().visited, functionalActionOwners);
  assert.equal(results.length, 39);
  assert.equal(f.counts().observations, 80);
  assert.equal(f.counts().cleanups, 0);
  assert.equal(Object.isFrozen(results), true);
  assert(
    results.every(
      (result) => !Object.hasOwn(result, "functionalActionsValidated"),
    ),
  );
});

test("an owner failure stops further admission and awaits actual cleanup", async () => {
  const f = fixture();
  const failure = new Error("original action failed");
  let release;
  let cleanupEntered;
  const entered = new Promise((resolve) => {
    cleanupEntered = resolve;
  });
  const pending = new Promise((resolve) => {
    release = resolve;
  });
  const original = f.runOwner;
  f.runOwner = async (owner) => {
    if (owner.owner === functionalActionOwners[2]) throw failure;
    return original(owner);
  };
  f.cancelAndJoin = async () => {
    cleanupEntered();
    await pending;
  };
  let completed = false;
  const running = executeFunctionalOwners(f).finally(() => {
    completed = true;
  });
  await entered;
  assert.equal(completed, false);
  assert.deepEqual(f.counts().visited, functionalActionOwners.slice(0, 2));
  release();
  await assert.rejects(running, (error) => error === failure);
});

test("changed live issuer is rejected before the next owner", async () => {
  const f = fixture();
  const original = f.requireCurrent;
  f.requireCurrent = async () => {
    await original();
    if (f.counts().observations === 3) throw new Error("owned issuer retired");
  };
  await assert.rejects(executeFunctionalOwners(f), /owned issuer retired/);
  assert.deepEqual(f.counts().visited, functionalActionOwners.slice(0, 1));
  assert.equal(f.counts().cleanups, 1);
});

test("missing, duplicated, reordered and concurrent owner plans fail before execution", async () => {
  for (const change of [
    (plan) => plan.owners.pop(),
    (plan) => {
      plan.owners[1] = plan.owners[0];
    },
    (plan) => plan.owners.reverse(),
    (plan) => {
      plan.concurrency = 3;
    },
    (plan) => {
      plan.owners[0].phases[1].version = "1.0.0";
    },
    (plan) => {
      plan.owners[0].definition.owner = "foreign";
    },
  ]) {
    const f = fixture();
    change(f.plan);
    await assert.rejects(executeFunctionalOwners(f));
    assert.equal(f.counts().visited.length, 0);
    assert.equal(f.counts().cleanups, 1);
  }
});

test("plan mutation during an awaited native action fails after joining cleanup", async () => {
  const f = fixture();
  const original = f.runOwner;
  f.runOwner = async (owner) => {
    const result = await original(owner);
    f.plan.owners[0].recipe.changed = true;
    return result;
  };
  await assert.rejects(executeFunctionalOwners(f), /Execution plan changed/);
  assert.equal(f.counts().cleanups, 1);
  assert.deepEqual(f.counts().visited, functionalActionOwners.slice(0, 1));
});

test("foreign owner and source outcomes cannot enter the completed inventory", async () => {
  for (const result of [
    { owner: "foreign", sourceCommit },
    { owner: functionalActionOwners[0], sourceCommit: "b".repeat(40) },
  ]) {
    const f = fixture();
    f.runOwner = async () => result;
    await assert.rejects(executeFunctionalOwners(f));
    assert.equal(f.counts().cleanups, 1);
  }
});

test("aborted execution drains owned work and admits no next owner", async () => {
  const f = fixture();
  const controller = new AbortController();
  f.signal = controller.signal;
  const original = f.runOwner;
  f.runOwner = async (owner, signal) => {
    assert.equal(signal, controller.signal);
    const result = await original(owner);
    controller.abort(new Error("stop requested"));
    return result;
  };
  await assert.rejects(executeFunctionalOwners(f), /stop requested/);
  assert.equal(f.counts().cleanups, 1);
  assert.deepEqual(f.counts().visited, functionalActionOwners.slice(0, 1));
});

test("cleanup failure preserves both failures and produces no result", async () => {
  const f = fixture();
  const failure = new Error("native action failed");
  const cleanup = new Error("actual join failed");
  f.runOwner = async () => {
    throw failure;
  };
  f.cancelAndJoin = async () => {
    throw cleanup;
  };
  await assert.rejects(executeFunctionalOwners(f), (error) => {
    assert(error instanceof AggregateError);
    assert.deepEqual(error.errors, [failure, cleanup]);
    return true;
  });
});

test("owned natural joins await every child and reject any signal or missing exit", async () => {
  let release;
  const pending = new Promise((resolve) => {
    release = resolve;
  });
  const owned = {
    child: { exitCode: null, signalCode: null },
    joined: pending,
  };
  let completed = false;
  const joining = joinFunctionalOwnedProcesses([owned]).then(() => {
    completed = true;
  });
  await Promise.resolve();
  assert.equal(completed, false);
  owned.child.exitCode = 0;
  release();
  await joining;
  assert.equal(completed, true);
  for (const child of [
    { exitCode: 0, signalCode: "SIGTERM" },
    { exitCode: null, signalCode: null },
  ]) {
    await assert.rejects(
      joinFunctionalOwnedProcesses([{ child, joined: Promise.resolve() }]),
    );
  }
  await assert.rejects(joinFunctionalOwnedProcesses([owned, owned]));
});

test("native session authority cannot be supplied as plain JSON", async () => {
  for (const session of [
    { sourceCommit },
    Object.freeze({ sourceCommit, admittedIssuer: {}, admittedArtifact: {} }),
  ]) {
    await assert.rejects(
      requestFunctionalHost(session, functionalActionOwners[0], "install", {
        version: "1.0.0",
      }),
      /Expected owned live native session/,
    );
    await assert.rejects(
      finishFunctionalNativeSession(session),
      /Expected owned live native session/,
    );
    await assert.rejects(
      cancelFunctionalNativeSession(session),
      /Expected owned native session/,
    );
  }
});

test("a failed child cannot finish cleanup before another owned child joins", async () => {
  let release;
  const pending = new Promise((resolve) => {
    release = resolve;
  });
  const failed = {
    child: { exitCode: null, signalCode: "SIGTERM" },
    joined: Promise.resolve(),
  };
  const other = {
    child: { exitCode: null, signalCode: null },
    joined: pending,
  };
  let completed = false;
  const joining = joinFunctionalOwnedProcesses([failed, other]).finally(() => {
    completed = true;
  });
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(completed, false);
  other.child.exitCode = 0;
  release();
  await assert.rejects(
    joining,
    (error) => error instanceof AggregateError && error.errors.length === 1,
  );
});

function signedCatalogFixture(change = () => {}) {
  const { privateKey, publicKey } = generateKeyPairSync("ed25519");
  const catalog = {
    schemaVersion: 1,
    revision: 1,
    packages: [
      {
        id: functionalActionOwners[0],
        version: "1.0.0",
        hostABI: "edith-host-2",
        architecture: "arm64",
        dependencies: [],
      },
    ],
  };
  change(catalog);
  const payload = Buffer.from(functionalCanonicalJSON(catalog));
  const envelope = {
    payload: payload.toString("base64"),
    signature: sign(null, payload, privateKey).toString("base64"),
  };
  return {
    catalog,
    bytes: Buffer.from(functionalCanonicalJSON(envelope)),
    issuerDER: publicKey.export({ format: "der", type: "spki" }),
  };
}

test("same issuer catalog signature binds the actual single original package selection", () => {
  const fixture = signedCatalogFixture();
  assert.deepEqual(
    validateFunctionalSignedCatalog(
      fixture.bytes,
      fixture.issuerDER,
      functionalActionOwners[0],
      "1.0.0",
    ),
    fixture.catalog,
  );
  const foreign = signedCatalogFixture();
  assert.throws(
    () =>
      validateFunctionalSignedCatalog(
        fixture.bytes,
        foreign.issuerDER,
        functionalActionOwners[0],
        "1.0.0",
      ),
    /Catalog signer differs/,
  );
  assert.equal(
    Object.hasOwn(fixture.catalog, "functionalActionsValidated"),
    false,
  );
});

test("signed catalogs still reject foreign owners, versions, duplicate packages and altered payloads", () => {
  for (const change of [
    (catalog) => {
      catalog.packages[0].id = functionalActionOwners[1];
    },
    (catalog) => {
      catalog.packages[0].version = "1.1.0";
    },
    (catalog) => {
      catalog.revision = 2;
    },
    (catalog) => {
      catalog.packages.push(catalog.packages[0]);
    },
    (catalog) => {
      catalog.packages[0].hostABI = "foreign";
    },
    (catalog) => {
      catalog.packages[0].architecture = "x86_64";
    },
    (catalog) => {
      catalog.packages[0].dependencies = ["foreign"];
    },
  ]) {
    const fixture = signedCatalogFixture(change);
    assert.throws(() =>
      validateFunctionalSignedCatalog(
        fixture.bytes,
        fixture.issuerDER,
        functionalActionOwners[0],
        "1.0.0",
      ),
    );
  }
  const fixture = signedCatalogFixture();
  const envelope = JSON.parse(fixture.bytes);
  envelope.payload = Buffer.from("{}").toString("base64");
  assert.throws(
    () =>
      validateFunctionalSignedCatalog(
        Buffer.from(functionalCanonicalJSON(envelope)),
        fixture.issuerDER,
        functionalActionOwners[0],
        "1.0.0",
      ),
    /Catalog signer differs/,
  );
  const malformed = JSON.parse(fixture.bytes);
  malformed.payload += "\n";
  assert.throws(() =>
    validateFunctionalSignedCatalog(
      Buffer.from(functionalCanonicalJSON(malformed)),
      fixture.issuerDER,
      functionalActionOwners[0],
      "1.0.0",
    ),
  );
});

const storageBytes = (value) => Buffer.from(functionalCanonicalJSON(value));

function savedSequence() {
  const saved = storageBytes({
    preference: { present: true, value: { enabled: true } },
  });
  return {
    applicable: true,
    phases: [
      { phase: "initial", baseline: null, saved: Buffer.from(saved) },
      {
        phase: "updated",
        baseline: Buffer.from(saved),
        saved: Buffer.from(saved),
      },
      {
        phase: "reinstalled",
        baseline: Buffer.from(saved),
        saved: Buffer.from(saved),
      },
    ],
    removed: Buffer.from(saved),
  };
}

test("canonical native storage preserves presence, decoded JSON and masked values", () => {
  const value = {
    absent: { present: false },
    decoded: { present: true, value: { names: ["synthetic"], enabled: false } },
    secret: { present: true, value: { maskedSHA256: "b".repeat(64) } },
  };
  assert.deepEqual(
    decodeFunctionalPreferenceStorage(
      storageBytes(value),
      ["absent", "decoded", "secret"],
      ["secret"],
    ),
    value,
  );
  assert.deepEqual(
    decodeFunctionalCanonicalStorage(
      storageBytes({ height: 1080, duration: { value: 3600, timescale: 30 } }),
    ),
    { height: 1080, duration: { value: 3600, timescale: 30 } },
  );
  for (const bytes of [
    Buffer.from('{"a":1,"a":2}'),
    Buffer.from('{"a":1}\n'),
    Buffer.from('{ "a": 1 }'),
    Buffer.from('{"a":9007199254740993}'),
    Buffer.from("[1]"),
    Buffer.from("null"),
    Buffer.from([0xff]),
  ])
    assert.throws(() => decodeFunctionalCanonicalStorage(bytes));
});

test("preference reader forms reject extra keys, missing presence and unmasked secrets", () => {
  for (const value of [
    { key: { value: true } },
    { key: { present: false, value: true } },
    { key: { present: "true", value: true } },
    { key: { present: true, value: "synthetic" } },
    { key: { present: true, value: { maskedSHA256: "wrong" } } },
    { key: { present: false }, foreign: { present: false } },
  ])
    assert.throws(() =>
      decodeFunctionalPreferenceStorage(storageBytes(value), ["key"], ["key"]),
    );
  assert.throws(() =>
    decodeFunctionalPreferenceStorage(
      storageBytes({ key: { present: false } }),
      ["key", "key"],
    ),
  );
});

test("raw saved bytes survive before construction, restoration and actual removal boundary", () => {
  const result = validateFunctionalSavedByteSequence(savedSequence());
  assert.match(result.savedSHA256, /^[0-9a-f]{64}$/);
  assert.deepEqual(Object.keys(result), ["savedSHA256"]);
  for (const change of [
    (sequence) => {
      sequence.phases[1].baseline = storageBytes({ changed: true });
    },
    (sequence) => {
      sequence.phases[1].saved = storageBytes({ changed: true });
    },
    (sequence) => {
      sequence.phases[2].baseline = null;
    },
    (sequence) => {
      sequence.phases[2].saved = storageBytes({ changed: true });
    },
    (sequence) => {
      sequence.removed = storageBytes({ changed: true });
    },
    (sequence) => {
      sequence.phases.reverse();
    },
    (sequence) => {
      sequence.phases[0].saved = null;
    },
  ]) {
    const sequence = savedSequence();
    change(sequence);
    assert.throws(() => validateFunctionalSavedByteSequence(sequence));
  }
  const absent = {
    applicable: false,
    phases: ["initial", "updated", "reinstalled"].map((phase) => ({
      phase,
      baseline: null,
      saved: null,
    })),
    removed: null,
  };
  assert.equal(validateFunctionalSavedByteSequence(absent).savedSHA256, null);
  absent.phases[0].saved = storageBytes({ providerPacket: true });
  assert.throws(() => validateFunctionalSavedByteSequence(absent));
});

test("all owner inventories require real signed native records rather than result flags", () => {
  const session = "12345678-1234-4123-8123-123456789abc";
  const f = fixture();
  const proofs = functionalActionOwners.map((owner) => ({
    claim: { owner },
    observation: { functionalActionsValidated: true },
  }));
  const inventory = {
    plan: f.plan,
    proofs,
    issuerDER: signedCatalogFixture().issuerDER,
    session,
    fixtureRoot: `/private/synthetic/functional-fixture-${session}`,
  };
  assert.throws(() => validateFunctionalOwnerProofInventory(inventory));
  for (const change of [
    (value) => {
      value.proofs.pop();
    },
    (value) => {
      value.proofs[1] = value.proofs[0];
    },
    (value) => {
      value.proofs.reverse();
    },
    (value) => {
      value.plan.owners.reverse();
    },
    (value) => {
      value.session = "wrong";
    },
  ]) {
    const value = structuredClone(inventory);
    change(value);
    assert.throws(() => validateFunctionalOwnerProofInventory(value));
  }
});

function generationFixture(change = () => {}) {
  const { privateKey, publicKey } = generateKeyPairSync("ed25519");
  const session = "12345678-1234-4123-8123-123456789abc";
  const root = `/private/synthetic/functional-fixture-${session}`;
  const workerPath = `${root}/Edith Tests/worker-${session}/Extensions/keepAwake/edith-host-2/arm64/1.0.0/keepAwake/ExtensionCarrier.app/Contents/Extensions/ExtensionWorker.appex`;
  const engine = {
    pid: 31,
    birthSeconds: 100,
    birthMicroseconds: 1,
    uid: 501,
    executableSHA256: "b".repeat(64),
  };
  const ui = {
    pid: 32,
    birthSeconds: 100,
    birthMicroseconds: 2,
    uid: 501,
    executableSHA256: "c".repeat(64),
  };
  const producer = {
    pid: 33,
    birthSeconds: 100,
    birthMicroseconds: 3,
    uid: 501,
    executable: `${root}/Producer/functional-producer`,
    executableSHA256: "d".repeat(64),
  };
  const capability = {
    schema: 1,
    sourceCommit,
    session,
    owner: "keepAwake",
    uid: 501,
    fixtureRoot: root,
    hostIdentifier: `com.pulkit.edith.tests.worker-${session}`,
    home: `${root}/keepAwake-home`,
    dataDirectory: `${root}/Edith Tests/worker-${session}/Data/keepAwake`,
    hostABI: "edith-host-2",
    caseSHA256: functionalDigest(keepAwakeDefinition),
    activationOperation: keepAwakeDefinition.activation.operation,
    phase: "initial",
    pairScope: "synthetic-development",
    previousVersion: "1.0.0",
    currentVersion: "1.1.0",
    version: "1.0.0",
    packageSHA256: "e".repeat(64),
    engine,
    ui,
    operations: keepAwakeDefinition.operations,
    ownedPaths: [
      {
        name: "owner-data",
        path: `${root}/Edith Tests/worker-${session}/Data/keepAwake`,
        kind: "directory",
      },
    ],
  };
  const presentationID = "23456789-1234-4123-8123-123456789abc";
  const descriptor = {
    schema: 1,
    sourceCommit,
    session,
    owner: "keepAwake",
    phase: "initial",
    presentationID,
    location: "main",
    section: "settings",
    capabilitySHA256: functionalDigest(capability),
    root,
    hostIdentifier: capability.hostIdentifier,
    home: capability.home,
    dataDirectory: capability.dataDirectory,
    workerPath,
    rolePath: `${workerPath}/Contents/Resources/Payload/keepAwake/helper.bundle`,
    version: "1.0.0",
    hostABI: "edith-host-2",
    packageSHA256: capability.packageSHA256,
    producer,
    engine: {
      ...engine,
      executable: `${root}/Fixture.app/Contents/MacOS/Edith`,
    },
    ui: { ...ui, executable: `${workerPath}/Contents/MacOS/Edith` },
  };
  change(descriptor);
  const payload = functionalCanonicalJSON(descriptor);
  const observation = {
    schema: 1,
    payload,
    signature: sign(null, Buffer.from(payload), privateKey).toString("base64"),
  };
  const generation = { capability, presentationID, descriptor: observation };
  return {
    generation,
    definition: keepAwakeDefinition,
    issuerDER: publicKey.export({ format: "der", type: "spki" }),
    expected: {
      sourceCommit,
      session,
      fixtureRoot: root,
      owner: "keepAwake",
      phase: "initial",
      version: "1.0.0",
      packageSHA256: capability.packageSHA256,
      location: "main",
      section: "settings",
      producer,
      ui: { ...ui, executable: `${workerPath}/Contents/MacOS/Edith` },
      primaryRole: "helper",
    },
  };
}

test("actual signed generation descriptor binds observed producer, UI, phase and source package", () => {
  const fixture = generationFixture();
  const descriptor = validateFunctionalGenerationDescriptor(fixture);
  assert.equal(
    descriptor.capabilitySHA256,
    functionalDigest(fixture.generation.capability),
  );
  assert.equal(Object.hasOwn(descriptor, "functionalActionsValidated"), false);
  const foreign = generationFixture();
  assert.throws(() =>
    validateFunctionalGenerationDescriptor({
      ...fixture,
      issuerDER: foreign.issuerDER,
    }),
  );
});

test("signed generation descriptors reject mismatched real birth, presentation and package fields", () => {
  for (const change of [
    (value) => {
      value.sourceCommit = "b".repeat(40);
    },
    (value) => {
      value.phase = "updated";
    },
    (value) => {
      value.presentationID = "34567890-1234-4123-8123-123456789abc";
    },
    (value) => {
      value.capabilitySHA256 = "f".repeat(64);
    },
    (value) => {
      value.packageSHA256 = "f".repeat(64);
    },
    (value) => {
      value.ui = { ...value.ui, pid: 34 };
    },
    (value) => {
      value.producer = { ...value.producer, birthMicroseconds: 9 };
    },
    (value) => {
      value.rolePath = `${value.workerPath}/foreign.bundle`;
    },
    (value) => {
      value.engine = {
        ...value.engine,
        executable: "/private/synthetic/foreign",
      };
    },
  ])
    assert.throws(() =>
      validateFunctionalGenerationDescriptor(generationFixture(change)),
    );
});

test("owned cleanup retries retained callbacks and shares each in-flight attempt", async () => {
  let cancels = 0,
    joins = 0,
    closes = 0;
  const cancellationFailure = new Error("actual producer join pending");
  const closeFailure = new Error("observer still owns live children");
  const cleanup = createFunctionalOwnedCleanup({
    cancelProducer: async () => {
      if (++cancels === 1) throw cancellationFailure;
    },
    joinProcesses: async () => {
      joins++;
    },
    closeCompilation: async () => {
      if (++closes === 1) throw closeFailure;
    },
  });
  const first = cleanup();
  assert.equal(cleanup(), first);
  await assert.rejects(
    first,
    (error) =>
      error instanceof AggregateError &&
      error.errors[0] === cancellationFailure &&
      error.errors[1] === closeFailure,
  );
  const retry = cleanup();
  assert.notEqual(retry, first);
  await retry;
  assert.deepEqual([cancels, joins, closes], [2, 2, 2]);
  assert.equal(cleanup(), retry);
  await cleanup();
  assert.deepEqual([cancels, joins, closes], [2, 2, 2]);
});

test("cleanup cannot release compiler ownership while a natural process join is pending", async () => {
  let release;
  const pending = new Promise((resolve) => {
    release = resolve;
  });
  let closed = false;
  const failure = new Error("producer cleanup failed");
  const cleanup = createFunctionalOwnedCleanup({
    cancelProducer: async () => {
      throw failure;
    },
    joinProcesses: () => pending,
    closeCompilation: async () => {
      closed = true;
    },
  });
  const running = cleanup();
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(closed, false);
  release();
  await assert.rejects(
    running,
    (error) => error instanceof AggregateError && error.errors[0] === failure,
  );
  assert.equal(closed, true);
});

test("generation owner entries must equal the admitted literal case and original recipe", () => {
  const ownerPlan = fixture().plan.owners[0];
  const plan = {
    definitions: [ownerPlan.definition],
    recipes: { [ownerPlan.owner]: ownerPlan.recipe },
  };
  const entry = validateFunctionalOwnerPlanEntry(
    plan,
    structuredClone(ownerPlan),
  );
  assert.equal(entry.definition, plan.definitions[0]);
  assert.equal(entry.recipe, plan.recipes[ownerPlan.owner]);
  for (const change of [
    (entry) => {
      entry.definition.operations = ["foreign.activation"];
    },
    (entry) => {
      entry.recipe.steps = [];
    },
    (entry) => {
      entry.phases[1].version = "1.0.0";
    },
    (entry) => {
      entry.authority = true;
    },
  ]) {
    const alternative = structuredClone(ownerPlan);
    change(alternative);
    assert.throws(() => validateFunctionalOwnerPlanEntry(plan, alternative));
  }
  assert.throws(() =>
    validateFunctionalOwnerPlanEntry(
      {
        definitions: [ownerPlan.definition, ownerPlan.definition],
        recipes: plan.recipes,
      },
      ownerPlan,
    ),
  );
  assert.throws(() =>
    validateFunctionalOwnerPlanEntry(
      { definitions: plan.definitions, recipes: {} },
      ownerPlan,
    ),
  );
});

test("original controls execute in literal order with live admission around every awaited action", async () => {
  const steps = [
    { action: "replace-text", value: "synthetic" },
    { action: "click", value: null },
  ];
  const events = [];
  let firstDone;
  const pending = new Promise((resolve) => {
    firstDone = resolve;
  });
  const firstReply = { controlPerformed: true };
  const running = executeFunctionalOriginalSteps({
    steps,
    requireCurrent: async () => {
      events.push("current");
    },
    performStep: async (step) => {
      events.push(step.action);
      if (step === steps[0]) return pending;
      return { controlPerformed: true };
    },
  });
  await new Promise((resolve) => setImmediate(resolve));
  assert.deepEqual(events, ["current", "replace-text"]);
  firstDone(firstReply);
  const replies = await running;
  assert.equal(replies[0], firstReply);
  assert.deepEqual(events, [
    "current",
    "replace-text",
    "current",
    "current",
    "click",
    "current",
  ]);
});

test("step failures and cancellation cannot retry mutations or execute later original controls", async () => {
  const steps = [
    { action: "click", value: null },
    { action: "submit", value: null },
  ];
  for (const boundary of ["actuator", "current", "cancel", "mutated"]) {
    const signal = new AbortController();
    const failure = new Error("actual original boundary failed");
    let actions = 0;
    let current = 0;
    await assert.rejects(
      executeFunctionalOriginalSteps({
        steps: structuredClone(steps),
        signal: signal.signal,
        requireCurrent: async () => {
          if (++current === 2 && boundary === "current") throw failure;
        },
        performStep: async (step) => {
          actions++;
          if (boundary === "actuator") throw failure;
          if (boundary === "cancel") signal.abort(failure);
          if (boundary === "mutated") step.value = "foreign";
          return { controlPerformed: true };
        },
      }),
    );
    assert.equal(actions, 1);
  }
});

function xctestArtifactFixture() {
  const capability = generationFixture().generation.capability;
  const directory = `${capability.fixtureRoot}/XCTest`;
  const sourceSHA256 = "e".repeat(64);
  const identifier = `com.pulkit.edith.tests.installed-${sourceSHA256.slice(0, 24)}`;
  const runnerPath = `${directory}/DerivedData/Build/Products/Release/HostedFunctionalInstalledUITests-Runner.app`;
  return {
    capability,
    artifact: {
      runnerPath,
      testBundlePath: `${runnerPath}/Contents/PlugIns/HostedFunctionalInstalledUITests.xctest`,
      sourcePath: `${directory}/HostedFunctionalInstalledUITests.swift`,
      sourceSHA256,
      runnerIdentifier: `${identifier}.xctrunner`,
      runnerRequirement: `identifier "${identifier}.xctrunner"`,
      runnerExecutableSHA256: "a".repeat(64),
      testBundleIdentifier: identifier,
      testBundleRequirement: `identifier "${identifier}"`,
      testBundleExecutableSHA256: "b".repeat(64),
    },
  };
}

test("XCTest registration selectors pin the actual nested source-built runner and test module", () => {
  const { artifact, capability } = xctestArtifactFixture();
  assert.equal(
    validateFunctionalXCTestArtifact(artifact, capability, 0),
    artifact,
  );
  for (const change of [
    (value) => {
      value.runnerPath = value.runnerPath.replace("/XCTest/", "/Foreign/");
    },
    (value) => {
      value.testBundlePath = `${value.runnerPath}/Foreign.xctest`;
    },
    (value) => {
      value.sourcePath = `${capability.fixtureRoot}/Foreign.swift`;
    },
    (value) => {
      value.sourceSHA256 = "f".repeat(64);
    },
    (value) => {
      value.runnerRequirement = "identifier *";
    },
    (value) => {
      value.testBundleIdentifier = "foreign.bundle";
    },
    (value) => {
      value.testBundleExecutableSHA256 = "not-a-hash";
    },
    (value) => {
      value.actorPID = 17;
    },
  ]) {
    const alternative = structuredClone(artifact);
    change(alternative);
    assert.throws(() =>
      validateFunctionalXCTestArtifact(alternative, capability, 0),
    );
  }
});

test("public XCTest metadata cannot manufacture an owned native generation", async () => {
  const { artifact } = xctestArtifactFixture();
  await assert.rejects(
    registerFunctionalNativeXCTestActor({
      session: {},
      generation: generationFixture().generation,
      stepIndex: 0,
      artifact,
    }),
    /Expected owned live native session/,
  );
});

function xctestObservationFixture(change = () => {}) {
  const { artifact, capability } = xctestArtifactFixture();
  const registration = {
    owner: capability.owner,
    phase: capability.phase,
    stepCount: 1,
    presentationID: "23456789-1234-4123-8123-123456789abc",
    capabilitySHA256: functionalDigest(capability),
    recipeSHA256: "d".repeat(64),
    sourceSHA256: artifact.sourceSHA256,
    invocationPath: `${capability.fixtureRoot}/XCTest/invocations/${capability.owner}-${capability.phase}.json`,
  };
  const actor = {
    pid: 44,
    birthSeconds: 120,
    birthMicroseconds: 3,
    uid: capability.uid,
    executable: `${artifact.runnerPath}/Contents/MacOS/HostedFunctionalInstalledUITests-Runner`,
    executableSHA256: artifact.runnerExecutableSHA256,
  };
  const { invocationPath, recipeSHA256, stepCount, ...signedRegistration } =
    registration;
  const authorization = {
    schema: 1,
    sourceCommit: capability.sourceCommit,
    session: capability.session,
    requestID: "34567890-1234-4123-8123-123456789abc",
    operation: "authorize-original-step",
    authorizationID: "45678901-1234-4123-8123-123456789abc",
    actor,
    ...signedRegistration,
    stepIndex: 0,
    stepSHA256: "f".repeat(64),
    firstEventOrdinal: 4,
    lastEventOrdinal: 4,
  };
  const completion = {
    ...structuredClone(authorization),
    requestID: "56789012-1234-4123-8123-123456789abc",
    operation: "complete-original-step",
    lastEventOrdinal: 9,
  };
  change({ authorization, completion, registration, artifact });
  const { publicKey, privateKey } = generateKeyPairSync("ed25519");
  const envelope = (claim) => {
    const payload = functionalCanonicalJSON(claim);
    return {
      schema: 1,
      payload,
      signature: sign(null, Buffer.from(payload), privateKey).toString(
        "base64",
      ),
    };
  };
  return {
    observations: {
      authorization: envelope(authorization),
      completion: envelope(completion),
    },
    issuerDER: publicKey.export({ format: "der", type: "spki" }),
    capability,
    registration,
    artifact,
    stepIndex: 0,
    stepSHA256: "f".repeat(64),
  };
}

test("signed XCTest boundaries bind the same actual actor, authorization and source step journal range", () => {
  const fixture = xctestObservationFixture();
  const claims = validateFunctionalXCTestStepObservations(fixture);
  assert.equal(claims.completion.lastEventOrdinal, 9);
  assert.equal(Object.hasOwn(claims.completion, "controlPerformed"), false);
  assert.throws(() =>
    validateFunctionalXCTestStepObservations({
      ...fixture,
      issuerDER: xctestObservationFixture().issuerDER,
    }),
  );
});

test("XCTest signed boundary pairs reject foreign actor births, replay and narrowed source bindings", () => {
  for (const change of [
    ({ completion }) => {
      completion.actor.birthMicroseconds++;
    },
    ({ completion }) => {
      completion.actor.uid++;
    },
    ({ completion }) => {
      completion.actor.executableSHA256 = "c".repeat(64);
    },
    ({ completion }) => {
      completion.actor.executable = "/private/synthetic/foreign";
    },
    ({ completion }) => {
      completion.authorizationID = "67890123-1234-4123-8123-123456789abc";
    },
    ({ completion, authorization }) => {
      completion.requestID = authorization.requestID;
    },
    ({ completion }) => {
      completion.firstEventOrdinal = 3;
    },
    ({ authorization }) => {
      authorization.lastEventOrdinal = 5;
    },
    ({ completion }) => {
      completion.lastEventOrdinal = 3;
    },
    ({ completion }) => {
      completion.sourceCommit = "b".repeat(40);
    },
    ({ completion }) => {
      completion.stepSHA256 = "c".repeat(64);
    },
    ({ completion }) => {
      completion.presentationID = "78901234-1234-4123-8123-123456789abc";
    },
    ({ completion }) => {
      completion.controlPerformed = true;
    },
    ({ registration }) => {
      delete registration.owner;
    },
  ])
    assert.throws(() =>
      validateFunctionalXCTestStepObservations(
        xctestObservationFixture(change),
      ),
    );
});

test("XCTest observations cannot be queried through an unowned native session", async () => {
  await assert.rejects(
    observeFunctionalNativeXCTestGeneration({
      session: {},
      generation: generationFixture().generation,
      stepIndex: 0,
    }),
    /Expected owned live native session/,
  );
});

function xctestGenerationFixture(change = () => {}) {
  const fixture = xctestObservationFixture();
  const steps = [
    { action: "click", label: "Synthetic A" },
    { action: "click", label: "Synthetic B" },
  ];
  const registration = { ...fixture.registration, stepCount: steps.length };
  const { publicKey, privateKey } = generateKeyPairSync("ed25519");
  const claims = steps.map((step, stepIndex) => {
    const authorization = JSON.parse(
      fixture.observations.authorization.payload,
    );
    const completion = JSON.parse(fixture.observations.completion.payload);
    for (const claim of [authorization, completion]) {
      claim.stepIndex = stepIndex;
      claim.stepSHA256 = functionalDigest(step);
      claim.authorizationID = `${stepIndex ? "67890123" : "45678901"}-1234-4123-8123-123456789abc`;
      claim.firstEventOrdinal = 4 + stepIndex * 6;
      claim.lastEventOrdinal = claim.firstEventOrdinal;
    }
    authorization.requestID = `${stepIndex ? "78901234" : "34567890"}-1234-4123-8123-123456789abc`;
    completion.requestID = `${stepIndex ? "89012345" : "56789012"}-1234-4123-8123-123456789abc`;
    completion.lastEventOrdinal += 5;
    return { stepIndex, authorization, completion };
  });
  change({ claims, steps, registration });
  const seal = (claim) => {
    const payload = functionalCanonicalJSON(claim);
    return {
      schema: 1,
      payload,
      signature: sign(null, Buffer.from(payload), privateKey).toString(
        "base64",
      ),
    };
  };
  return {
    ...fixture,
    registration,
    steps,
    issuerDER: publicKey.export({ format: "der", type: "spki" }),
    observations: {
      steps: claims.map(({ stepIndex, authorization, completion }) => ({
        stepIndex,
        authorization: seal(authorization),
        completion: seal(completion),
      })),
    },
  };
}

test("one source-built phase actor carries every ordered original recipe step", () => {
  const fixture = xctestGenerationFixture();
  const claims = validateFunctionalXCTestGenerationObservations(fixture);
  assert.equal(claims.length, 2);
  assert.deepEqual(claims[0].authorization.actor, claims[1].completion.actor);
});

test("phase observations reject missing steps, actor substitution, reused boundaries and reordered journals", () => {
  for (const change of [
    ({ claims }) => {
      claims.pop();
    },
    ({ claims }) => {
      claims.reverse();
    },
    ({ claims }) => {
      claims[1].authorization.actor.birthMicroseconds++;
      claims[1].completion.actor.birthMicroseconds++;
    },
    ({ claims }) => {
      claims[1].authorization.authorizationID =
        claims[0].authorization.authorizationID;
      claims[1].completion.authorizationID =
        claims[0].authorization.authorizationID;
    },
    ({ claims }) => {
      claims[1].authorization.requestID = claims[0].authorization.requestID;
    },
    ({ claims }) => {
      claims[1].authorization.firstEventOrdinal = 3;
      claims[1].authorization.lastEventOrdinal = 3;
      claims[1].completion.firstEventOrdinal = 3;
    },
    ({ steps }) => {
      steps[1].label = "Narrowed source";
    },
    ({ registration }) => {
      registration.invocationPath += ".foreign";
    },
  ])
    assert.throws(() =>
      validateFunctionalXCTestGenerationObservations(
        xctestGenerationFixture(change),
      ),
    );
});

function persistenceFixture() {
  const capability = generationFixture().generation.capability;
  const expected = {
    sourceCommit: capability.sourceCommit,
    session: capability.session,
    owner: capability.owner,
    phase: capability.phase,
    fixtureRoot: capability.fixtureRoot,
    hostIdentifier: `com.pulkit.edith.tests.worker-${capability.session}`,
    uid: capability.uid,
  };
  const value = {
    preferences: { name: { present: true, value: "Synthetic" } },
  };
  const policy = {
    schema: 1,
    owner: capability.owner,
    reads: [
      {
        name: "preferences",
        root: "owner-data",
        components: ["synthetic.json"],
        maximumBytes: 4096,
        format: "json",
        selections: [{ name: "name", path: ["name"], codec: "value" }],
      },
    ],
    sentinels: [],
    initial: value,
    final: value,
  };
  const bytes = Buffer.from(functionalCanonicalJSON(value));
  const digest = createHash("sha256").update(bytes).digest("hex");
  const file = {
    name: "preferences",
    path: `${capability.fixtureRoot}/Edith Tests/worker-${capability.session}/Data/${capability.owner}/synthetic.json`,
    present: true,
    bytes: bytes.length,
    sha256: digest,
    identity: {
      device: "1",
      inode: "2",
      uid: String(capability.uid),
      mode: "33152",
      links: "1",
      size: String(bytes.length),
      modifiedSeconds: "123",
      modifiedNanoseconds: "4",
      changedSeconds: "123",
      changedNanoseconds: "5",
    },
  };
  const observation = {
    reader: "independent-hosted-producer",
    observationID: "67890123-1234-4123-8123-123456789abc",
    sequence: 1,
    readbackSHA256: digest,
    expectedSHA256: digest,
  };
  const raw = {
    reader: "independent-hosted-producer",
    observationID: "78901234-1234-4123-8123-123456789abc",
    readbackSHA256: digest,
    files: [file],
  };
  const baselineClaim = {
    schema: 1,
    sourceCommit: capability.sourceCommit,
    session: capability.session,
    owner: capability.owner,
    phase: capability.phase,
    definitionSHA256: functionalDigest(policy),
    baseline: observation,
    raw,
    saved: bytes.toString("base64"),
  };
  const savedClaim = {
    schema: 1,
    sourceCommit: capability.sourceCommit,
    session: capability.session,
    owner: capability.owner,
    phase: capability.phase,
    definitionSHA256: functionalDigest(policy),
    capabilitySHA256: functionalDigest(capability),
    observation: {
      ...observation,
      observationID: "89012345-1234-4123-8123-123456789abc",
      sequence: 3,
    },
    raw: {
      ...structuredClone(raw),
      observationID: "90123456-1234-4123-8123-123456789abc",
    },
    beforeFirstRequest: {
      ...observation,
      capabilitySHA256: functionalDigest(capability),
      engine: capability.engine,
      ui: capability.ui,
      beforeRequestID: "01234567-1234-4123-8123-123456789abc",
    },
    saved: bytes.toString("base64"),
  };
  const { publicKey, privateKey } = generateKeyPairSync("ed25519");
  const seal = (claim) => {
    const payload = functionalCanonicalJSON(claim);
    return {
      schema: 1,
      payload,
      signature: sign(null, Buffer.from(payload), privateKey).toString(
        "base64",
      ),
    };
  };
  const issuerDER = publicKey.export({ format: "der", type: "spki" });
  const baseline = validateFunctionalPersistenceObservation({
    envelope: seal(baselineClaim),
    issuerDER,
    policy,
    expected,
  });
  const saved = validateFunctionalPersistenceObservation({
    envelope: seal(savedClaim),
    issuerDER,
    policy,
    expected,
    baseline,
    capability,
  });
  return {
    capability,
    expected,
    policy,
    bytes,
    issuerDER,
    seal,
    baselineClaim,
    savedClaim,
    baseline,
    saved,
  };
}

test("actual signed raw reader bytes bind compiled semantic policy and before-construction births", () => {
  const fixture = persistenceFixture();
  assert.deepEqual(fixture.baseline.bytes, fixture.bytes);
  assert.deepEqual(fixture.saved.bytes, fixture.bytes);
  for (const change of [
    (claim) => {
      claim.definitionSHA256 = "a".repeat(64);
    },
    (claim) => {
      claim.saved = Buffer.from('{"foreign":true}').toString("base64");
    },
    (claim) => {
      claim.raw.files[0].path += ".foreign";
    },
    (claim) => {
      claim.raw.files[0].identity.uid = "99";
    },
    (claim) => {
      claim.beforeFirstRequest.engine.pid++;
    },
    (claim) => {
      claim.beforeFirstRequest.sequence++;
    },
    (claim) => {
      claim.observation.sequence = 1;
    },
    (claim) => {
      claim.beforeFirstRequest = null;
    },
    (claim) => {
      claim.phase = "updated";
    },
    (claim) => {
      claim.controlPerformed = true;
    },
  ]) {
    const claim = structuredClone(fixture.savedClaim);
    change(claim);
    assert.throws(() =>
      validateFunctionalPersistenceObservation({
        ...fixture,
        envelope: fixture.seal(claim),
      }),
    );
  }
});

test("signed native drain requires exact original births, all joins, released leases and no signals", () => {
  const fixture = persistenceFixture();
  const claim = {
    schema: 1,
    sourceCommit: fixture.capability.sourceCommit,
    session: fixture.capability.session,
    owner: fixture.capability.owner,
    phase: fixture.capability.phase,
    capabilitySHA256: functionalDigest(fixture.capability),
    receipt: {
      births: [fixture.capability.engine, fixture.capability.ui],
      allTasksJoined: true,
      birthsAbsent: true,
      leasesReleased: true,
      signalsSent: 0,
    },
  };
  assert.deepEqual(
    validateFunctionalDrainObservation({
      ...fixture,
      envelope: fixture.seal(claim),
    }),
    claim,
  );
  for (const change of [
    (value) => {
      value.receipt.allTasksJoined = false;
    },
    (value) => {
      value.receipt.birthsAbsent = false;
    },
    (value) => {
      value.receipt.leasesReleased = false;
    },
    (value) => {
      value.receipt.signalsSent = 1;
    },
    (value) => {
      value.receipt.births[0].birthMicroseconds++;
    },
    (value) => {
      value.capabilitySHA256 = "c".repeat(64);
    },
  ]) {
    const altered = structuredClone(claim);
    change(altered);
    assert.throws(() =>
      validateFunctionalDrainObservation({
        ...fixture,
        envelope: fixture.seal(altered),
      }),
    );
  }
});

test("signed removal compares retained raw file fingerprints and actual saved bytes", () => {
  const fixture = persistenceFixture();
  const claim = {
    schema: 1,
    sourceCommit: fixture.expected.sourceCommit,
    session: fixture.expected.session,
    owner: fixture.expected.owner,
    receipt: {
      physicallyAbsentVersions: ["1.0.0", "1.1.0"],
      pendingRemoval: false,
      leasesReleased: true,
      sentinelBytesPreserved: true,
      semanticDataPreserved: true,
    },
    before: fixture.saved.claim.raw,
    after: {
      ...structuredClone(fixture.saved.claim.raw),
      observationID: "12345678-1234-4123-8123-123456789abc",
    },
  };
  assert.deepEqual(
    validateFunctionalRemovalObservation({
      ...fixture,
      envelope: fixture.seal(claim),
    }),
    claim,
  );
  for (const change of [
    (value) => {
      value.receipt.physicallyAbsentVersions = ["1.0.0"];
    },
    (value) => {
      value.receipt.pendingRemoval = true;
    },
    (value) => {
      value.receipt.sentinelBytesPreserved = false;
    },
    (value) => {
      value.receipt.semanticDataPreserved = false;
    },
    (value) => {
      value.after.files[0].sha256 = "c".repeat(64);
    },
    (value) => {
      value.before.observationID = value.after.observationID;
    },
  ]) {
    const altered = structuredClone(claim);
    change(altered);
    assert.throws(() =>
      validateFunctionalRemovalObservation({
        ...fixture,
        envelope: fixture.seal(altered),
      }),
    );
  }
});

test("raw persistence and retirement operations require actual private session and generation brands", async () => {
  for (const operation of [
    () =>
      captureFunctionalNativeBaseline({
        session: {},
        owner: "keepAwake",
        phase: "initial",
      }),
    () => readFunctionalNativeSaved({ session: {}, generation: {} }),
    () => drainFunctionalNativeGeneration({ session: {}, generation: {} }),
    () => removeFunctionalNativeOwner({}, "keepAwake", "initial"),
  ])
    await assert.rejects(operation(), /Expected owned live native session/);
});

test("full run source admission rejects missing native seals and unavailable operation bodies", () => {
  const source = functionalRunRequiredNativeOperations
    .map(
      (operation) =>
        `case "${operation}":\n try FunctionalBytes.exact(command, ["operation"])\n try emit(["operation": operation])`,
    )
    .join("\n");
  assert.deepEqual(
    validateFunctionalRunNativeSourceOperations(Buffer.from(source)),
    functionalRunRequiredNativeOperations,
  );
  for (const changed of [
    source.replace('case "seal-owner-proof":', 'case "foreign":'),
    source.replace('case "seal-qualified-evidence":', 'case "foreign":'),
    `${source}\ncase "finish": try emit([:])`,
    source.replace(
      'case "finish":',
      'case "finish": throw FunctionalFailure.unavailable("stub")',
    ),
    source.replace(
      'case "finish":\n try FunctionalBytes.exact(command, ["operation"])',
      'case "finish":',
    ),
  ])
    assert.throws(() =>
      validateFunctionalRunNativeSourceOperations(Buffer.from(changed)),
    );
});

test("the actual full owner adapter rejects public metadata instead of accepting injected authority", async () => {
  await assert.rejects(
    createFunctionalNativeOwnerAdapter({
      session: {},
      ownerPlan: {},
      environment: {},
    }),
    /Expected owned live native session/,
  );
});

test("full hosted entry refuses forged environment before compilation, signatures or native execution", async () => {
  await assert.rejects(
    runHostedFunctionalActions({
      repository: "/synthetic/missing",
      sourceCommit,
      environment: {},
    }),
  );
});

function qualifiedSealFixture(change = () => {}) {
  const { publicKey, privateKey } = generateKeyPairSync("ed25519");
  const issuerDER = publicKey.export({ format: "der", type: "spki" });
  const issuerPublicKey = issuerDER.subarray(-32).toString("base64");
  const sealEnvelope = (claim) => {
    const payload = functionalCanonicalJSON(claim);
    return {
      schema: 1,
      payload,
      signature: sign(null, Buffer.from(payload), privateKey).toString(
        "base64",
      ),
    };
  };
  const { capability } = generationFixture().generation;
  const sourcePins = {
    sourceCommit,
    files: [{ path: "synthetic/source.swift", sha256: "c".repeat(64) }],
  };
  const expected = {
    sourceCommit,
    mergeCommit: "5".repeat(40),
    baseCommit: "6".repeat(40),
    session: capability.session,
    sourceSHA256: functionalDigest(sourcePins),
    toolchainSHA256: "b".repeat(64),
    policySHA256: "c".repeat(64),
    runID: 101,
    jobID: 202,
    runAttempt: 1,
    workflowSHA256: "d".repeat(64),
  };
  const producer = {
    pid: 55,
    birthSeconds: 100,
    birthMicroseconds: 1,
    uid: capability.uid,
    executable: `${capability.fixtureRoot}/Producer/functional-producer`,
    executableSHA256: "e".repeat(64),
  };
  const host = {
    ...producer,
    pid: 56,
    birthMicroseconds: 2,
    executable: `${capability.fixtureRoot}/Fixture.app/Contents/MacOS/Edith`,
    executableSHA256: "f".repeat(64),
  };
  const certificate = Buffer.alloc(32, 8).toString("base64");
  const issuerManifest = {
    schema: 2,
    sourceCommit,
    runID: 101,
    jobID: 202,
    session: expected.session,
    root: capability.fixtureRoot,
    hostIdentifier: `com.pulkit.edith.tests.worker-${expected.session}`,
    issuerPublicKey,
    policySHA256: expected.policySHA256,
    producer: {
      path: producer.executable,
      executableSHA256: producer.executableSHA256,
      certificateSHA256: certificate,
      requirement: "identifier synthetic.producer",
      sourceSHA256: expected.sourceSHA256,
      toolchainSHA256: expected.toolchainSHA256,
    },
    signing: {
      hostRequirement: "identifier synthetic.host",
      hostCertificateSHA256: certificate,
      workerCertificateSHA256: certificate,
      roleCertificateSHA256: certificate,
    },
  };
  const hostArtifact = {
    schema: 2,
    sourceCommit,
    session: expected.session,
    root: capability.fixtureRoot,
    hostIdentifier: issuerManifest.hostIdentifier,
    issuerPublicKey,
    issuerManifestSHA256: functionalDigest(issuerManifest),
    host: {
      path: `${capability.fixtureRoot}/Fixture.app`,
      executableSHA256: host.executableSHA256,
      certificateSHA256: certificate,
      requirement: issuerManifest.signing.hostRequirement,
    },
    producer: {
      path: producer.executable,
      executableSHA256: producer.executableSHA256,
    },
    workerCertificateSHA256: certificate,
    roleCertificateSHA256: certificate,
  };
  const ownerProofs = functionalActionOwners.map((owner) => {
    const metadata = {
      schema: 1,
      sourceCommit,
      session: expected.session,
      owner,
      caseSHA256: "a".repeat(64),
    };
    return {
      claim: sealEnvelope({ ...metadata, stages: [] }),
      observation: sealEnvelope({ ...metadata, stages: [] }),
    };
  });
  const payload = {
    schema: 1,
    kind: "qualified-evidence",
    ...expected,
    root: capability.fixtureRoot,
    hostIdentifier: issuerManifest.hostIdentifier,
    issuerPublicKey,
    issuerManifestSHA256: functionalDigest(issuerManifest),
    artifactSHA256: functionalDigest(hostArtifact),
    producer,
    host,
    owners: functionalActionOwners.map((owner, index) => ({
      owner,
      caseSHA256: "a".repeat(64),
      claimSHA256: functionalDigest(ownerProofs[index].claim),
      observationSHA256: functionalDigest(ownerProofs[index].observation),
    })),
    retirement: { hostAbsent: true, receiverJoined: true, signalsSent: 0 },
  };
  change({ payload, issuerManifest, hostArtifact, ownerProofs, expected });
  return {
    envelope: sealEnvelope(payload),
    issuerDER,
    issuerManifest,
    hostArtifact,
    ownerProofs,
    expected,
    sourcePins,
  };
}

test("closed signed aggregate binds genuine envelope bytes and complete canonical owner metadata", () => {
  const fixture = qualifiedSealFixture();
  const payload = validateFunctionalQualifiedSeal(fixture);
  assert.equal(payload.owners.length, 39);
  assert.throws(() =>
    validateFunctionalQualifiedSeal({
      ...fixture,
      issuerDER: qualifiedSealFixture().issuerDER,
    }),
  );
});

test("final aggregate rejects narrowed source jobs, altered envelopes and incomplete retirement", () => {
  for (const change of [
    ({ payload }) => {
      payload.mergeCommit = "7".repeat(40);
    },
    ({ payload }) => {
      payload.baseCommit = "7".repeat(40);
    },
    ({ expected, payload }) => {
      expected.mergeCommit = payload.mergeCommit = "7".repeat(39);
    },
    ({ payload }) => {
      payload.runAttempt++;
    },
    ({ payload }) => {
      payload.workflowSHA256 = "f".repeat(64);
    },
    ({ payload }) => {
      payload.sourceSHA256 = "f".repeat(64);
    },
    ({ payload }) => {
      payload.owners.pop();
    },
    ({ payload }) => {
      payload.owners.reverse();
    },
    ({ payload }) => {
      payload.owners[0].claimSHA256 = "f".repeat(64);
    },
    ({ payload }) => {
      payload.retirement.receiverJoined = false;
    },
    ({ payload }) => {
      payload.retirement.signalsSent = 1;
    },
    ({ payload }) => {
      payload.retirement.producerAbsent = true;
    },
    ({ ownerProofs }) => {
      ownerProofs[0] = ownerProofs[1];
    },
    ({ issuerManifest }) => {
      issuerManifest.producer.sourceSHA256 = "f".repeat(64);
    },
    ({ hostArtifact }) => {
      hostArtifact.host.executableSHA256 = "e".repeat(64);
    },
  ])
    assert.throws(() =>
      validateFunctionalQualifiedSeal(qualifiedSealFixture(change)),
    );
});

test("a signed inventory with39 metadata records cannot qualify missing actual native action stages", async () => {
  const fixture = qualifiedSealFixture();
  const artifact = {
    schema: 1,
    issuerManifest: fixture.issuerManifest,
    hostArtifact: fixture.hostArtifact,
    evidence: fixture.envelope,
    ownerProofs: fixture.ownerProofs,
    ownedExits: [],
    presentations: [],
    rolePolicies: [],
    observerHelper: {
      executable: "/synthetic/helper",
      executableSHA256: "e".repeat(64),
    },
  };
  await assert.rejects(
    verifyQualifiedFunctionalEvidence({
      artifact,
      plan: {
        sourceCommit,
        owners: functionalActionOwners.map((owner) => ({
          owner,
          definition: { owner },
        })),
      },
      sourcePins: fixture.sourcePins,
      expected: fixture.expected,
      admittedAuthority: {
        issuerPublicKey: fixture.issuerManifest.issuerPublicKey,
        issuerManifestSHA256: functionalDigest(fixture.issuerManifest),
        artifactSHA256: functionalDigest(fixture.hostArtifact),
        observerHelperSHA256: artifact.observerHelper.executableSHA256,
      },
    }),
  );
});

test("mandatory presentation bindings retain three distinct genuine captured generation identifiers", () => {
  const { generation, definition } = generationFixture();
  const generations = ["initial", "updated", "reinstalled"].map(
    (phase, index) => ({
      ...structuredClone(generation),
      capability: { ...structuredClone(generation.capability), phase },
      presentationID: `${index + 1}2345678-1234-4123-8123-123456789abc`,
    }),
  );
  const input = {
    sourceCommit: generation.capability.sourceCommit,
    session: generation.capability.session,
    owner: definition.owner,
    definition,
    generations,
  };
  assert.equal(
    Object.keys(functionalAdmittedPresentations(input).presentations).length,
    3,
  );
  for (const change of [
    (values) => {
      values.pop();
    },
    (values) => {
      values[1].presentationID = values[0].presentationID;
    },
    (values) => {
      values[1].capability.sourceCommit = "b".repeat(40);
    },
    (values) => {
      values[1].capability.owner = "foreign";
    },
  ]) {
    const altered = structuredClone(generations);
    change(altered);
    assert.throws(() =>
      functionalAdmittedPresentations({ ...input, generations: altered }),
    );
  }
});

test("qualified artifact authority requires independently admitted exact issuer Host and observer pins", () => {
  const fixture = qualifiedSealFixture();
  const artifact = {
    ...fixture,
    observerHelper: { executableSHA256: "e".repeat(64) },
  };
  const admittedAuthority = {
    issuerPublicKey: fixture.issuerManifest.issuerPublicKey,
    issuerManifestSHA256: functionalDigest(fixture.issuerManifest),
    artifactSHA256: functionalDigest(fixture.hostArtifact),
    observerHelperSHA256: "e".repeat(64),
  };
  assert.equal(
    validateFunctionalQualifiedAuthority({ artifact, admittedAuthority }),
    true,
  );
  assert.throws(() => validateFunctionalQualifiedAuthority({ artifact }));
  for (const field of Object.keys(admittedAuthority)) {
    const altered = {
      ...admittedAuthority,
      [field]:
        field === "issuerPublicKey"
          ? Buffer.alloc(32, 7).toString("base64")
          : "f".repeat(64),
    };
    assert.throws(() =>
      validateFunctionalQualifiedAuthority({
        artifact,
        admittedAuthority: altered,
      }),
    );
  }
  assert.throws(() =>
    validateFunctionalQualifiedAuthority({
      artifact,
      admittedAuthority: { ...admittedAuthority, sourceReady: true },
    }),
  );
});

test("a signed actor completion cannot substitute the original qualified UI presentation observation", async () => {
  const fixture = xctestGenerationFixture();
  await assert.rejects(
    validateFunctionalNativePresentationObservation({
      envelope: fixture.observations.steps[0].completion,
      issuerDER: fixture.issuerDER,
      generation: generationFixture().generation,
      recipe: {},
      definition: keepAwakeDefinition,
    }),
  );
});

async function originalPresentationFixture(change = () => {}) {
  const { installedPresentationID, installedPresentationWindowTitle } =
    await import("./presentation.mjs");
  const { privateKey, publicKey } = generateKeyPairSync("ed25519");
  const { generation, definition } = generationFixture();
  const capability = generation.capability;
  generation.presentationID = installedPresentationID(capability);
  const recipe = {
    schema: 1,
    owner: definition.owner,
    location: "settings",
    section: definition.owner,
    operation: definition.activation.operation,
    steps: [
      {
        role: "checkBox",
        label: "Synthetic control",
        action: "set-checkbox",
        value: true,
      },
    ],
    sources: [
      {
        path: `Extensions/${definition.owner}/Synthetic.swift`,
        sha256: "a".repeat(64),
      },
    ],
  };
  const inventory = {
    sourceCommit: capability.sourceCommit,
    sourceClean: true,
    heldRootPinned: true,
    heldDescriptorPinned: true,
    hostSignatureVerified: true,
    workerSignatureVerified: true,
    roleSignatureVerified: true,
    rolePayloadUnchanged: true,
    factoryOverlay: false,
    originalFactoriesUnchanged: true,
    originalControlsUnchanged: true,
    hostABI: capability.hostABI,
    version: capability.version,
    packageSHA256: capability.packageSHA256,
    bundleTreeSHA256: "b".repeat(64),
    engine: capability.engine,
    ui: capability.ui,
    presentationID: generation.presentationID,
  };
  const claim = {
    schema: 1,
    authority: "independent-hosted-producer",
    execution: "hosted-macos-native",
    capabilitySHA256: functionalDigest(capability),
    recipeSHA256: functionalDigest(recipe),
    presentationID: generation.presentationID,
    windowTitle: installedPresentationWindowTitle(capability),
    before: structuredClone(inventory),
    after: structuredClone(inventory),
    steps: structuredClone(recipe.steps),
    stepInventories: [
      {
        index: 0,
        before: structuredClone(inventory),
        after: structuredClone(inventory),
      },
    ],
    mutation: {
      origin: "authenticated-downloaded-ui-engine-receiver",
      operation: recipe.operation,
      presentationID: generation.presentationID,
      ui: capability.ui,
      engine: capability.engine,
      requestID: "34567890-1234-4123-8123-123456789abc",
      payloadSHA256: "c".repeat(64),
      responseSHA256: "d".repeat(64),
      success: true,
      beforeAuthoritativeRead: true,
    },
    authoritative: {
      reader: "independent-hosted-producer",
      kind: definition.observation.kind,
      name: definition.observation.name,
      observationID: "45678901-1234-4123-8123-123456789abc",
      engine: capability.engine,
      observedSHA256: "e".repeat(64),
      expectedSHA256: "e".repeat(64),
    },
    presentationClosed: true,
    leasesReleased: true,
  };
  change({ claim, recipe, generation });
  const seal = (claim) => {
    const payload = functionalCanonicalJSON(claim);
    return {
      schema: 1,
      payload,
      signature: sign(null, Buffer.from(payload), privateKey).toString(
        "base64",
      ),
    };
  };
  return {
    envelope: seal(claim),
    seal,
    issuerDER: publicKey.export({ format: "der", type: "spki" }),
    generation,
    recipe,
    definition,
  };
}

test("original UI seal validator consumes complete signed per-step inventories and immutable generation", async () => {
  const result = await validateFunctionalNativePresentationObservation(
    await originalPresentationFixture(),
  );
  assert.equal(result.result.downloadedUIBinaryActionsValidated, true);
  for (const change of [
    ({ claim }) => {
      delete claim.stepInventories;
    },
    ({ claim }) => {
      claim.stepInventories = [];
    },
    ({ claim }) => {
      claim.stepInventories[0].after.rolePayloadUnchanged = false;
    },
    ({ claim }) => {
      claim.after.bundleTreeSHA256 = "f".repeat(64);
    },
    ({ claim }) => {
      claim.authoritative.expectedSHA256 = "f".repeat(64);
    },
    ({ claim }) => {
      claim.presentationClosed = false;
    },
    ({ claim }) => {
      claim.leasesReleased = false;
    },
    ({ claim }) => {
      claim.mutation.beforeAuthoritativeRead = false;
    },
    ({ generation }) => {
      generation.presentationID = "56789012-1234-4123-8123-123456789abc";
    },
  ])
    await assert.rejects(
      validateFunctionalNativePresentationObservation(
        await originalPresentationFixture(change),
      ),
    );
});

async function drainLifetimeFixture(pauseAt) {
  const fixture = await originalPresentationFixture();
  const { generation, recipe, definition, issuerDER } = fixture;
  Object.freeze(generation);
  const capability = generation.capability;
  const drainClaim = {
    schema: 1,
    sourceCommit: capability.sourceCommit,
    session: capability.session,
    owner: capability.owner,
    phase: capability.phase,
    capabilitySHA256: functionalDigest(capability),
    receipt: {
      births: [capability.engine, capability.ui],
      allTasksJoined: true,
      birthsAbsent: true,
      leasesReleased: true,
      signalsSent: 0,
    },
  };
  const drainEnvelope = fixture.seal(drainClaim);
  let resume,
    paused,
    currentness = 0,
    presentationValidated = false;
  const waiting = new Promise((resolve) => {
    paused = resolve;
  });
  const released = new Promise((resolve) => {
    resume = resolve;
  });
  const requests = [];
  const boundary = async (name) => {
    await Promise.resolve();
    if (pauseAt === name) {
      paused();
      await released;
    }
  };
  const session = Object.freeze({
    sourceCommit: capability.sourceCommit,
    issuerDER,
  });
  const transcript = Object.freeze({ generation });
  const transcripts = [transcript];
  const state = {
    status: "live",
    compilation: Object.freeze({ kind: "isolated-memory-compilation" }),
    builder: {
      async functionalCompilationForBuilder(compilation) {
        assert.equal(compilation, state.compilation);
        await boundary(`currentness-${++currentness}`);
      },
    },
    observeOwnedProducer() {
      assert.equal(state.status, "live");
    },
    observeOwnedHost() {
      assert.equal(state.status, "live");
    },
    authority: {
      functionalFixtureTrustSource() {
        assert.equal(state.status, "live");
      },
    },
    savedObservations: new Map([
      [`${capability.owner}:${capability.phase}`, {}],
    ]),
    ownerPresentations: new Map([[capability.owner, transcripts]]),
    plan: { session: capability.session },
    channel: {
      async request(operation, fields) {
        requests.push(operation);
        await boundary(operation);
        if (operation === "host-command") {
          assert.equal(fields.command, "drain");
          return {
            response: {
              schema: 1,
              sourceCommit: capability.sourceCommit,
              session: capability.session,
              owner: capability.owner,
              operation: "drain",
            },
          };
        }
        if (operation === "collect-drain")
          return {
            requestID: "synthetic-drain",
            operation,
            receipt: drainEnvelope,
          };
        if (operation === "seal-presentation-proof")
          return {
            requestID: "synthetic-presentation",
            operation,
            observation: fixture.envelope,
          };
        assert.equal(operation, "retired");
        return {
          requestID: "synthetic-retirement",
          operation,
          ownedBirthsAbsent: true,
        };
      },
    },
  };
  const held = {
    session,
    digest: functionalDigest(generation),
    ownerPlan: { recipe, definition },
  };
  const source = await readFile(
    new URL("./run-functional.mjs", import.meta.url),
    "utf8",
  );
  const currentnessSource = source.slice(
    source.indexOf("async function requireFunctionalNativeSession("),
    source.indexOf("export async function cancelFunctionalNativeSession("),
  );
  const drainSource = source.slice(
    source.indexOf("export async function drainFunctionalNativeGeneration("),
    source.indexOf("export function validateFunctionalRemovalObservation("),
  );
  const probe = `${currentnessSource}\n${drainSource}`.replace(
    /^export /gm,
    "",
  );
  return {
    generation,
    requests,
    waiting,
    resume,
    transcripts,
    transcript,
    drainClaim,
    presentationValidated: () => presentationValidated,
    run() {
      return runInNewContext(
        `const nativeSessions = new WeakMap([[session, state]]);
         const nativeGenerations = new WeakMap([[generation, held]]);
         ${probe}
         drainFunctionalNativeGeneration({session, generation});`,
        {
          assert,
          functionalDigest,
          functionalActionOwners,
          session,
          state,
          generation,
          held,
          exactFunctionalFields(value, fields) {
            assert.deepEqual(Object.keys(value).sort(), [...fields].sort());
          },
          validateFunctionalDrainObservation,
          async validateFunctionalNativePresentationObservation(options) {
            const result =
              await validateFunctionalNativePresentationObservation(options);
            presentationValidated = true;
            await boundary("presentation-validation");
            return result;
          },
        },
      );
    },
  };
}

test("isolated actual drain source rejects nested mutation at every awaited lifetime boundary", async () => {
  const unchanged = await drainLifetimeFixture();
  const result = await unchanged.run();
  assert.deepEqual(result.claim, unchanged.drainClaim);
  assert.deepEqual(unchanged.requests, [
    "host-command",
    "collect-drain",
    "seal-presentation-proof",
    "retired",
  ]);
  assert.equal(unchanged.presentationValidated(), true);
  assert(Object.hasOwn(unchanged.transcripts[0], "presentationObservation"));
  for (const [pauseAt, requests] of [
    ["host-command", ["host-command"]],
    ["currentness-3", ["host-command"]],
    ["collect-drain", ["host-command", "collect-drain"]],
    ["currentness-4", ["host-command", "collect-drain"]],
    [
      "seal-presentation-proof",
      ["host-command", "collect-drain", "seal-presentation-proof"],
    ],
    [
      "presentation-validation",
      ["host-command", "collect-drain", "seal-presentation-proof"],
    ],
    [
      "currentness-5",
      ["host-command", "collect-drain", "seal-presentation-proof"],
    ],
    [
      "retired",
      ["host-command", "collect-drain", "seal-presentation-proof", "retired"],
    ],
    [
      "currentness-6",
      ["host-command", "collect-drain", "seal-presentation-proof", "retired"],
    ],
  ]) {
    const fixture = await drainLifetimeFixture(pauseAt);
    const rejected = assert.rejects(fixture.run(), { code: "ERR_ASSERTION" });
    await fixture.waiting;
    if (pauseAt === "currentness-5") {
      assert.equal(fixture.presentationValidated(), true);
      assert.equal(fixture.transcripts[0], fixture.transcript);
      assert.equal(fixture.requests.includes("retired"), false);
    }
    assert(Object.isFrozen(fixture.generation));
    fixture.generation.capability.engine.birthMicroseconds++;
    fixture.resume();
    await rejected;
    assert.deepEqual(fixture.requests, requests, pauseAt);
    if (!requests.includes("retired"))
      assert.equal(fixture.transcripts[0], fixture.transcript, pauseAt);
  }
});
