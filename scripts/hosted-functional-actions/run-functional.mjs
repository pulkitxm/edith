import assert from "node:assert/strict";
import { createHash, randomUUID, verify } from "node:crypto";
import { mkdir, readFile, realpath, writeFile } from "node:fs/promises";
import { join } from "node:path";
import {
  functionalCanonicalJSON,
  functionalDigest,
  validateFunctionalActionProof,
  validateFunctionalCapability,
  verifyFunctionalEnvelope,
} from "./contract.mjs";
import {
  validateFunctionalProcessAbsence,
  validateFunctionalProcessBirth,
} from "./owned-process.mjs";
import { functionalActionOwners } from "./owners.mjs";

const phases = Object.freeze([
  Object.freeze({ phase: "initial", version: "1.0.0" }),
  Object.freeze({ phase: "updated", version: "1.1.0" }),
  Object.freeze({ phase: "reinstalled", version: "1.1.0" }),
]);

export async function executeFunctionalOwners({
  plan,
  requireCurrent,
  runOwner,
  cancelAndJoin,
  signal,
}) {
  for (const [name, method] of Object.entries({
    requireCurrent,
    runOwner,
    cancelAndJoin,
  }))
    assert.equal(
      typeof method,
      "function",
      `Missing execution boundary ${name}`,
    );
  const results = [];
  try {
    assert.match(plan.sourceCommit, /^[0-9a-f]{40}$/);
    assert.equal(plan.concurrency, 1);
    assert.equal(plan.pairScope, "synthetic-development");
    assert.deepEqual(
      plan.owners.map(({ owner }) => owner),
      functionalActionOwners,
    );
    for (const owner of plan.owners) {
      assert.equal(owner.definition.owner, owner.owner);
      assert.deepEqual(owner.phases, phases);
    }
    const digest = functionalDigest(plan);
    const current = async () => {
      signal?.throwIfAborted();
      assert.equal(functionalDigest(plan), digest, "Execution plan changed");
      await requireCurrent();
      signal?.throwIfAborted();
      assert.equal(functionalDigest(plan), digest, "Execution plan changed");
    };
    await current();
    for (const owner of plan.owners) {
      await current();
      const result = await runOwner(owner, signal);
      await current();
      assert.equal(result.owner, owner.owner);
      assert.equal(result.sourceCommit, plan.sourceCommit);
      results.push(result);
    }
    await current();
    assert.equal(results.length, functionalActionOwners.length);
    return Object.freeze(results);
  } catch (error) {
    try {
      await cancelAndJoin();
    } catch (cleanup) {
      throw new AggregateError(
        [error, cleanup],
        "Functional execution failed with incomplete owned cleanup",
      );
    }
    throw error;
  }
}

const nativeSessions = new WeakMap();
const nativeGenerations = new WeakMap();

export async function joinFunctionalOwnedProcesses(processes) {
  assert(Array.isArray(processes));
  assert.equal(new Set(processes).size, processes.length);
  let timer;
  try {
    await Promise.race([
      Promise.allSettled(
        processes.map(async (owned) => {
          assert.equal(typeof owned.joined?.then, "function");
          await owned.joined;
          assert.equal(
            owned.child.signalCode,
            null,
            "Owned child received a signal",
          );
          assert(
            Number.isInteger(owned.child.exitCode),
            "Owned child did not exit",
          );
        }),
      ).then((outcomes) => {
        const failures = outcomes
          .filter((outcome) => outcome.status === "rejected")
          .map((outcome) => outcome.reason);
        if (failures.length)
          throw new AggregateError(
            failures,
            "Owned process cleanup was incomplete",
          );
      }),
      new Promise((_, reject) => {
        timer = setTimeout(
          () => reject(new Error("Owned natural process join deadline")),
          30000,
        );
      }),
    ]);
  } finally {
    clearTimeout(timer);
  }
}

export async function startFunctionalNativeSession({
  repository,
  plan,
  compilation,
  policyBytes,
  admittedPolicies,
  environment,
}) {
  const controller = await import("./controller.mjs");
  const builder = await import("./functional-build.mjs");
  const producer = await import("./producer-project.mjs");
  const authority = await import("./fixture-trust.mjs");
  environment = Object.freeze({ ...environment });
  const compiled = await builder.functionalCompilationForBuilder(compilation);
  assert.equal(compiled.sourceCommit, plan.sourceCommit);
  assert.equal(compiled.root, plan.root);
  const ownedProcesses = [];
  let channel;
  let bootstrapped = false;
  let producerComplete = false;
  let compilationClosed = false;
  const cancelAndJoin = createFunctionalOwnedCleanup({
    cancelProducer: async () => {
      if (channel && bootstrapped && !producerComplete) {
        await controller.cancelFunctionalProducer(channel);
        producerComplete = true;
      }
    },
    joinProcesses: () => joinFunctionalOwnedProcesses(ownedProcesses),
    closeCompilation: async () => {
      if (!compilationClosed) {
        await builder.closeFunctionalCompilation(compilation);
        compilationClosed = true;
      }
    },
  });
  try {
    const receipt = await producer.buildFunctionalProducer({
      repository,
      plan,
      compilation,
      environment,
    });
    channel = await controller.launchFunctionalProducer(receipt, environment);
    bootstrapped = true;
    ownedProcesses.push(controller.functionalProducerOwnedProcess(channel));
    const activeJob = await controller.observeFunctionalActiveJob({
      repository,
      sourceCommit: plan.sourceCommit,
      environment,
    });
    const {
      issuerManifestBytes: manifestBytes,
      admittedIssuer,
      issuerDER,
    } = await controller.admitFunctionalProducerAuthority({
      receipt,
      plan,
      channel,
      activeJob,
      environment,
    });
    const observeOwnedProducer = () =>
      controller.observeFunctionalProducer(channel);
    const hostReceipt = await builder.buildFunctionalFixtureHost({
      compilation,
      plan,
      issuerManifestBytes: manifestBytes,
      admittedIssuer,
      policyBytes,
      admittedPolicies,
    });
    const ownedHost = await compiled.observer.spawn(
      hostReceipt.hostSpecification,
      [],
      { cwd: plan.root, env: environment },
    );
    ownedProcesses.push(ownedHost);
    ownedHost.child.stdout.resume();
    ownedHost.child.stderr.resume();
    const observedHost = await builder.bindFunctionalCompilationHost({
      compilation,
      receipt: hostReceipt,
      ownedHost,
    });
    const registration = await channel.request("host-registration", {
      artifact: JSON.parse(hostReceipt.artifactBytes.toString("utf8")),
      hostPID: ownedHost.child.pid,
    });
    assert.deepEqual(registration.host, observedHost);
    const observeOwnedHost = builder.observeFunctionalCompilationHost({
      compilation,
      receipt: hostReceipt,
      ownedHost,
    });
    const admittedArtifact = authority.admitFunctionalFixtureHost(
      hostReceipt.artifactBytes,
      admittedIssuer,
      {
        sourceCommit: hostReceipt.sourceCommit,
        runID: hostReceipt.runID,
        jobID: hostReceipt.jobID,
        source: hostReceipt.source,
        toolchain: hostReceipt.toolchain,
        bootstrapSHA256: hostReceipt.bootstrapSHA256,
        host: hostReceipt.host,
        hostProcess: observeOwnedHost().hostProcess,
      },
      observeOwnedHost,
    );
    const session = Object.freeze({
      sourceCommit: plan.sourceCommit,
      issuerManifestBytes: manifestBytes,
      admittedIssuer,
      issuerDER,
      artifactBytes: hostReceipt.artifactBytes,
      admittedArtifact,
    });
    nativeSessions.set(session, {
      repository,
      plan,
      compilation,
      compiled,
      receipt,
      channel,
      ownedProcesses,
      observeOwnedProducer,
      observeOwnedHost,
      policyBytes,
      admittedPolicies,
      authority,
      builder,
      controller,
      cancelAndJoin,
      markProducerComplete: () => {
        producerComplete = true;
      },
      markCompilationClosed: () => {
        compilationClosed = true;
      },
      ownerCatalogs: new Map(),
      savedBaselines: new Map(),
      savedObservations: new Map(),
      ownerProofs: new Map(),
      ownerPresentations: new Map(),
      status: "live",
    });
    await requireFunctionalNativeSession(session);
    return session;
  } catch (error) {
    try {
      await cancelAndJoin();
    } catch (cleanup) {
      const failure = new AggregateError(
        [error, cleanup],
        "Native session startup failed with incomplete owned cleanup",
      );
      Object.defineProperty(failure, "retryOwnedCleanup", {
        value: cancelAndJoin,
      });
      throw failure;
    }
    throw error;
  }
}

async function requireFunctionalNativeSession(session) {
  const state = nativeSessions.get(session);
  assert(
    state && state.status === "live",
    "Expected owned live native session",
  );
  await state.builder.functionalCompilationForBuilder(state.compilation);
  state.observeOwnedProducer();
  state.observeOwnedHost();
  state.authority.functionalFixtureTrustSource(
    session.artifactBytes,
    session.admittedArtifact,
    state.policyBytes,
    state.admittedPolicies,
  );
  return state;
}

async function requestFunctionalHostReply(session, owner, command, fields) {
  const state = await requireFunctionalNativeSession(session);
  assert(functionalActionOwners.includes(owner));
  assert(
    [
      "create-session",
      "select-catalog",
      "install",
      "open-original",
      "drain",
      "remove",
      "retire-session",
    ].includes(command),
  );
  const reply = await state.channel.request("host-command", {
    owner,
    command,
    fields,
  });
  assert.equal(reply.response.schema, 1);
  assert.equal(reply.response.sourceCommit, session.sourceCommit);
  assert.equal(reply.response.session, state.plan.session);
  assert.equal(reply.response.owner, owner);
  assert.equal(reply.response.operation, command);
  await requireFunctionalNativeSession(session);
  return reply;
}

export async function requestFunctionalHost(session, owner, command, fields) {
  return (await requestFunctionalHostReply(session, owner, command, fields))
    .response;
}

export async function cancelFunctionalNativeSession(session) {
  const state = nativeSessions.get(session);
  assert(state, "Expected owned native session");
  if (state.status === "closed") return;
  state.status = "closing";
  await state.cancelAndJoin();
  state.status = "closed";
}

export async function finishFunctionalNativeSession(session) {
  const state = nativeSessions.get(session);
  assert(
    state && state.status === "live",
    "Expected owned live native session",
  );
  assert(state.finalEvidence, "Missing actual collected final issuer seal");
  await state.builder.functionalCompilationForBuilder(state.compilation);
  state.observeOwnedProducer();
  state.status = "closing";
  await state.controller.finishFunctionalProducer(state.channel);
  state.markProducerComplete();
  await joinFunctionalOwnedProcesses(state.ownedProcesses);
  for (const owned of state.ownedProcesses)
    assert.equal(owned.child.exitCode, 0);
  const exits = [];
  for (const owned of state.ownedProcesses)
    exits.push(await state.compiled.observer.observeNaturalExit(owned));
  await state.builder.closeFunctionalCompilation(state.compilation);
  state.markCompilationClosed();
  state.status = "closed";
  return Object.freeze(exits);
}

export function validateFunctionalSignedCatalog(
  bytes,
  issuerDER,
  owner,
  version,
) {
  assert(functionalActionOwners.includes(owner));
  assert(["1.0.0", "1.1.0"].includes(version));
  assert(Buffer.isBuffer(bytes) && bytes.length > 0 && bytes.length <= 1048576);
  const text = new TextDecoder("utf-8", { fatal: true }).decode(bytes);
  const envelope = JSON.parse(text);
  assert.equal(functionalCanonicalJSON(envelope), text);
  assert.deepEqual(Object.keys(envelope).sort(), ["payload", "signature"]);
  const decode = (value, maximum) => {
    assert.equal(typeof value, "string");
    const result = Buffer.from(value, "base64");
    assert(result.length > 0 && result.length <= maximum);
    assert.equal(result.toString("base64"), value);
    return result;
  };
  const payload = decode(envelope.payload, 1048576);
  const signature = decode(envelope.signature, 64);
  assert.equal(signature.length, 64);
  assert(
    verify(
      null,
      payload,
      { key: issuerDER, format: "der", type: "spki" },
      signature,
    ),
    "Catalog signer differs from live issuer",
  );
  const payloadText = new TextDecoder("utf-8", { fatal: true }).decode(payload);
  const catalog = JSON.parse(payloadText);
  assert.equal(functionalCanonicalJSON(catalog), payloadText);
  assert.deepEqual(Object.keys(catalog).sort(), [
    "packages",
    "revision",
    "schemaVersion",
  ]);
  assert.equal(catalog.schemaVersion, 1);
  assert.equal(catalog.revision, version === "1.0.0" ? 1 : 2);
  assert(Array.isArray(catalog.packages) && catalog.packages.length === 1);
  const [entry] = catalog.packages;
  assert.equal(entry.id, owner);
  assert.equal(entry.version, version);
  assert.equal(entry.hostABI, "edith-host-2");
  assert.equal(entry.architecture, "arm64");
  assert.deepEqual(entry.dependencies, []);
  return catalog;
}

export async function installFunctionalNativeOwnerVersion(
  session,
  owner,
  version,
) {
  const state = await requireFunctionalNativeSession(session);
  assert(functionalActionOwners.includes(owner));
  assert(["1.0.0", "1.1.0"].includes(version));
  let catalogs = state.ownerCatalogs.get(owner);
  if (!catalogs) {
    assert.equal(
      version,
      "1.0.0",
      "Owner must begin with original installed version",
    );
    catalogs = new Map();
    for (const selected of ["1.0.0", "1.1.0"]) {
      await requireFunctionalNativeSession(session);
      const response = await state.channel.request("seal-catalog", {
        owner,
        version: selected,
      });
      assert.deepEqual(Object.keys(response).sort(), [
        "catalog",
        "operation",
        "requestID",
      ]);
      assert.equal(typeof response.catalog, "string");
      const bytes = Buffer.from(response.catalog, "base64");
      assert.equal(bytes.toString("base64"), response.catalog);
      validateFunctionalSignedCatalog(
        bytes,
        session.issuerDER,
        owner,
        selected,
      );
      await requireFunctionalNativeSession(session);
      catalogs.set(selected, response.catalog);
    }
    await requestFunctionalHost(session, owner, "create-session", {
      catalogs: [...catalogs.values()],
    });
    state.ownerCatalogs.set(owner, catalogs);
  }
  await requestFunctionalHost(session, owner, "select-catalog", {
    catalog: catalogs.get(version),
  });
  return requestFunctionalHost(session, owner, "install", { version });
}

export async function retireFunctionalNativeOwner(session, owner) {
  const state = await requireFunctionalNativeSession(session);
  assert(
    state.ownerCatalogs.has(owner),
    "Owner has no source-built installed pair",
  );
  await requestFunctionalHost(session, owner, "retire-session", {});
  state.ownerCatalogs.delete(owner);
}

export function decodeFunctionalCanonicalStorage(bytes) {
  assert(
    Buffer.isBuffer(bytes) && bytes.length > 0 && bytes.length <= 16777216,
  );
  const text = new TextDecoder("utf-8", { fatal: true }).decode(bytes);
  const value = JSON.parse(text);
  assert(value && Object.getPrototypeOf(value) === Object.prototype);
  assert.equal(
    functionalCanonicalJSON(value),
    text,
    "Storage bytes are not canonical",
  );
  return value;
}

export function decodeFunctionalPreferenceStorage(
  bytes,
  ownedKeys,
  maskedKeys = [],
) {
  assert(
    Array.isArray(ownedKeys) && ownedKeys.length > 0 && ownedKeys.length <= 64,
  );
  assert.equal(new Set(ownedKeys).size, ownedKeys.length);
  for (const key of ownedKeys)
    assert(
      typeof key === "string" &&
        Buffer.byteLength(key) > 0 &&
        Buffer.byteLength(key) <= 256,
    );
  assert(
    Array.isArray(maskedKeys) &&
      new Set(maskedKeys).size === maskedKeys.length &&
      maskedKeys.every((key) => ownedKeys.includes(key)),
  );
  assert(Buffer.isBuffer(bytes) && bytes.length <= 1048576);
  const value = decodeFunctionalCanonicalStorage(bytes);
  assert.deepEqual(Object.keys(value).sort(), [...ownedKeys].sort());
  for (const key of ownedKeys) {
    const record = value[key];
    assert(record && Object.getPrototypeOf(record) === Object.prototype);
    assert.equal(typeof record.present, "boolean");
    assert.deepEqual(
      Object.keys(record).sort(),
      record.present ? ["present", "value"] : ["present"],
    );
    if (record.present && maskedKeys.includes(key)) {
      assert(
        record.value &&
          Object.getPrototypeOf(record.value) === Object.prototype,
      );
      assert.deepEqual(Object.keys(record.value), ["maskedSHA256"]);
      assert.match(record.value.maskedSHA256, /^[0-9a-f]{64}$/);
    }
  }
  return value;
}

export function validateFunctionalSavedByteSequence({
  applicable,
  phases: observations,
  removed,
}) {
  assert.equal(typeof applicable, "boolean");
  assert(Array.isArray(observations));
  assert.deepEqual(
    observations.map(({ phase }) => phase),
    phases.map(({ phase }) => phase),
  );
  for (const observation of observations) {
    assert.deepEqual(Object.keys(observation).sort(), [
      "baseline",
      "phase",
      "saved",
    ]);
    for (const bytes of [observation.baseline, observation.saved]) {
      assert(bytes === null || Buffer.isBuffer(bytes));
      if (bytes !== null) decodeFunctionalCanonicalStorage(bytes);
      if (!applicable) assert.equal(bytes, null);
    }
    if (applicable) assert(Buffer.isBuffer(observation.saved));
  }
  const saved = observations[0].saved;
  assert.deepEqual(removed, saved, "Removal changed original saved bytes");
  for (const observation of observations.slice(1)) {
    assert.deepEqual(
      observation.baseline,
      saved,
      "Saved bytes changed before original construction",
    );
    assert.deepEqual(
      observation.saved,
      saved,
      "Original final restore changed saved bytes",
    );
  }
  return Object.freeze({
    savedSHA256:
      saved === null ? null : createHash("sha256").update(saved).digest("hex"),
  });
}

export function validateFunctionalOwnerProofInventory({
  plan,
  proofs,
  issuerDER,
  session,
  fixtureRoot,
  admittedPresentations,
}) {
  assert.match(plan.sourceCommit, /^[0-9a-f]{40}$/);
  assert.match(
    session,
    /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/,
  );
  assert.deepEqual(
    plan.owners.map(({ owner }) => owner),
    functionalActionOwners,
  );
  assert(Array.isArray(proofs));
  exactFunctionalFields(admittedPresentations, functionalActionOwners);
  const decoded = proofs.map((record) => {
    exactFunctionalFields(record, ["claim", "observation"]);
    return {
      ...record,
      claim: verifyFunctionalEnvelope(record.claim, issuerDER),
    };
  });
  assert.deepEqual(
    decoded.map(({ claim }) => claim.owner),
    functionalActionOwners,
  );
  assert(
    typeof fixtureRoot === "string" &&
      fixtureRoot.startsWith("/") &&
      fixtureRoot.endsWith(`/functional-fixture-${session}`),
  );
  const roots = new Set();
  const seenBirths = new Set();
  const results = [];
  for (const [index, record] of decoded.entries()) {
    assert.deepEqual(Object.keys(record).sort(), ["claim", "observation"]);
    const { definition } = plan.owners[index];
    assert.equal(definition.owner, functionalActionOwners[index]);
    const observed = verifyFunctionalEnvelope(record.observation, issuerDER);
    assert.equal(observed.sourceCommit, plan.sourceCommit);
    assert.equal(observed.session, session);
    assert.equal(observed.owner, definition.owner);
    for (const stage of observed.stages)
      assert.equal(stage.capability.fixtureRoot, fixtureRoot);
    const result = validateFunctionalActionProof(
      record.claim,
      definition,
      record.observation,
      issuerDER,
      undefined,
      admittedPresentations[definition.owner],
    );
    assert.equal(result.sourceCommit, plan.sourceCommit);
    assert.equal(result.session, session);
    for (const stage of observed.stages) {
      roots.add(stage.capability.fixtureRoot);
      for (const birth of [stage.capability.engine, stage.capability.ui]) {
        const identity = `${birth.pid}:${birth.birthSeconds}:${birth.birthMicroseconds}`;
        assert(
          !seenBirths.has(identity),
          "Owner proof reused an observed process birth",
        );
        seenBirths.add(identity);
      }
    }
    results.push(result);
  }
  assert.equal(roots.size, 1, "Owner proofs came from different fixture roots");
  assert([...roots][0].endsWith(`/functional-fixture-${session}`));
  return Object.freeze(results);
}

export function validateFunctionalGenerationDescriptor({
  generation,
  definition,
  issuerDER,
  expected,
}) {
  validateFunctionalCapability(generation.capability, definition);
  const capability = generation.capability;
  assert.equal(capability.pairScope, "synthetic-development");
  assert.equal(
    capability.dataDirectory,
    `${capability.fixtureRoot}/Edith Tests/worker-${capability.session}/Data/${capability.owner}`,
  );
  for (const field of [
    "sourceCommit",
    "session",
    "owner",
    "phase",
    "version",
    "packageSHA256",
    "fixtureRoot",
  ])
    assert.equal(capability[field], expected[field]);
  assert.match(
    generation.presentationID,
    /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/,
  );
  const descriptor = verifyFunctionalEnvelope(generation.descriptor, issuerDER);
  assert.deepEqual(
    Object.keys(descriptor).sort(),
    [
      "schema",
      "sourceCommit",
      "session",
      "owner",
      "phase",
      "presentationID",
      "location",
      "section",
      "capabilitySHA256",
      "root",
      "hostIdentifier",
      "home",
      "dataDirectory",
      "workerPath",
      "rolePath",
      "version",
      "hostABI",
      "packageSHA256",
      "producer",
      "engine",
      "ui",
    ].sort(),
  );
  assert.equal(descriptor.schema, 1);
  for (const field of [
    "sourceCommit",
    "session",
    "owner",
    "phase",
    "version",
    "packageSHA256",
    "hostIdentifier",
    "home",
    "dataDirectory",
    "hostABI",
  ])
    assert.equal(descriptor[field], capability[field]);
  assert.equal(descriptor.root, capability.fixtureRoot);
  assert.equal(descriptor.capabilitySHA256, functionalDigest(capability));
  assert.equal(descriptor.presentationID, generation.presentationID);
  assert.equal(descriptor.location, expected.location);
  assert.equal(descriptor.section, expected.section);
  assert.deepEqual(descriptor.producer, expected.producer);
  assert.deepEqual(descriptor.ui, expected.ui);
  for (const [name, birth] of Object.entries({
    engine: descriptor.engine,
    ui: descriptor.ui,
  })) {
    assert.deepEqual(
      Object.keys(birth).sort(),
      [
        "pid",
        "birthSeconds",
        "birthMicroseconds",
        "uid",
        "executable",
        "executableSHA256",
      ].sort(),
    );
    const { executable, ...projection } = birth;
    assert.deepEqual(projection, capability[name]);
    assert.equal(birth.uid, capability.uid);
  }
  assert.equal(
    descriptor.engine.executable,
    `${capability.fixtureRoot}/Fixture.app/Contents/MacOS/Edith`,
  );
  const workerPath = `${capability.dataDirectory.slice(0, -`/Data/${capability.owner}`.length)}/Extensions/${capability.owner}/edith-host-2/arm64/${capability.version}/${capability.owner}/ExtensionCarrier.app/Contents/Extensions/ExtensionWorker.appex`;
  assert.equal(descriptor.workerPath, workerPath);
  assert.equal(descriptor.ui.executable, `${workerPath}/Contents/MacOS/Edith`);
  assert(["app", "helper"].includes(expected.primaryRole));
  assert.equal(
    descriptor.rolePath,
    `${workerPath}/Contents/Resources/Payload/${capability.owner}/${expected.primaryRole}.bundle`,
  );
  return descriptor;
}

export function validateFunctionalOwnerPlanEntry(plan, ownerPlan) {
  assert.deepEqual(Object.keys(ownerPlan).sort(), [
    "definition",
    "owner",
    "phases",
    "recipe",
  ]);
  assert(functionalActionOwners.includes(ownerPlan.owner));
  const definitions = plan.definitions.filter(
    (definition) => definition.owner === ownerPlan.owner,
  );
  assert.equal(
    definitions.length,
    1,
    "Missing unique admitted owner definition",
  );
  const definition = definitions[0];
  const recipe = plan.recipes[ownerPlan.owner];
  assert(recipe, "Missing admitted original recipe");
  assert.deepEqual(
    ownerPlan.definition,
    definition,
    "Caller owner definition differs from admitted source",
  );
  assert.deepEqual(
    ownerPlan.recipe,
    recipe,
    "Caller original recipe differs from admitted source",
  );
  assert.deepEqual(ownerPlan.phases, phases);
  return Object.freeze({ owner: ownerPlan.owner, definition, recipe, phases });
}

export async function openFunctionalNativeGeneration(
  session,
  ownerPlan,
  phase,
  packageSHA256,
) {
  const state = await requireFunctionalNativeSession(session);
  ownerPlan = validateFunctionalOwnerPlanEntry(state.plan, ownerPlan);
  const owner = ownerPlan.owner;
  assert(
    state.ownerCatalogs.has(owner),
    "Original owner pair is not installed",
  );
  assert.equal(ownerPlan.definition.owner, owner);
  assert.deepEqual(
    phase,
    phases.find((value) => value.phase === phase.phase),
  );
  assert.match(packageSHA256, /^[0-9a-f]{64}$/);
  const prepared = await state.channel.request("prepare-generation", {
    owner,
    phase: phase.phase,
  });
  assert.deepEqual(Object.keys(prepared).sort(), [
    "operation",
    "presentation",
    "requestID",
  ]);
  const presentation = prepared.presentation;
  assert.deepEqual(Object.keys(presentation).sort(), [
    "location",
    "phase",
    "presentationID",
    "section",
  ]);
  assert.equal(presentation.phase, phase.phase);
  assert.equal(presentation.location, ownerPlan.recipe.location);
  assert.equal(presentation.section, ownerPlan.recipe.section);
  const opened = await requestFunctionalHost(
    session,
    owner,
    "open-original",
    presentation,
  );
  const held = await state.channel.request("held-generation", {
    owner,
    phase: phase.phase,
  });
  assert.deepEqual(Object.keys(held).sort(), [
    "capability",
    "descriptor",
    "operation",
    "presentationID",
    "requestID",
  ]);
  assert.equal(held.presentationID, presentation.presentationID);
  const { codeHash, ...ui } = opened.ui;
  assert.equal(typeof codeHash, "string");
  const policy = JSON.parse(state.policyBytes.toString("utf8")).find(
    (value) => value.owner === owner,
  );
  const generation = {
    capability: held.capability,
    presentationID: held.presentationID,
    descriptor: held.descriptor,
  };
  validateFunctionalGenerationDescriptor({
    generation,
    definition: ownerPlan.definition,
    issuerDER: session.issuerDER,
    expected: {
      sourceCommit: session.sourceCommit,
      session: state.plan.session,
      fixtureRoot: state.plan.root,
      owner,
      phase: phase.phase,
      version: phase.version,
      packageSHA256,
      location: ownerPlan.recipe.location,
      section: ownerPlan.recipe.section,
      producer: state.observeOwnedProducer(),
      ui,
      primaryRole: policy.primaryRole,
    },
  });
  await requireFunctionalNativeSession(session);
  Object.freeze(generation);
  nativeGenerations.set(generation, {
    registrations: new Map(),
    session,
    ownerPlan,
    digest: functionalDigest(generation),
  });
  return generation;
}

export function createFunctionalOwnedCleanup({
  cancelProducer,
  joinProcesses,
  closeCompilation,
}) {
  for (const method of [cancelProducer, joinProcesses, closeCompilation])
    assert.equal(typeof method, "function");
  let running;
  return () => {
    running ??= (async () => {
      const outcomes = await Promise.allSettled([
        Promise.resolve().then(cancelProducer),
        Promise.resolve().then(joinProcesses),
      ]);
      const failures = outcomes
        .filter((outcome) => outcome.status === "rejected")
        .map((outcome) => outcome.reason);
      try {
        await closeCompilation();
      } catch (error) {
        failures.push(error);
      }
      if (failures.length)
        throw new AggregateError(
          failures,
          "Owned session cleanup was incomplete",
        );
    })().catch((error) => {
      running = undefined;
      throw error;
    });
    return running;
  };
}

export async function executeFunctionalOriginalSteps({
  steps,
  performStep,
  requireCurrent,
  signal,
}) {
  assert(Array.isArray(steps) && steps.length >= 1 && steps.length <= 16);
  assert.equal(typeof performStep, "function");
  assert.equal(typeof requireCurrent, "function");
  const snapshot = functionalDigest(steps);
  const current = async () => {
    signal?.throwIfAborted();
    assert.equal(functionalDigest(steps), snapshot, "Original recipe changed");
    await requireCurrent();
    signal?.throwIfAborted();
    assert.equal(functionalDigest(steps), snapshot, "Original recipe changed");
  };
  const replies = [];
  for (const step of steps) {
    await current();
    const reply = await performStep(step);
    await current();
    replies.push(reply);
  }
  return Object.freeze(replies);
}

export function validateFunctionalXCTestArtifact(artifact, capability) {
  assert.deepEqual(
    Object.keys(artifact).sort(),
    [
      "runnerPath",
      "testBundlePath",
      "sourcePath",
      "sourceSHA256",
      "runnerIdentifier",
      "runnerRequirement",
      "runnerExecutableSHA256",
      "testBundleIdentifier",
      "testBundleRequirement",
      "testBundleExecutableSHA256",
    ].sort(),
  );
  for (const field of [
    "sourceSHA256",
    "runnerExecutableSHA256",
    "testBundleExecutableSHA256",
  ])
    assert.match(artifact[field], /^[0-9a-f]{64}$/);
  const directory = `${capability.fixtureRoot}/XCTest`;
  assert.equal(
    artifact.runnerPath,
    `${directory}/DerivedData/Build/Products/Release/HostedFunctionalInstalledUITests-Runner.app`,
  );
  assert.equal(
    artifact.testBundlePath,
    `${artifact.runnerPath}/Contents/PlugIns/HostedFunctionalInstalledUITests.xctest`,
  );
  assert.equal(
    artifact.sourcePath,
    `${directory}/HostedFunctionalInstalledUITests.swift`,
  );
  const identifier = `com.pulkit.edith.tests.installed-${artifact.sourceSHA256.slice(0, 24)}`;
  assert.equal(artifact.testBundleIdentifier, identifier);
  assert.equal(artifact.runnerIdentifier, `${identifier}.xctrunner`);
  assert.equal(artifact.testBundleRequirement, `identifier "${identifier}"`);
  assert.equal(
    artifact.runnerRequirement,
    `identifier "${identifier}.xctrunner"`,
  );
  return artifact;
}

export async function registerFunctionalNativeXCTestActor({
  session,
  generation,
  artifact,
}) {
  const state = await requireFunctionalNativeSession(session);
  const held = nativeGenerations.get(generation);
  assert(
    held && held.session === session,
    "Expected actual owned held generation",
  );
  assert.equal(
    functionalDigest(generation),
    held.digest,
    "Owned generation changed",
  );
  const { heldInstalledPresentationSteps } = await import("./presentation.mjs");
  const ownerPlan = validateFunctionalOwnerPlanEntry(
    state.plan,
    held.ownerPlan,
  );
  const steps = heldInstalledPresentationSteps(
    ownerPlan.recipe,
    ownerPlan.definition,
    generation.capability,
  );
  validateFunctionalXCTestArtifact(artifact, generation.capability);
  const expected = {
    owner: ownerPlan.owner,
    phase: generation.capability.phase,
    presentationID: generation.presentationID,
    capabilitySHA256: functionalDigest(generation.capability),
    recipeSHA256: functionalDigest(ownerPlan.recipe),
    sourceSHA256: artifact.sourceSHA256,
    invocationPath: `${generation.capability.fixtureRoot}/XCTest/invocations/${ownerPlan.owner}-${generation.capability.phase}.json`,
    stepCount: steps.length,
  };
  const reply = await state.channel.request("register-xctest-actor", {
    owner: expected.owner,
    phase: expected.phase,
    artifact,
  });
  assert.deepEqual(Object.keys(reply).sort(), [
    "operation",
    "registration",
    "requestID",
  ]);
  assert.deepEqual(reply.registration, expected);
  await requireFunctionalNativeSession(session);
  assert.equal(
    functionalDigest(generation),
    held.digest,
    "Owned generation changed",
  );
  assert.equal(held.registrations.size, 0, "XCTest actor already registered");
  held.registrations.set("phase", {
    registration: structuredClone(expected),
    artifact: structuredClone(artifact),
    steps: structuredClone(steps),
  });
  return Object.freeze(reply.registration);
}

export function validateFunctionalXCTestStepObservations({
  observations,
  issuerDER,
  capability,
  registration,
  artifact,
  stepIndex,
  stepSHA256,
}) {
  assert(
    Number.isSafeInteger(stepIndex) &&
      stepIndex >= 0 &&
      stepIndex < registration.stepCount,
  );
  assert.match(stepSHA256, /^[0-9a-f]{64}$/);
  assert.deepEqual(Object.keys(observations).sort(), [
    "authorization",
    "completion",
  ]);
  assert.deepEqual(
    Object.keys(registration).sort(),
    [
      "owner",
      "phase",
      "presentationID",
      "capabilitySHA256",
      "recipeSHA256",
      "sourceSHA256",
      "invocationPath",
      "stepCount",
    ].sort(),
  );
  assert.equal(registration.owner, capability.owner);
  assert.equal(registration.phase, capability.phase);
  assert.equal(
    registration.invocationPath,
    `${capability.fixtureRoot}/XCTest/invocations/${capability.owner}-${capability.phase}.json`,
  );
  assert.equal(registration.capabilitySHA256, functionalDigest(capability));
  assert.match(registration.recipeSHA256, /^[0-9a-f]{64}$/);
  assert(
    Number.isSafeInteger(registration.stepCount) &&
      registration.stepCount > 0 &&
      registration.stepCount <= 16,
  );
  assert.match(
    registration.presentationID,
    /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/,
  );
  validateFunctionalXCTestArtifact(artifact, capability);
  const claims = ["authorization", "completion"].map((name) =>
    verifyFunctionalEnvelope(observations[name], issuerDER),
  );
  for (const [index, claim] of claims.entries()) {
    assert.deepEqual(
      Object.keys(claim).sort(),
      [
        "schema",
        "sourceCommit",
        "session",
        "requestID",
        "operation",
        "owner",
        "phase",
        "authorizationID",
        "actor",
        "stepIndex",
        "stepSHA256",
        "sourceSHA256",
        "presentationID",
        "capabilitySHA256",
        "firstEventOrdinal",
        "lastEventOrdinal",
      ].sort(),
    );
    assert.equal(claim.schema, 1);
    assert.equal(
      claim.operation,
      index === 0 ? "authorize-original-step" : "complete-original-step",
    );
    assert.equal(claim.sourceCommit, capability.sourceCommit);
    assert.equal(claim.session, capability.session);
    for (const field of Object.keys(registration).filter(
      (field) =>
        !["invocationPath", "recipeSHA256", "stepCount"].includes(field),
    ))
      assert.equal(claim[field], registration[field]);
    assert.equal(claim.stepIndex, stepIndex);
    assert.equal(claim.stepSHA256, stepSHA256);
    assert.equal(claim.capabilitySHA256, functionalDigest(capability));
    assert.equal(claim.sourceSHA256, artifact.sourceSHA256);
    for (const field of ["requestID", "authorizationID"])
      assert.match(
        claim[field],
        /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/,
      );
    for (const field of ["firstEventOrdinal", "lastEventOrdinal"])
      assert(Number.isSafeInteger(claim[field]) && claim[field] >= 0);
    assert(claim.lastEventOrdinal >= claim.firstEventOrdinal);
    const actor = claim.actor;
    assert.deepEqual(
      Object.keys(actor).sort(),
      [
        "pid",
        "birthSeconds",
        "birthMicroseconds",
        "uid",
        "executable",
        "executableSHA256",
      ].sort(),
    );
    assert(
      Number.isSafeInteger(actor.pid) &&
        actor.pid > 1 &&
        actor.pid <= 2147483647,
    );
    assert(Number.isSafeInteger(actor.birthSeconds) && actor.birthSeconds > 0);
    assert(
      Number.isSafeInteger(actor.birthMicroseconds) &&
        actor.birthMicroseconds >= 0 &&
        actor.birthMicroseconds < 1000000,
    );
    assert.equal(actor.uid, capability.uid);
    assert(![capability.engine.pid, capability.ui.pid].includes(actor.pid));
    assert.equal(
      actor.executable,
      `${artifact.runnerPath}/Contents/MacOS/HostedFunctionalInstalledUITests-Runner`,
    );
    assert.equal(actor.executableSHA256, artifact.runnerExecutableSHA256);
  }
  const [authorization, completion] = claims;
  assert.notEqual(authorization.requestID, completion.requestID);
  assert.equal(authorization.firstEventOrdinal, authorization.lastEventOrdinal);
  assert.equal(completion.authorizationID, authorization.authorizationID);
  assert.deepEqual(completion.actor, authorization.actor);
  assert.equal(completion.firstEventOrdinal, authorization.firstEventOrdinal);
  assert(completion.lastEventOrdinal >= authorization.lastEventOrdinal);
  return Object.freeze({ authorization, completion });
}

export function validateFunctionalXCTestGenerationObservations({
  observations,
  issuerDER,
  capability,
  registration,
  artifact,
  steps,
}) {
  assert.deepEqual(Object.keys(observations), ["steps"]);
  assert(Array.isArray(steps) && steps.length === registration.stepCount);
  assert(Array.isArray(observations.steps));
  assert.equal(observations.steps.length, steps.length);
  const requestIDs = new Set(),
    authorizationIDs = new Set();
  let birth,
    previousOrdinal = -1;
  return Object.freeze(
    observations.steps.map((record, stepIndex) => {
      assert.deepEqual(Object.keys(record).sort(), [
        "authorization",
        "completion",
        "stepIndex",
      ]);
      assert.equal(record.stepIndex, stepIndex);
      const claims = validateFunctionalXCTestStepObservations({
        observations: {
          authorization: record.authorization,
          completion: record.completion,
        },
        issuerDER,
        capability,
        registration,
        artifact,
        stepIndex,
        stepSHA256: functionalDigest(steps[stepIndex]),
      });
      if (birth)
        assert.deepEqual(
          claims.authorization.actor,
          birth,
          "Recipe changed actual actor birth",
        );
      else birth = claims.authorization.actor;
      assert(
        claims.authorization.firstEventOrdinal >= previousOrdinal,
        "Original step journal moved backwards",
      );
      previousOrdinal = claims.completion.lastEventOrdinal;
      assert(
        !authorizationIDs.has(claims.authorization.authorizationID),
        "Original step reused authorization",
      );
      authorizationIDs.add(claims.authorization.authorizationID);
      for (const claim of [claims.authorization, claims.completion]) {
        assert(
          !requestIDs.has(claim.requestID),
          "Original step reused actual request",
        );
        requestIDs.add(claim.requestID);
      }
      return claims;
    }),
  );
}

export async function observeFunctionalNativeXCTestGeneration({
  session,
  generation,
}) {
  const state = await requireFunctionalNativeSession(session);
  const held = nativeGenerations.get(generation);
  assert(
    held && held.session === session,
    "Expected actual owned held generation",
  );
  assert.equal(
    functionalDigest(generation),
    held.digest,
    "Owned generation changed",
  );
  const registered = held.registrations.get("phase");
  assert(registered, "No actual source-built XCTest actor registration");
  const reply = await state.channel.request("xctest-step-observations", {
    owner: generation.capability.owner,
    phase: generation.capability.phase,
  });
  assert.deepEqual(Object.keys(reply).sort(), [
    "observations",
    "operation",
    "requestID",
  ]);
  const claims = validateFunctionalXCTestGenerationObservations({
    observations: reply.observations,
    issuerDER: session.issuerDER,
    capability: generation.capability,
    ...registered,
  });
  await requireFunctionalNativeSession(session);
  assert.equal(
    functionalDigest(generation),
    held.digest,
    "Owned generation changed",
  );
  return Object.freeze({ observations: reply.observations, claims });
}

function exactFunctionalFields(value, fields) {
  assert(value && Object.getPrototypeOf(value) === Object.prototype);
  assert.deepEqual(Object.keys(value).sort(), [...fields].sort());
}

function functionalOwnedSavedPath(file, expected) {
  const roots = {
    "owner-home": `${expected.fixtureRoot}/${expected.owner}-home`,
    "owner-data": `${expected.fixtureRoot}/Edith Tests/worker-${expected.session}/Data/${expected.owner}`,
    "owner-inputs": `${expected.fixtureRoot}/inputs/${expected.owner}`,
    "owner-outputs": `${expected.fixtureRoot}/outputs/${expected.owner}`,
  };
  assert(Object.hasOwn(roots, file.root));
  const derived = {
    "ui-suite-plist": `${expected.hostIdentifier}.extension.${expected.owner}.worker.plist`,
    "engine-suite-plist": `${expected.hostIdentifier}.extensions.${expected.owner}.plist`,
    session: expected.session,
    phase: expected.phase,
  };
  assert(
    Array.isArray(file.components) &&
      file.components.length > 0 &&
      file.components.length <= 16,
  );
  const components = file.components.map((value) => {
    if (typeof value !== "string") {
      exactFunctionalFields(value, ["derived"]);
      assert(Object.hasOwn(derived, value.derived));
      value = derived[value.derived];
    }
    assert(
      typeof value === "string" &&
        value.length > 0 &&
        Buffer.byteLength(value) <= 255,
    );
    assert(![".", ".."].includes(value) && !/[\\/\0]/.test(value));
    return value;
  });
  return `${roots[file.root]}/${components.join("/")}`;
}

function functionalSavedExpectedBytes(policy, expected, final) {
  function expand(value) {
    if (Array.isArray(value)) return value.map(expand);
    if (value && typeof value === "object") {
      if (Object.hasOwn(value, "$binding")) {
        if (value.$binding === "session") {
          exactFunctionalFields(value, ["$binding"]);
          return expected.session;
        }
        assert.equal(value.$binding, "owned-path");
        exactFunctionalFields(value, ["$binding", "root", "components"]);
        return functionalOwnedSavedPath(value, expected);
      }
      return Object.fromEntries(
        Object.entries(value).map(([key, item]) => [key, expand(item)]),
      );
    }
    return value;
  }
  const value =
    final || expected.phase !== "initial" ? policy.final : policy.initial;
  return value === null
    ? null
    : Buffer.from(functionalCanonicalJSON(expand(value)));
}

function validateFunctionalRawSaved(raw, policy, expected, bytes) {
  exactFunctionalFields(raw, [
    "reader",
    "observationID",
    "readbackSHA256",
    "files",
  ]);
  assert.equal(raw.reader, "independent-hosted-producer");
  assert.match(
    raw.observationID,
    /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/,
  );
  const digest =
    bytes === null ? null : createHash("sha256").update(bytes).digest("hex");
  assert.equal(raw.readbackSHA256, digest);
  const files = [...policy.reads, ...policy.sentinels];
  assert.equal(raw.files.length, files.length);
  for (const [index, file] of raw.files.entries()) {
    exactFunctionalFields(file, [
      "name",
      "path",
      "present",
      "bytes",
      "sha256",
      "identity",
    ]);
    const source = files[index];
    assert.equal(file.name, source.name);
    assert.equal(file.path, functionalOwnedSavedPath(source, expected));
    assert.equal(typeof file.present, "boolean");
    assert(
      Number.isSafeInteger(file.bytes) &&
        file.bytes >= 0 &&
        file.bytes <= source.maximumBytes,
    );
    if (!file.present) {
      assert.equal(file.bytes, 0);
      assert.equal(file.sha256, null);
      assert.deepEqual(file.identity, {});
    } else {
      assert.match(file.sha256, /^[0-9a-f]{64}$/);
      exactFunctionalFields(file.identity, [
        "device",
        "inode",
        "uid",
        "mode",
        "links",
        "size",
        "modifiedSeconds",
        "modifiedNanoseconds",
        "changedSeconds",
        "changedNanoseconds",
      ]);
      for (const value of Object.values(file.identity))
        assert.match(value, /^-?[0-9]+$/);
      assert.equal(file.identity.uid, String(expected.uid));
      assert.equal(file.identity.size, String(file.bytes));
      assert.equal(file.identity.links, "1");
    }
  }
  return raw;
}

export function validateFunctionalPersistenceObservation({
  envelope,
  issuerDER,
  policy,
  expected,
  baseline,
  capability,
}) {
  exactFunctionalFields(policy, [
    "schema",
    "owner",
    "reads",
    "sentinels",
    "initial",
    "final",
  ]);
  assert.equal(policy.schema, 1);
  assert.equal(policy.owner, expected.owner);
  const claim = verifyFunctionalEnvelope(envelope, issuerDER);
  const final = capability !== undefined;
  exactFunctionalFields(claim, [
    "schema",
    "sourceCommit",
    "session",
    "owner",
    "phase",
    "definitionSHA256",
    final ? "observation" : "baseline",
    "raw",
    "saved",
    ...(final ? ["capabilitySHA256", "beforeFirstRequest"] : []),
  ]);
  assert.equal(claim.schema, 1);
  for (const field of ["sourceCommit", "session", "owner", "phase"])
    assert.equal(claim[field], expected[field]);
  assert.equal(claim.definitionSHA256, functionalDigest(policy));
  const bytes =
    claim.saved === null ? null : Buffer.from(claim.saved, "base64");
  if (bytes !== null) {
    assert.equal(bytes.toString("base64"), claim.saved);
    decodeFunctionalCanonicalStorage(bytes);
  }
  const expectedBytes = functionalSavedExpectedBytes(policy, expected, final);
  assert.deepEqual(
    bytes,
    expectedBytes,
    "Observed saved bytes differ from compiled original semantics",
  );
  const observation = claim[final ? "observation" : "baseline"];
  exactFunctionalFields(observation, [
    "reader",
    "observationID",
    "sequence",
    "readbackSHA256",
    "expectedSHA256",
  ]);
  assert.equal(observation.reader, "independent-hosted-producer");
  assert.match(
    observation.observationID,
    /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/,
  );
  assert(
    Number.isSafeInteger(observation.sequence) && observation.sequence > 0,
  );
  const digest =
    bytes === null ? null : createHash("sha256").update(bytes).digest("hex");
  assert.equal(observation.readbackSHA256, digest);
  assert.equal(observation.expectedSHA256, digest);
  validateFunctionalRawSaved(claim.raw, policy, expected, bytes);
  if (final) {
    assert(baseline && baseline.claim && Buffer.isBuffer(issuerDER));
    assert.equal(claim.capabilitySHA256, functionalDigest(capability));
    assert.equal(observation.sequence > baseline.claim.baseline.sequence, true);
    assert.notEqual(
      observation.observationID,
      baseline.claim.baseline.observationID,
    );
    const first = claim.beforeFirstRequest;
    exactFunctionalFields(first, [
      ...Object.keys(baseline.claim.baseline),
      "capabilitySHA256",
      "engine",
      "ui",
      "beforeRequestID",
    ]);
    for (const [key, value] of Object.entries(baseline.claim.baseline))
      assert.deepEqual(first[key], value);
    assert.equal(first.capabilitySHA256, functionalDigest(capability));
    assert.deepEqual(first.engine, capability.engine);
    assert.deepEqual(first.ui, capability.ui);
    assert.match(
      first.beforeRequestID,
      /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/,
    );
  }
  return Object.freeze({ envelope, claim, bytes });
}

function functionalNativeSavedExpected(state, owner, phase) {
  assert(functionalActionOwners.includes(owner));
  assert(phases.some((value) => value.phase === phase));
  return {
    sourceCommit: state.plan.sourceCommit,
    session: state.plan.session,
    owner,
    phase,
    fixtureRoot: state.plan.root,
    hostIdentifier: state.plan.hostIdentifier,
    uid: state.observeOwnedProducer().uid,
  };
}

export async function captureFunctionalNativeBaseline({
  session,
  owner,
  phase,
}) {
  const state = await requireFunctionalNativeSession(session),
    key = `${owner}:${phase}`;
  assert(!state.savedBaselines.has(key), "Original baseline already captured");
  const expected = functionalNativeSavedExpected(state, owner, phase);
  const response = await state.channel.request("capture-before-construction", {
    owner,
    phase,
  });
  exactFunctionalFields(response, ["requestID", "operation", "observation"]);
  const result = validateFunctionalPersistenceObservation({
    envelope: response.observation,
    issuerDER: session.issuerDER,
    policy: state.plan.savedReaderPolicies[owner],
    expected,
  });
  await requireFunctionalNativeSession(session);
  state.savedBaselines.set(key, result);
  return result;
}

export async function readFunctionalNativeSaved({ session, generation }) {
  const state = await requireFunctionalNativeSession(session),
    held = nativeGenerations.get(generation);
  assert(
    held && held.session === session,
    "Expected actual owned held generation",
  );
  assert.equal(functionalDigest(generation), held.digest);
  const capability = generation.capability,
    key = `${capability.owner}:${capability.phase}`;
  const baseline = state.savedBaselines.get(key);
  assert(baseline, "Missing actual before-construction baseline");
  const expected = functionalNativeSavedExpected(
    state,
    capability.owner,
    capability.phase,
  );
  const response = await state.channel.request("read-saved", {
    owner: capability.owner,
    phase: capability.phase,
  });
  exactFunctionalFields(response, ["requestID", "operation", "observation"]);
  const result = validateFunctionalPersistenceObservation({
    envelope: response.observation,
    issuerDER: session.issuerDER,
    policy: state.plan.savedReaderPolicies[capability.owner],
    expected,
    baseline,
    capability,
  });
  await requireFunctionalNativeSession(session);
  assert.equal(functionalDigest(generation), held.digest);
  state.savedObservations.set(key, result);
  return result;
}

export function validateFunctionalDrainObservation({
  envelope,
  issuerDER,
  capability,
}) {
  const claim = verifyFunctionalEnvelope(envelope, issuerDER);
  exactFunctionalFields(claim, [
    "schema",
    "sourceCommit",
    "session",
    "owner",
    "phase",
    "capabilitySHA256",
    "receipt",
  ]);
  assert.equal(claim.schema, 1);
  for (const field of ["sourceCommit", "session", "owner", "phase"])
    assert.equal(claim[field], capability[field]);
  assert.equal(claim.capabilitySHA256, functionalDigest(capability));
  exactFunctionalFields(claim.receipt, [
    "births",
    "allTasksJoined",
    "birthsAbsent",
    "leasesReleased",
    "signalsSent",
  ]);
  assert.deepEqual(claim.receipt.births, [capability.engine, capability.ui]);
  for (const field of ["allTasksJoined", "birthsAbsent", "leasesReleased"])
    assert.equal(claim.receipt[field], true);
  assert.equal(claim.receipt.signalsSent, 0);
  return claim;
}

export async function drainFunctionalNativeGeneration({ session, generation }) {
  const state = await requireFunctionalNativeSession(session),
    held = nativeGenerations.get(generation);
  assert(
    held && held.session === session,
    "Expected actual owned held generation",
  );
  assert.equal(functionalDigest(generation), held.digest);
  const { owner, phase } = generation.capability;
  assert(
    state.savedObservations.has(`${owner}:${phase}`),
    "Missing final actual saved observation",
  );
  await requestFunctionalHost(session, owner, "drain", {});
  assert.equal(functionalDigest(generation), held.digest);
  const reply = await state.channel.request("collect-drain", { owner, phase });
  assert.equal(functionalDigest(generation), held.digest);
  exactFunctionalFields(reply, ["requestID", "operation", "receipt"]);
  const claim = validateFunctionalDrainObservation({
    envelope: reply.receipt,
    issuerDER: session.issuerDER,
    capability: generation.capability,
  });
  await requireFunctionalNativeSession(session);
  assert.equal(functionalDigest(generation), held.digest);
  const presentation = await state.channel.request("seal-presentation-proof", {
    owner,
    phase,
  });
  assert.equal(functionalDigest(generation), held.digest);
  exactFunctionalFields(presentation, [
    "requestID",
    "operation",
    "observation",
  ]);
  await validateFunctionalNativePresentationObservation({
    envelope: presentation.observation,
    issuerDER: session.issuerDER,
    generation,
    recipe: held.ownerPlan.recipe,
    definition: held.ownerPlan.definition,
  });
  assert.equal(functionalDigest(generation), held.digest);
  await requireFunctionalNativeSession(session);
  assert.equal(functionalDigest(generation), held.digest);
  const transcripts = state.ownerPresentations.get(owner);
  const transcriptIndex = transcripts.findIndex(
    (value) => value.generation === generation,
  );
  assert(
    transcriptIndex >= 0,
    "Missing actual retained original actor transcript",
  );
  assert(
    !Object.hasOwn(transcripts[transcriptIndex], "presentationObservation"),
    "Original presentation already sealed",
  );
  transcripts[transcriptIndex] = Object.freeze({
    ...transcripts[transcriptIndex],
    presentationObservation: presentation.observation,
  });
  assert.equal(functionalDigest(generation), held.digest);
  const retired = await state.channel.request("retired", {});
  assert.equal(functionalDigest(generation), held.digest);
  exactFunctionalFields(retired, [
    "requestID",
    "operation",
    "ownedBirthsAbsent",
  ]);
  assert.equal(retired.ownedBirthsAbsent, true);
  await requireFunctionalNativeSession(session);
  assert.equal(functionalDigest(generation), held.digest);
  return Object.freeze({ envelope: reply.receipt, claim });
}

export function validateFunctionalRemovalObservation({
  envelope,
  issuerDER,
  policy,
  expected,
  saved,
}) {
  const claim = verifyFunctionalEnvelope(envelope, issuerDER);
  exactFunctionalFields(claim, [
    "schema",
    "sourceCommit",
    "session",
    "owner",
    "receipt",
    "before",
    "after",
  ]);
  assert.equal(claim.schema, 1);
  for (const field of ["sourceCommit", "session", "owner"])
    assert.equal(claim[field], expected[field]);
  exactFunctionalFields(claim.receipt, [
    "physicallyAbsentVersions",
    "pendingRemoval",
    "leasesReleased",
    "sentinelBytesPreserved",
    "semanticDataPreserved",
  ]);
  assert.deepEqual(claim.receipt.physicallyAbsentVersions, ["1.0.0", "1.1.0"]);
  assert.equal(claim.receipt.pendingRemoval, false);
  for (const field of [
    "leasesReleased",
    "sentinelBytesPreserved",
    "semanticDataPreserved",
  ])
    assert.equal(claim.receipt[field], true);
  for (const raw of [claim.before, claim.after])
    validateFunctionalRawSaved(raw, policy, expected, saved.bytes);
  assert.deepEqual(
    claim.before,
    saved.claim.raw,
    "Removal differs from actual final retained read",
  );
  const withoutIdentity = (raw) =>
    raw.files.map(({ identity, ...file }) => file);
  assert.deepEqual(withoutIdentity(claim.after), withoutIdentity(claim.before));
  assert.notEqual(claim.before.observationID, claim.after.observationID);
  return claim;
}

export async function removeFunctionalNativeOwner(session, owner, phase) {
  const state = await requireFunctionalNativeSession(session);
  const saved = state.savedObservations.get(`${owner}:${phase}`);
  assert(saved, "Missing original final saved observation");
  const reply = await requestFunctionalHostReply(session, owner, "remove", {});
  exactFunctionalFields(reply, [
    "requestID",
    "operation",
    "response",
    "removal",
  ]);
  const claim = validateFunctionalRemovalObservation({
    envelope: reply.removal,
    issuerDER: session.issuerDER,
    policy: state.plan.savedReaderPolicies[owner],
    expected: functionalNativeSavedExpected(state, owner, phase),
    saved,
  });
  await requireFunctionalNativeSession(session);
  return Object.freeze({ envelope: reply.removal, claim });
}

export const functionalRunRequiredNativeOperations = Object.freeze([
  "authority-metadata",
  "host-registration",
  "host-command",
  "seal-catalog",
  "capture-before-construction",
  "read-saved",
  "prepare-generation",
  "held-generation",
  "register-xctest-actor",
  "xctest-step-observations",
  "collect-drain",
  "seal-presentation-proof",
  "retired",
  "seal-owner-proof",
  "seal-qualified-evidence",
  "finish",
  "cancel",
]);

export function validateFunctionalRunNativeSourceOperations(bytes) {
  assert(Buffer.isBuffer(bytes) && bytes.length > 0 && bytes.length <= 1048576);
  const source = new TextDecoder("utf-8", { fatal: true }).decode(bytes);
  for (const operation of functionalRunRequiredNativeOperations) {
    assert.equal(
      source.split(`case "${operation}":`).length,
      2,
      `Duplicated or missing actual native operation ${operation}`,
    );
    const cases = [
      ...source.matchAll(
        new RegExp(`^([ \t]*)case "${operation}":\\s*$`, "gm"),
      ),
    ];
    assert.equal(
      cases.length,
      1,
      `Missing unique actual native operation ${operation}`,
    );
    const current = cases[0],
      rest = source.slice(current.index + current[0].length);
    const next = new RegExp(`^${current[1]}(?:case "|default:)`, "m").exec(
      rest,
    );
    const body = next ? rest.slice(0, next.index) : rest;
    assert(
      /FunctionalBytes[.]exact\s*\(\s*command\s*,/.test(body),
      `Missing closed native input ${operation}`,
    );
    assert(
      /try\s+emit\s*\(/.test(body),
      `Missing actual native output ${operation}`,
    );
    assert(
      !body.includes("FunctionalFailure.unavailable("),
      `Unavailable native operation ${operation}`,
    );
  }
  return Object.freeze([...functionalRunRequiredNativeOperations]);
}

export async function createFunctionalNativeOwnerAdapter({
  session,
  ownerPlan,
  environment,
}) {
  const state = await requireFunctionalNativeSession(session);
  ownerPlan = validateFunctionalOwnerPlanEntry(state.plan, ownerPlan);
  const owner = ownerPlan.owner;
  const generations = [],
    observations = [];
  const current = async (signal) => {
    signal?.throwIfAborted();
    await requireFunctionalNativeSession(session);
    signal?.throwIfAborted();
  };
  async function installPackage(selected, version, signal) {
    await current(signal);
    assert.equal(selected.version, version);
    assert.match(selected.archiveSHA256, /^[0-9a-f]{64}$/);
    return installFunctionalNativeOwnerVersion(session, owner, version);
  }
  return Object.freeze({
    async captureBeforeConstruction({ owner: selectedOwner, phase, signal }) {
      assert.equal(selectedOwner, owner);
      await current(signal);
      return captureFunctionalNativeBaseline({ session, owner, phase });
    },
    install: (selected, signal) => installPackage(selected, "1.0.0", signal),
    update: (selected, signal) => installPackage(selected, "1.1.0", signal),
    reinstall: (selected, signal) => installPackage(selected, "1.1.0", signal),
    async prepareGeneration({
      ownerPlan: selected,
      phase,
      pair,
      baseline,
      signal,
    }) {
      await current(signal);
      assert.deepEqual(selected, ownerPlan);
      assert.equal(pair.owner, owner);
      const actualBaseline = state.savedBaselines.get(
        `${owner}:${phase.phase}`,
      );
      assert.equal(
        baseline,
        actualBaseline,
        "Expected actual retained before-construction read",
      );
      const packageSHA256 = pair.packages.find(
        (value) => value.version === phase.version,
      )?.archiveSHA256;
      const generation = await openFunctionalNativeGeneration(
        session,
        ownerPlan,
        phase,
        packageSHA256,
      );
      generations.push(generation);
      return generation;
    },
    async loadOriginal({ generation, binding, baseline, signal }) {
      await current(signal);
      const held = nativeGenerations.get(generation);
      assert(
        held && held.session === session && held.ownerPlan.owner === owner,
      );
      assert.equal(functionalDigest(generation), held.digest);
      assert.equal(binding.presentationID, generation.presentationID);
      assert.equal(
        binding.capabilitySHA256,
        functionalDigest(generation.capability),
      );
      assert.equal(
        baseline,
        state.savedBaselines.get(`${owner}:${generation.capability.phase}`),
      );
      assert.deepEqual(binding.baseline, baseline.bytes);
      validateFunctionalGenerationDescriptor({
        generation,
        definition: ownerPlan.definition,
        issuerDER: session.issuerDER,
        expected: {
          sourceCommit: session.sourceCommit,
          session: state.plan.session,
          fixtureRoot: state.plan.root,
          owner,
          phase: generation.capability.phase,
          version: generation.capability.version,
          packageSHA256: generation.capability.packageSHA256,
          location: ownerPlan.recipe.location,
          section: ownerPlan.recipe.section,
          producer: state.observeOwnedProducer(),
          ui: JSON.parse(generation.descriptor.payload).ui,
          primaryRole: JSON.parse(state.policyBytes.toString("utf8")).find(
            (value) => value.owner === owner,
          ).primaryRole,
        },
      });
      await current(signal);
    },
    async performOriginal({ generation, recipe, signal }) {
      await current(signal);
      assert.deepEqual(recipe, ownerPlan.recipe);
      assert.equal(
        typeof state.controller.runFunctionalInstalledXCTestGeneration,
        "function",
        "Missing actual maintained whole recipe XCTest actor",
      );
      await state.controller.runFunctionalInstalledXCTestGeneration({
        repository: state.repository,
        sourcePins: state.plan.sourcePins,
        recipe: ownerPlan.recipe,
        definition: ownerPlan.definition,
        capability: generation.capability,
        nativeSession: session,
        generation,
        channel: state.channel,
        issuerManifestBytes: session.issuerManifestBytes,
        admittedIssuer: session.admittedIssuer,
        artifactBytes: session.artifactBytes,
        admittedArtifact: session.admittedArtifact,
        policyBytes: state.policyBytes,
        admittedPolicies: state.admittedPolicies,
        environment,
      });
      await current(signal);
      const observed = await observeFunctionalNativeXCTestGeneration({
        session,
        generation,
      });
      observations.push(observed);
      const registered = nativeGenerations
        .get(generation)
        .registrations.get("phase");
      const transcript = Object.freeze({
        generation,
        registration: registered.registration,
        artifact: registered.artifact,
        observations: observed.observations,
      });
      const retained = state.ownerPresentations.get(owner) ?? [];
      retained.push(transcript);
      state.ownerPresentations.set(owner, retained);
      return Object.freeze({
        capability: generation.capability,
        observations: observed.observations,
      });
    },
    async readSaved({ generation, signal }) {
      await current(signal);
      return readFunctionalNativeSaved({ session, generation });
    },
    async closeAndDrain({ generation, signal }) {
      await current(signal);
      return (await drainFunctionalNativeGeneration({ session, generation }))
        .claim.receipt;
    },
    async remove({ signal }) {
      await current(signal);
      return (await removeFunctionalNativeOwner(session, owner, "updated"))
        .claim.receipt;
    },
    async sealProof({ stages, definition, signal }) {
      await current(signal);
      assert.deepEqual(definition, ownerPlan.definition);
      assert.equal(stages.length, 3);
      assert.equal(observations.length, 3);
      assert.deepEqual(
        stages.map((value) => value.capability),
        generations.map((value) => value.capability),
      );
      await removeFunctionalNativeOwner(session, owner, "reinstalled");
      const reply = await state.channel.request("seal-owner-proof", { owner });
      exactFunctionalFields(reply, [
        "requestID",
        "operation",
        "claim",
        "observation",
      ]);
      const claim = verifyFunctionalEnvelope(reply.claim, session.issuerDER);
      const observation = verifyFunctionalEnvelope(
        reply.observation,
        session.issuerDER,
      );
      assert.equal(claim.sourceCommit, session.sourceCommit);
      assert.equal(claim.session, state.plan.session);
      assert.equal(claim.owner, owner);
      assert.deepEqual(
        observation.stages.map((value) => value.capability),
        generations.map((value) => value.capability),
      );
      validateFunctionalActionProof(
        claim,
        ownerPlan.definition,
        reply.observation,
        session.issuerDER,
        undefined,
        functionalAdmittedPresentations({
          sourceCommit: session.sourceCommit,
          session: state.plan.session,
          owner,
          definition: ownerPlan.definition,
          generations,
        }),
      );
      await current(signal);
      assert(
        !state.ownerProofs.has(owner),
        "Original owner proof already sealed",
      );
      state.ownerProofs.set(
        owner,
        Object.freeze({ claim: reply.claim, observation: reply.observation }),
      );
      await retireFunctionalNativeOwner(session, owner);
      return Object.freeze({ claim, observation: reply.observation });
    },
    cancelAndJoin: () => cancelFunctionalNativeSession(session),
  });
}

export async function runHostedFunctionalActions({
  repository,
  sourceCommit,
  environment = process.env,
}) {
  const controller = await import("./controller.mjs"),
    builder = await import("./functional-build.mjs"),
    producer = await import("./producer-project.mjs");
  environment = Object.freeze({ ...environment });
  const { admitFunctionalRunner } = producer;
  admitFunctionalRunner(environment, sourceCommit);
  assert.equal(process.platform, "darwin");
  assert.equal(process.arch, "arm64");
  repository = await realpath(repository);
  validateFunctionalRunNativeSourceOperations(
    await readFile(
      join(
        repository,
        "Tests/HostedFunctionalActions/ProducerSources/FunctionalProducer.swift",
      ),
    ),
  );
  const ready = await controller.checkFunctionalSourceReady({
    repository,
    sourceCommit,
  });
  assert.equal(
    typeof controller.runFunctionalInstalledXCTestGeneration,
    "function",
    "Missing actual maintained whole recipe XCTest actor",
  );
  const activeJob = await controller.observeFunctionalActiveJob({
    repository,
    sourceCommit,
    environment,
  });
  const toolchain = await builder.captureFunctionalCompilationToolchain({
    repository,
    sourceCommit,
    environment,
  });
  const certificateSHA256 = await producer.captureFunctionalSigningCertificate({
    environment,
    sourceCommit,
  });
  const sessionID = randomUUID(),
    root = join(environment.RUNNER_TEMP, `functional-fixture-${sessionID}`);
  await mkdir(root, { mode: 0o700 });
  let compilation,
    session,
    sessionStartupOwnsCleanup = false;
  try {
    compilation = await builder.createFunctionalCompilation({
      repository,
      sourceCommit,
      sourcePins: ready.sourcePins,
      root,
      environment,
      toolchain,
    });
    const plan = producer.functionalProducerPlan({
      sourceCommit,
      session: sessionID,
      root,
      certificateSHA256,
      sourcePins: ready.sourcePins,
      cases: ready.cases,
      manifest: ready.manifest,
      recipes: Object.fromEntries(
        ready.plan.owners.map((value) => [value.owner, value.recipe]),
      ),
      policyBytes: ready.policyBytes,
      admittedPolicies: ready.admittedPolicies,
      policySources: ready.policySources,
      savedReaderPolicies: ready.savedReaderPolicies,
      savedReaderSources: ready.savedReaderSources,
      preparationPolicies: ready.preparationPolicies,
      preparationSources: ready.preparationSources,
      observationPolicies: ready.observationPolicies,
      observationSources: ready.observationSources,
      activeJob,
      toolchain,
      environment,
    });
    sessionStartupOwnsCleanup = true;
    session = await startFunctionalNativeSession({
      repository,
      plan,
      compilation,
      policyBytes: ready.policyBytes,
      admittedPolicies: ready.admittedPolicies,
      environment,
    });
    await executeFunctionalOwners({
      plan: ready.plan,
      requireCurrent: () => requireFunctionalNativeSession(session),
      runOwner: async (ownerPlan) =>
        controller.runFunctionalOwner({
          repository,
          sourcePins: ready.sourcePins,
          ownerPlan,
          ...session,
          policyBytes: ready.policyBytes,
          admittedPolicies: ready.admittedPolicies,
          environment,
          compilation,
          native: await createFunctionalNativeOwnerAdapter({
            session,
            ownerPlan,
            environment,
          }),
        }),
      cancelAndJoin: () => cancelFunctionalNativeSession(session),
    });
    const state = await requireFunctionalNativeSession(session);
    const ownerProofs = functionalActionOwners.map((owner) => {
      const proof = state.ownerProofs.get(owner);
      assert(proof, "Missing actual sealed owner proof");
      return proof;
    });
    validateFunctionalOwnerProofInventory({
      plan: ready.plan,
      proofs: ownerProofs,
      admittedPresentations: Object.fromEntries(
        ready.plan.owners.map(({ owner, definition }) => [
          owner,
          functionalAdmittedPresentations({
            sourceCommit,
            session: sessionID,
            owner,
            definition,
            generations: state.ownerPresentations
              .get(owner)
              .map((value) => value.generation),
          }),
        ]),
      ),
      issuerDER: session.issuerDER,
      session: sessionID,
      fixtureRoot: root,
    });
    const reply = await state.channel.request("seal-qualified-evidence", {});
    exactFunctionalFields(reply, ["requestID", "operation", "evidence"]);
    const expected = {
      sourceCommit,
      mergeCommit: plan.hostedRunPins.mergeCommit,
      baseCommit: plan.hostedRunPins.baseCommit,
      session: sessionID,
      sourceSHA256: plan.sourceSHA256,
      toolchainSHA256: plan.toolchainSHA256,
      policySHA256: plan.policySHA256,
      runID: plan.hostedRunPins.runID,
      jobID: plan.hostedRunPins.jobID,
      runAttempt: plan.hostedRunPins.runAttempt,
      workflowSHA256: plan.hostedRunPins.workflowSHA256,
    };
    const issuerManifest = JSON.parse(
        session.issuerManifestBytes.toString("utf8"),
      ),
      hostArtifact = JSON.parse(session.artifactBytes.toString("utf8"));
    const seal = validateFunctionalQualifiedSeal({
      envelope: reply.evidence,
      issuerDER: session.issuerDER,
      issuerManifest,
      hostArtifact,
      ownerProofs,
      expected,
    });
    state.finalEvidence = Object.freeze({ envelope: reply.evidence, seal });
    const ownedExits = await finishFunctionalNativeSession(session);
    const artifact = {
      schema: 1,
      issuerManifest: JSON.parse(session.issuerManifestBytes.toString("utf8")),
      hostArtifact: JSON.parse(session.artifactBytes.toString("utf8")),
      evidence: reply.evidence,
      ownerProofs,
      ownedExits,
      observerHelper: state.compiled.observerHelper,
      presentations: functionalActionOwners.map((owner) => ({
        owner,
        phases: state.ownerPresentations.get(owner),
      })),
      rolePolicies: JSON.parse(ready.policyBytes.toString("utf8")),
    };
    await verifyQualifiedFunctionalEvidence({
      artifact,
      plan: ready.plan,
      sourcePins: ready.sourcePins,
      expected,
      admittedAuthority: {
        issuerPublicKey: issuerManifest.issuerPublicKey,
        issuerManifestSHA256: functionalDigest(issuerManifest),
        artifactSHA256: functionalDigest(hostArtifact),
        observerHelperSHA256: state.compiled.observerHelper.executableSHA256,
      },
    });
    const output = join(
      repository,
      "local/hosted-functional-actions/qualified-evidence",
    );
    await mkdir(output, { recursive: true, mode: 0o700 });
    await writeFile(
      join(output, "qualified-evidence.json"),
      functionalCanonicalJSON(artifact),
      { flag: "wx", mode: 0o600 },
    );
    return Object.freeze({
      sourceCommit,
      session: sessionID,
      ownerCount: ownerProofs.length,
      artifactSHA256: functionalDigest(artifact),
    });
  } catch (error) {
    try {
      if (session) await cancelFunctionalNativeSession(session);
      else if (compilation && !sessionStartupOwnsCleanup)
        await builder.closeFunctionalCompilation(compilation);
    } catch (cleanup) {
      throw new AggregateError(
        [error, cleanup],
        "Hosted functional journey failed with incomplete owned cleanup",
      );
    }
    throw error;
  }
}

export function validateFunctionalQualifiedSeal({
  envelope,
  issuerDER,
  issuerManifest,
  hostArtifact,
  ownerProofs,
  expected,
}) {
  const seal = verifyFunctionalEnvelope(envelope, issuerDER);
  exactFunctionalFields(seal, [
    "schema",
    "kind",
    "sourceCommit",
    "mergeCommit",
    "baseCommit",
    "session",
    "root",
    "hostIdentifier",
    "issuerPublicKey",
    "issuerManifestSHA256",
    "artifactSHA256",
    "policySHA256",
    "sourceSHA256",
    "toolchainSHA256",
    "runID",
    "jobID",
    "runAttempt",
    "workflowSHA256",
    "producer",
    "host",
    "owners",
    "retirement",
  ]);
  assert.equal(seal.schema, 1);
  assert.equal(seal.kind, "qualified-evidence");
  const issuerKey = Buffer.from(issuerManifest.issuerPublicKey, "base64");
  assert.equal(issuerKey.length, 32);
  assert.equal(issuerKey.toString("base64"), issuerManifest.issuerPublicKey);
  assert.deepEqual(
    issuerDER,
    Buffer.concat([Buffer.from("302a300506032b6570032100", "hex"), issuerKey]),
  );
  exactFunctionalFields(expected, [
    "sourceCommit",
    "mergeCommit",
    "baseCommit",
    "session",
    "sourceSHA256",
    "toolchainSHA256",
    "policySHA256",
    "runID",
    "jobID",
    "runAttempt",
    "workflowSHA256",
  ]);
  for (const field of ["sourceCommit", "mergeCommit", "baseCommit"])
    assert.match(expected[field], /^[0-9a-f]{40}$/);
  for (const [field, value] of Object.entries(expected))
    assert.equal(seal[field], value, `Final issuer seal binding ${field}`);
  exactFunctionalFields(issuerManifest, [
    "schema",
    "sourceCommit",
    "runID",
    "jobID",
    "session",
    "root",
    "hostIdentifier",
    "issuerPublicKey",
    "policySHA256",
    "producer",
    "signing",
  ]);
  exactFunctionalFields(issuerManifest.producer, [
    "path",
    "executableSHA256",
    "certificateSHA256",
    "requirement",
    "sourceSHA256",
    "toolchainSHA256",
  ]);
  exactFunctionalFields(issuerManifest.signing, [
    "hostRequirement",
    "hostCertificateSHA256",
    "workerCertificateSHA256",
    "roleCertificateSHA256",
  ]);
  exactFunctionalFields(hostArtifact, [
    "schema",
    "sourceCommit",
    "session",
    "root",
    "hostIdentifier",
    "issuerPublicKey",
    "issuerManifestSHA256",
    "host",
    "producer",
    "workerCertificateSHA256",
    "roleCertificateSHA256",
  ]);
  exactFunctionalFields(hostArtifact.host, [
    "path",
    "executableSHA256",
    "certificateSHA256",
    "requirement",
  ]);
  exactFunctionalFields(hostArtifact.producer, ["path", "executableSHA256"]);
  assert.deepEqual(hostArtifact.producer, {
    path: issuerManifest.producer.path,
    executableSHA256: issuerManifest.producer.executableSHA256,
  });
  assert.equal(
    hostArtifact.host.certificateSHA256,
    issuerManifest.signing.hostCertificateSHA256,
  );
  assert.equal(
    hostArtifact.host.requirement,
    issuerManifest.signing.hostRequirement,
  );
  assert.equal(
    hostArtifact.workerCertificateSHA256,
    issuerManifest.signing.workerCertificateSHA256,
  );
  assert.equal(
    hostArtifact.roleCertificateSHA256,
    issuerManifest.signing.roleCertificateSHA256,
  );
  assert.equal(issuerManifest.schema, 2);
  assert.equal(hostArtifact.schema, 2);
  for (const field of [
    "sourceCommit",
    "session",
    "root",
    "hostIdentifier",
    "issuerPublicKey",
  ]) {
    assert.equal(seal[field], issuerManifest[field]);
    assert.equal(seal[field], hostArtifact[field]);
  }
  assert.equal(seal.issuerManifestSHA256, functionalDigest(issuerManifest));
  assert.equal(seal.artifactSHA256, functionalDigest(hostArtifact));
  assert.equal(hostArtifact.issuerManifestSHA256, seal.issuerManifestSHA256);
  assert.equal(issuerManifest.producer.sourceSHA256, seal.sourceSHA256);
  assert.equal(issuerManifest.producer.toolchainSHA256, seal.toolchainSHA256);
  for (const field of ["runID", "jobID", "policySHA256"])
    assert.equal(issuerManifest[field], seal[field]);
  const producer = validateFunctionalProcessBirth(seal.producer),
    host = validateFunctionalProcessBirth(seal.host);
  assert.equal(producer.executable, issuerManifest.producer.path);
  assert.equal(
    producer.executableSHA256,
    issuerManifest.producer.executableSHA256,
  );
  assert.equal(
    host.executable,
    `${hostArtifact.host.path}/Contents/MacOS/Edith`,
  );
  assert.equal(host.executableSHA256, hostArtifact.host.executableSHA256);
  assert.equal(producer.uid, host.uid);
  assert.notEqual(producer.pid, host.pid);
  assert.equal(
    seal.hostIdentifier,
    `com.pulkit.edith.tests.worker-${seal.session}`,
  );
  assert(
    seal.root.startsWith("/") &&
      seal.root.endsWith(`/functional-fixture-${seal.session}`),
  );
  assert.equal(
    producer.executable,
    `${seal.root}/Producer/functional-producer`,
  );
  assert.equal(hostArtifact.host.path, `${seal.root}/Fixture.app`);
  assert.equal(ownerProofs.length, functionalActionOwners.length);
  assert.equal(seal.owners.length, functionalActionOwners.length);
  for (const [index, record] of seal.owners.entries()) {
    exactFunctionalFields(record, [
      "owner",
      "caseSHA256",
      "claimSHA256",
      "observationSHA256",
    ]);
    assert.equal(record.owner, functionalActionOwners[index]);
    const envelopes = ownerProofs[index];
    exactFunctionalFields(envelopes, ["claim", "observation"]);
    const claim = verifyFunctionalEnvelope(envelopes.claim, issuerDER),
      observation = verifyFunctionalEnvelope(envelopes.observation, issuerDER);
    for (const value of [claim, observation]) {
      assert.equal(value.owner, record.owner);
      assert.equal(value.caseSHA256, record.caseSHA256);
      assert.equal(value.sourceCommit, seal.sourceCommit);
      assert.equal(value.session, seal.session);
    }
    assert.equal(record.claimSHA256, functionalDigest(envelopes.claim));
    assert.equal(
      record.observationSHA256,
      functionalDigest(envelopes.observation),
    );
  }
  exactFunctionalFields(seal.retirement, [
    "hostAbsent",
    "receiverJoined",
    "signalsSent",
  ]);
  assert.equal(seal.retirement.hostAbsent, true);
  assert.equal(seal.retirement.receiverJoined, true);
  assert.equal(seal.retirement.signalsSent, 0);
  return seal;
}

export async function verifyQualifiedFunctionalEvidence({
  artifact,
  plan,
  sourcePins,
  expected,
  admittedAuthority,
}) {
  validateFunctionalQualifiedAuthority({ artifact, admittedAuthority });
  exactFunctionalFields(artifact, [
    "schema",
    "issuerManifest",
    "hostArtifact",
    "evidence",
    "ownerProofs",
    "ownedExits",
    "observerHelper",
    "presentations",
    "rolePolicies",
  ]);
  assert.equal(artifact.schema, 1);
  assert.equal(sourcePins.sourceCommit, expected.sourceCommit);
  assert.equal(plan.sourceCommit, expected.sourceCommit);
  assert.equal(functionalDigest(sourcePins), expected.sourceSHA256);
  const key = Buffer.from(artifact.issuerManifest.issuerPublicKey, "base64");
  assert.equal(key.length, 32);
  assert.equal(key.toString("base64"), artifact.issuerManifest.issuerPublicKey);
  const issuerDER = Buffer.concat([
    Buffer.from("302a300506032b6570032100", "hex"),
    key,
  ]);
  const seal = validateFunctionalQualifiedSeal({
    envelope: artifact.evidence,
    issuerDER,
    ...artifact,
    expected,
  });
  assert.equal(functionalDigest(artifact.rolePolicies), seal.policySHA256);
  const admittedPresentations = await validateFunctionalPresentationTranscripts(
    {
      presentations: artifact.presentations,
      ownerProofs: artifact.ownerProofs,
      plan,
      rolePolicies: artifact.rolePolicies,
      issuerDER,
      producer: seal.producer,
      sourceCommit: seal.sourceCommit,
      session: seal.session,
      root: seal.root,
    },
  );
  const owners = validateFunctionalOwnerProofInventory({
    plan,
    proofs: artifact.ownerProofs,
    issuerDER,
    session: expected.session,
    fixtureRoot: seal.root,
    admittedPresentations,
  });
  exactFunctionalFields(artifact.observerHelper, [
    "executable",
    "executableSHA256",
  ]);
  assert.equal(
    artifact.observerHelper.executable,
    `${seal.root}/ProcessObserver/functional-process-probe`,
  );
  assert.match(artifact.observerHelper.executableSHA256, /^[0-9a-f]{64}$/);
  assert.equal(artifact.ownedExits.length, 2);
  for (const [index, exit] of artifact.ownedExits.entries()) {
    exactFunctionalFields(exit, [
      "schema",
      "birth",
      "exitCode",
      "signal",
      "absence",
      "helper",
    ]);
    assert.equal(exit.schema, 1);
    assert.equal(exit.exitCode, 0);
    assert.equal(exit.signal, null);
    assert.deepEqual(exit.birth, index === 0 ? seal.producer : seal.host);
    assert.deepEqual(exit.helper, artifact.observerHelper);
    validateFunctionalProcessAbsence(
      Buffer.from(functionalCanonicalJSON(exit.absence)),
      exit.birth,
    );
  }
  return Object.freeze({
    sourceCommit: seal.sourceCommit,
    session: seal.session,
    ownerCount: owners.length,
    artifactSHA256: functionalDigest(artifact),
    runID: seal.runID,
    jobID: seal.jobID,
    runAttempt: seal.runAttempt,
  });
}

export function functionalAdmittedPresentations({
  sourceCommit,
  session,
  owner,
  definition,
  generations,
}) {
  assert.equal(definition.owner, owner);
  assert(functionalActionOwners.includes(owner));
  assert.equal(generations.length, 3);
  assert.deepEqual(
    generations.map((value) => value.capability.phase),
    phases.map((value) => value.phase),
  );
  const presentations = {};
  for (const generation of generations) {
    assert.equal(generation.capability.sourceCommit, sourceCommit);
    assert.equal(generation.capability.session, session);
    assert.equal(generation.capability.owner, owner);
    assert.match(
      generation.presentationID,
      /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/,
    );
    presentations[generation.capability.phase] = generation.presentationID;
  }
  assert.equal(new Set(Object.values(presentations)).size, 3);
  return Object.freeze({
    sourceCommit,
    session,
    owner,
    caseSHA256: functionalDigest(definition),
    presentations: Object.freeze(presentations),
  });
}

export async function validateFunctionalPresentationTranscripts({
  presentations,
  ownerProofs,
  plan,
  rolePolicies,
  issuerDER,
  producer,
  sourceCommit,
  session,
  root,
}) {
  const { heldInstalledPresentationSteps } = await import("./presentation.mjs");
  assert.deepEqual(
    presentations.map((value) => value.owner),
    functionalActionOwners,
  );
  assert.deepEqual(
    rolePolicies.map((value) => value.owner),
    functionalActionOwners,
  );
  const bindings = {};
  for (const [index, record] of presentations.entries()) {
    exactFunctionalFields(record, ["owner", "phases"]);
    const ownerPlan = plan.owners[index];
    assert.equal(record.owner, ownerPlan.owner);
    const observation = verifyFunctionalEnvelope(
      ownerProofs[index].observation,
      issuerDER,
    );
    assert.equal(record.phases.length, 3);
    for (const [phaseIndex, transcript] of record.phases.entries()) {
      exactFunctionalFields(transcript, [
        "generation",
        "registration",
        "artifact",
        "observations",
        "presentationObservation",
      ]);
      const { generation } = transcript,
        capability = generation.capability;
      assert.equal(capability.phase, phases[phaseIndex].phase);
      assert.deepEqual(capability, observation.stages[phaseIndex].capability);
      const descriptor = verifyFunctionalEnvelope(
        generation.descriptor,
        issuerDER,
      );
      validateFunctionalGenerationDescriptor({
        generation,
        definition: ownerPlan.definition,
        issuerDER,
        expected: {
          sourceCommit,
          session,
          fixtureRoot: root,
          owner: record.owner,
          phase: capability.phase,
          version: phases[phaseIndex].version,
          packageSHA256: capability.packageSHA256,
          location: ownerPlan.recipe.location,
          section: ownerPlan.recipe.section,
          producer,
          ui: descriptor.ui,
          primaryRole: rolePolicies[index].primaryRole,
        },
      });
      assert.equal(
        transcript.registration.presentationID,
        generation.presentationID,
      );
      assert.equal(
        transcript.registration.recipeSHA256,
        functionalDigest(ownerPlan.recipe),
      );
      await validateFunctionalNativePresentationObservation({
        envelope: transcript.presentationObservation,
        issuerDER,
        generation,
        recipe: ownerPlan.recipe,
        definition: ownerPlan.definition,
      });
      validateFunctionalXCTestGenerationObservations({
        ...transcript,
        issuerDER,
        capability,
        steps: heldInstalledPresentationSteps(
          ownerPlan.recipe,
          ownerPlan.definition,
          capability,
        ),
      });
    }
    bindings[record.owner] = functionalAdmittedPresentations({
      sourceCommit,
      session,
      owner: record.owner,
      definition: ownerPlan.definition,
      generations: record.phases.map((value) => value.generation),
    });
  }
  return Object.freeze(bindings);
}

export function validateFunctionalQualifiedAuthority({
  artifact,
  admittedAuthority,
}) {
  exactFunctionalFields(admittedAuthority, [
    "issuerPublicKey",
    "issuerManifestSHA256",
    "artifactSHA256",
    "observerHelperSHA256",
  ]);
  const key = Buffer.from(admittedAuthority.issuerPublicKey, "base64");
  assert.equal(key.length, 32);
  assert.equal(key.toString("base64"), admittedAuthority.issuerPublicKey);
  for (const field of [
    "issuerManifestSHA256",
    "artifactSHA256",
    "observerHelperSHA256",
  ])
    assert.match(admittedAuthority[field], /^[0-9a-f]{64}$/);
  assert.equal(
    artifact.issuerManifest.issuerPublicKey,
    admittedAuthority.issuerPublicKey,
  );
  assert.equal(
    functionalDigest(artifact.issuerManifest),
    admittedAuthority.issuerManifestSHA256,
  );
  assert.equal(
    functionalDigest(artifact.hostArtifact),
    admittedAuthority.artifactSHA256,
  );
  assert.equal(
    artifact.observerHelper.executableSHA256,
    admittedAuthority.observerHelperSHA256,
  );
  return true;
}

export async function validateFunctionalNativePresentationObservation({
  envelope,
  issuerDER,
  generation,
  recipe,
  definition,
}) {
  const { validateInstalledPresentationObservation } = await import(
    "./presentation.mjs"
  );
  const claim = verifyFunctionalEnvelope(envelope, issuerDER);
  assert.equal(claim.presentationID, generation.presentationID);
  const result = validateInstalledPresentationObservation(
    envelope,
    recipe,
    definition,
    issuerDER,
    generation.capability,
  );
  assert.equal(result.downloadedUIBinaryActionsValidated, true);
  return Object.freeze({ claim, result });
}
