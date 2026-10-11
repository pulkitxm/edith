import assert from "node:assert/strict";
import { createHash, createPublicKey, verify } from "node:crypto";
import { isAbsolute, posix } from "node:path";
import { parseExpression } from "@babel/parser";
import { functionalActionOwners } from "./owners.mjs";

const uuid =
  /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
const hash = /^[0-9a-f]{64}$/;
const source = /^[0-9a-f]{40}$/;
const phases = ["initial", "updated", "reinstalled"];
const limits = new Set([
  "synthetic-platform-adapter",
  "private-filesystem",
  "loopback-service",
  "owned-pty",
  "bundled-content",
  "owned-toolchain",
  "privileged-role-unproved",
]);

function keys(value, expected) {
  assert(value !== null && typeof value === "object" && !Array.isArray(value));
  assert.equal(Object.getPrototypeOf(value), Object.prototype);
  assert.deepEqual(Object.keys(value).sort(), [...expected].sort());
}

function text(value, maximum = 256) {
  assert(
    typeof value === "string" &&
      value.length > 0 &&
      Buffer.byteLength(value) <= maximum,
  );
  assert(
    [...value].every((character) => {
      const code = character.codePointAt(0);
      return code > 31 && code !== 127;
    }),
  );
}

function canonicalValue(value) {
  if (Array.isArray(value)) return value.map(canonicalValue);
  if (value !== null && typeof value === "object") {
    assert.equal(Object.getPrototypeOf(value), Object.prototype);
    return Object.fromEntries(
      Object.keys(value)
        .sort()
        .map((key) => [key, canonicalValue(value[key])]),
    );
  }
  assert(
    value === null || ["string", "boolean", "number"].includes(typeof value),
  );
  if (typeof value === "number") assert(Number.isFinite(value));
  return value;
}

export function functionalCanonicalJSON(value) {
  return JSON.stringify(canonicalValue(value));
}

export function functionalDigest(value) {
  return createHash("sha256")
    .update(functionalCanonicalJSON(value))
    .digest("hex");
}

export function verifyFunctionalEnvelope(envelope, compiledIssuerPublicKeyDER) {
  keys(envelope, ["schema", "payload", "signature"]);
  assert.equal(envelope.schema, 1);
  assert(
    typeof envelope.payload === "string" &&
      Buffer.byteLength(envelope.payload) <= 1_048_576,
  );
  assert.match(envelope.signature, /^[A-Za-z0-9+/]{86}==$/);
  const signature = Buffer.from(envelope.signature, "base64");
  assert.equal(signature.length, 64);
  assert.equal(signature.toString("base64"), envelope.signature);
  assert(Buffer.isBuffer(compiledIssuerPublicKeyDER));
  const key = createPublicKey({
    key: compiledIssuerPublicKeyDER,
    format: "der",
    type: "spki",
  });
  assert.equal(key.asymmetricKeyType, "ed25519");
  const payload = JSON.parse(envelope.payload);
  assert.equal(
    functionalCanonicalJSON(payload),
    envelope.payload,
    "Noncanonical or duplicate fields",
  );
  assert(
    verify(null, Buffer.from(envelope.payload), key, signature),
    "Invalid fixture issuer signature",
  );
  return payload;
}

function path(value, root) {
  text(value, 4096);
  assert(
    isAbsolute(value) &&
      posix.normalize(value) === value &&
      !value.endsWith("/"),
  );
  if (root !== undefined) assert(value.startsWith(`${root}/`));
  return value;
}

function identity(value, uid) {
  keys(value, [
    "pid",
    "birthSeconds",
    "birthMicroseconds",
    "uid",
    "executableSHA256",
  ]);
  assert(Number.isSafeInteger(value.pid) && value.pid > 1);
  assert(Number.isSafeInteger(value.birthSeconds) && value.birthSeconds > 0);
  assert(
    Number.isSafeInteger(value.birthMicroseconds) &&
      value.birthMicroseconds >= 0 &&
      value.birthMicroseconds < 1000000,
  );
  assert.equal(value.uid, uid);
  assert.match(value.executableSHA256, hash);
  return value;
}

function version(value) {
  assert(
    typeof value === "string" &&
      value.length <= 80 &&
      /^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$/.test(value),
  );
  return value.split(".").map(BigInt);
}

function increasingVersion(before, after) {
  const a = version(before),
    b = version(after);
  for (const part of [...a, ...b]) assert(part <= 18446744073709551615n);
  for (let index = 0; index < 3; index++) {
    if (a[index] < b[index]) return;
    assert.equal(a[index], b[index], "Older package version must be lower");
  }
  assert.fail("Distinct lower package version required");
}

function differentGeneration(before, after) {
  assert.notEqual(before.pid, after.pid, "Fresh process PID required");
  assert(
    before.birthSeconds !== after.birthSeconds ||
      before.birthMicroseconds !== after.birthMicroseconds,
    "Fresh process birth required",
  );
}

function sourcePin(value, owner) {
  keys(value, ["path", "sha256"]);
  text(value.path, 4096);
  assert(value.path.startsWith(`Extensions/${owner}/`));
  assert(!value.path.split("/").some((part) => ["", ".", ".."].includes(part)));
  assert.match(value.sha256, hash);
}

export function validateFunctionalCaseDefinition(value) {
  keys(value, [
    "schema",
    "owner",
    "activation",
    "operations",
    "observation",
    "persistence",
    "limits",
  ]);
  assert.equal(value.schema, 1);
  assert(functionalActionOwners.includes(value.owner));
  keys(value.activation, [
    "kind",
    "control",
    "operation",
    "sources",
    "mutation",
  ]);
  assert(
    ["original-control-callback", "native-accessibility"].includes(
      value.activation.kind,
    ),
  );
  text(value.activation.control);
  assert(
    value.activation.sources.length >= 1 &&
      value.activation.sources.length <= 8,
  );
  for (const pin of value.activation.sources) sourcePin(pin, value.owner);
  assert.equal(
    new Set(value.activation.sources.map((pin) => pin.path)).size,
    value.activation.sources.length,
  );
  assert(value.operations.length >= 1 && value.operations.length <= 16);
  for (const operation of value.operations) {
    text(operation, 128);
    assert(
      /^[A-Za-z][A-Za-z0-9_-]*(?:\.[A-Za-z][A-Za-z0-9_-]*)+$/.test(operation),
    );
  }
  assert.equal(new Set(value.operations).size, value.operations.length);
  assert(value.operations.includes(value.activation.operation));
  assert(
    !value.activation.operation
      .split(".")
      .some((part) =>
        ["read", "snapshot", "state", "list", "schema", "get", "poll"].includes(
          part,
        ),
      ),
  );
  keys(value.activation.mutation, ["kind", "payloadKeys"]);
  assert(
    ["state-transition", "owned-output"].includes(
      value.activation.mutation.kind,
    ),
  );
  const fields = value.activation.mutation.payloadKeys;
  assert(Array.isArray(fields) && fields.length <= 32);
  assert(
    fields.length > 0 ||
      (value.owner === "terminal" &&
        value.activation.operation === "terminal.open"),
  );
  for (const field of fields)
    assert.match(field, /^[A-Za-z][A-Za-z0-9_]{0,63}$/);
  assert.equal(new Set(fields).size, fields.length);
  keys(value.observation, ["kind", "name"]);
  assert(
    [
      "checked-engine-readback",
      "owned-file-output",
      "owned-process-output",
    ].includes(value.observation.kind),
  );
  text(value.observation.name);
  keys(value.persistence, ["applicable", "name"]);
  assert(typeof value.persistence.applicable === "boolean");
  text(value.persistence.name);
  if (!value.persistence.applicable)
    assert.equal(value.persistence.name, "no-owned-persistent-record");
  assert(value.limits.length >= 1 && value.limits.length <= limits.size);
  for (const limit of value.limits) assert(limits.has(limit));
  assert.equal(new Set(value.limits).size, value.limits.length);
  return value;
}

export function validateFunctionalCapability(value, definition) {
  validateFunctionalCaseDefinition(definition);
  keys(value, [
    "schema",
    "sourceCommit",
    "session",
    "owner",
    "uid",
    "fixtureRoot",
    "hostIdentifier",
    "home",
    "dataDirectory",
    "hostABI",
    "caseSHA256",
    "activationOperation",
    "phase",
    "pairScope",
    "previousVersion",
    "currentVersion",
    "version",
    "packageSHA256",
    "engine",
    "ui",
    "operations",
    "ownedPaths",
  ]);
  assert.equal(value.schema, 1);
  assert.match(value.sourceCommit, source);
  assert.match(value.session, uuid);
  assert.equal(value.owner, definition.owner);
  assert(Number.isSafeInteger(value.uid) && value.uid >= 0);
  path(value.fixtureRoot);
  assert(value.fixtureRoot.endsWith(`/functional-fixture-${value.session}`));
  assert.equal(
    value.hostIdentifier,
    `com.pulkit.edith.tests.worker-${value.session}`,
  );
  assert.equal(value.home, `${value.fixtureRoot}/${value.owner}-home`);
  path(value.dataDirectory, value.fixtureRoot);
  assert.equal(value.hostABI, "edith-host-2");
  assert.equal(value.caseSHA256, functionalDigest(definition));
  assert.equal(value.activationOperation, definition.activation.operation);
  assert(phases.includes(value.phase));
  assert(
    ["synthetic-development", "public-signed-pair"].includes(value.pairScope),
  );
  increasingVersion(value.previousVersion, value.currentVersion);
  if (value.pairScope === "synthetic-development") {
    assert.equal(value.previousVersion, "1.0.0");
    assert.equal(value.currentVersion, "1.1.0");
  }
  assert.equal(
    value.version,
    value.phase === "initial" ? value.previousVersion : value.currentVersion,
  );
  assert.match(value.packageSHA256, hash);
  identity(value.engine, value.uid);
  identity(value.ui, value.uid);
  assert.notEqual(value.engine.pid, value.ui.pid);
  assert.deepEqual(value.operations, definition.operations);
  assert(value.ownedPaths.length >= 1 && value.ownedPaths.length <= 32);
  const names = new Set(),
    paths = new Set();
  for (const entry of value.ownedPaths) {
    keys(entry, ["name", "path", "kind"]);
    text(entry.name);
    path(entry.path, value.fixtureRoot);
    assert(["file", "directory"].includes(entry.kind));
    assert(!names.has(entry.name) && !paths.has(entry.path));
    names.add(entry.name);
    paths.add(entry.path);
  }
  return value;
}

export function validateFunctionalRequest(request, capability) {
  keys(request, [
    "schema",
    "sourceCommit",
    "session",
    "owner",
    "phase",
    "capabilitySHA256",
    "requestID",
    "operation",
    "payloadSHA256",
  ]);
  assert.equal(request.schema, 1);
  for (const key of ["sourceCommit", "session", "owner", "phase"])
    assert.equal(request[key], capability[key]);
  assert.equal(request.capabilitySHA256, functionalDigest(capability));
  assert.match(request.requestID, uuid);
  assert(
    capability.operations.includes(request.operation),
    "Unadmitted functional operation",
  );
  assert.match(request.payloadSHA256, hash);
  return request;
}

function mutationPayload(encoded, request, fields) {
  assert(typeof encoded === "string" && encoded.length <= 1_398_104);
  const bytes = Buffer.from(encoded, "base64");
  assert(bytes.length > 0 && bytes.length <= 1_048_576);
  assert.equal(bytes.toString("base64"), encoded);
  assert.equal(
    createHash("sha256").update(bytes).digest("hex"),
    request.payloadSHA256,
  );
  const payload = uniqueJSON(bytes.toString("utf8"));
  if (fields !== undefined) keys(payload, fields);
  return payload;
}

export function validateFunctionalMutationJournal(
  envelope,
  capability,
  definition,
  issuer,
  stage,
  admittedPresentationID,
) {
  assert.match(admittedPresentationID, uuid);
  const journal = verifyFunctionalEnvelope(envelope, issuer);
  keys(journal, [
    "schema",
    "sourceCommit",
    "session",
    "owner",
    "phase",
    "capabilitySHA256",
    "presentationID",
    "baseline",
    "loadSequence",
    "records",
    "sealedThroughSequence",
  ]);
  assert.equal(journal.schema, 1);
  for (const field of ["sourceCommit", "session", "owner", "phase"])
    assert.equal(journal[field], capability[field]);
  assert.equal(journal.capabilitySHA256, functionalDigest(capability));
  assert.equal(journal.presentationID, admittedPresentationID);
  const baseline = journal.baseline;
  keys(baseline, [
    "reader",
    "observationID",
    "sequence",
    "readbackSHA256",
    "expectedSHA256",
  ]);
  assert.equal(baseline.reader, "independent-hosted-producer");
  assert.match(baseline.observationID, uuid);
  positiveSequence(baseline.sequence);
  positiveSequence(journal.loadSequence);
  assert(baseline.sequence < journal.loadSequence);
  if (definition.persistence.applicable) {
    assert.match(baseline.readbackSHA256, hash);
    assert.equal(baseline.expectedSHA256, baseline.readbackSHA256);
  } else {
    assert.equal(baseline.readbackSHA256, null);
    assert.equal(baseline.expectedSHA256, null);
  }
  assert(
    Array.isArray(journal.records) &&
      journal.records.length > 0 &&
      journal.records.length <= 128,
  );
  const identifiers = new Set([baseline.observationID]);
  let sequence = journal.loadSequence;
  let selected;
  for (const record of journal.records) {
    keys(record, [
      "request",
      "activationID",
      "origin",
      "ui",
      "engine",
      "payload",
      "sendSequence",
      "acknowledgement",
      "transition",
    ]);
    validateFunctionalRequest(record.request, capability);
    assert(
      !record.request.operation
        .split(".")
        .some((part) =>
          [
            "read",
            "snapshot",
            "state",
            "list",
            "schema",
            "get",
            "poll",
          ].includes(part),
        ),
    );
    assert(!identifiers.has(record.request.requestID));
    identifiers.add(record.request.requestID);
    assert.match(record.activationID, uuid);
    assert.equal(record.origin, "authenticated-original-control");
    assert.deepEqual(record.ui, capability.ui);
    assert.deepEqual(record.engine, capability.engine);
    mutationPayload(
      record.payload,
      record.request,
      record.request.operation === definition.activation.operation
        ? definition.activation.mutation.payloadKeys
        : undefined,
    );
    positiveSequence(record.sendSequence);
    const ack = record.acknowledgement;
    keys(ack, ["request", "engine", "success", "responseSHA256", "sequence"]);
    assert.deepEqual(ack.request, record.request);
    assert.deepEqual(ack.engine, capability.engine);
    assert.equal(ack.success, true);
    assert.match(ack.responseSHA256, hash);
    positiveSequence(ack.sequence);
    assert(record.sendSequence < ack.sequence);
    const transition = record.transition;
    keys(transition, [
      "kind",
      "reader",
      "capabilitySHA256",
      "requestID",
      "before",
      "after",
    ]);
    assert(["state-transition", "owned-output"].includes(transition.kind));
    assert.equal(transition.reader, "independent-hosted-producer");
    assert.equal(transition.capabilitySHA256, journal.capabilitySHA256);
    assert.equal(transition.requestID, record.request.requestID);
    for (const observation of [transition.before, transition.after]) {
      keys(observation, [
        "observationID",
        "sequence",
        "observationSHA256",
        "expectedSHA256",
      ]);
      assert.match(observation.observationID, uuid);
      assert(!identifiers.has(observation.observationID));
      identifiers.add(observation.observationID);
      positiveSequence(observation.sequence);
      assert.match(observation.observationSHA256, hash);
      assert.equal(observation.expectedSHA256, observation.observationSHA256);
    }
    assert(sequence < transition.before.sequence);
    assert(transition.before.sequence < record.sendSequence);
    assert(ack.sequence < transition.after.sequence);
    sequence = transition.after.sequence;
    if (record.request.requestID === stage.activation.request.requestID) {
      assert.equal(selected, undefined);
      selected = record;
    }
  }
  positiveSequence(journal.sealedThroughSequence);
  assert(journal.sealedThroughSequence > sequence);
  assert(journal.sealedThroughSequence >= stage.persistence.sequence);
  assert(
    selected,
    "Selected original action must belong to the admitted mutation journal",
  );
  assert.deepEqual(selected.request, stage.activation.request);
  assert.equal(selected.payload, stage.activation.payload);
  assert.equal(selected.sendSequence, stage.activation.sequence);
  assert.deepEqual(selected.acknowledgement, stage.acknowledgement);
  assert.deepEqual(selected.transition, stage.transition);
  assert.equal(selected.transition.kind, definition.activation.mutation.kind);
  assert.equal(
    selected,
    journal.records.at(-1),
    "Final selected action must close the mutation journal",
  );
  return journal;
}

export function validateFunctionalActionProof(
  proof,
  definition,
  signedObservation,
  compiledIssuerPublicKeyDER,
  admittedPublicPair,
  admittedPresentations,
) {
  validateFunctionalCaseDefinition(definition);
  const observed = verifyFunctionalEnvelope(
    signedObservation,
    compiledIssuerPublicKeyDER,
  );
  keys(observed, [
    "schema",
    "authority",
    "execution",
    "sourceCommit",
    "session",
    "owner",
    "uid",
    "caseSHA256",
    "stages",
    "packagePair",
    "naturalExit",
    "removal",
    "agenticSentinels",
  ]);
  assert.equal(observed.schema, 1);
  assert.equal(observed.authority, "independent-hosted-producer");
  assert.equal(observed.execution, "hosted-macos-native");
  assert.equal(observed.owner, definition.owner);
  assert.equal(observed.caseSHA256, functionalDigest(definition));
  keys(proof, [
    "schema",
    "sourceCommit",
    "session",
    "owner",
    "caseSHA256",
    "stages",
  ]);
  assert.equal(proof.schema, 1);
  for (const key of ["sourceCommit", "session", "owner", "caseSHA256"])
    assert.equal(proof[key], observed[key]);
  keys(admittedPresentations, [
    "sourceCommit",
    "session",
    "owner",
    "caseSHA256",
    "presentations",
  ]);
  for (const field of ["sourceCommit", "session", "owner", "caseSHA256"])
    assert.equal(admittedPresentations[field], observed[field]);
  keys(admittedPresentations.presentations, phases);
  for (const presentation of Object.values(admittedPresentations.presentations))
    assert.match(presentation, uuid);
  assert.equal(
    new Set(Object.values(admittedPresentations.presentations)).size,
    3,
  );
  assert.equal(observed.stages.length, 3);
  assert.equal(proof.stages.length, 3);
  const requests = new Set(),
    processes = new Set();
  for (let index = 0; index < phases.length; index++) {
    const stage = observed.stages[index],
      claim = proof.stages[index];
    keys(stage, [
      "capability",
      "admission",
      "activation",
      "acknowledgement",
      "authoritative",
      "retired",
      "persistence",
      "transition",
      "mutationJournal",
    ]);
    const capability = validateFunctionalCapability(
      stage.capability,
      definition,
    );
    assert.equal(capability.phase, phases[index]);
    for (const peer of [capability.engine, capability.ui]) {
      assert(!processes.has(peer.pid), "Captured process PID reused");
      processes.add(peer.pid);
    }
    for (const key of ["sourceCommit", "session", "owner", "uid", "caseSHA256"])
      assert.equal(capability[key], observed[key]);
    if (index > 0) {
      const before = observed.stages[index - 1].capability;
      for (const key of [
        "fixtureRoot",
        "hostIdentifier",
        "home",
        "dataDirectory",
        "hostABI",
        "pairScope",
        "previousVersion",
        "currentVersion",
      ])
        assert.equal(capability[key], before[key]);
      differentGeneration(before.engine, capability.engine);
      differentGeneration(before.ui, capability.ui);
      assert.deepEqual(stage.retired, [before.engine, before.ui]);
      if (index === 1)
        assert.notEqual(capability.packageSHA256, before.packageSHA256);
      else assert.equal(capability.packageSHA256, before.packageSHA256);
    } else assert.deepEqual(stage.retired, []);
    keys(stage.admission, [
      "heldRootPinned",
      "heldDescriptorPinned",
      "sourceClean",
      "sourcePinned",
      "payloadSignatureVerified",
      "architectureVerified",
      "hostABIVerified",
      "originalFactoryUnchanged",
      "originalControlsUnchanged",
      "staleGenerationRejected",
    ]);
    for (const result of Object.values(stage.admission))
      assert.equal(result, true);
    keys(stage.activation, [
      "kind",
      "control",
      "operation",
      "sources",
      "ui",
      "request",
      "payload",
      "sequence",
      "mutation",
    ]);
    assert.equal(stage.activation.kind, definition.activation.kind);
    assert.equal(stage.activation.control, definition.activation.control);
    assert.equal(stage.activation.operation, definition.activation.operation);
    assert.deepEqual(stage.activation.sources, definition.activation.sources);
    assert.deepEqual(stage.activation.mutation, definition.activation.mutation);
    assert.deepEqual(stage.activation.ui, capability.ui);
    validateFunctionalRequest(stage.activation.request, capability);
    assert.equal(
      stage.activation.request.operation,
      definition.activation.operation,
    );
    assert(!requests.has(stage.activation.request.requestID));
    requests.add(stage.activation.request.requestID);
    mutationPayload(
      stage.activation.payload,
      stage.activation.request,
      definition.activation.mutation.payloadKeys,
    );
    const journal = validateFunctionalMutationJournal(
      stage.mutationJournal,
      capability,
      definition,
      compiledIssuerPublicKeyDER,
      stage,
      admittedPresentations.presentations[capability.phase],
    );
    positiveSequence(stage.activation.sequence);
    keys(stage.acknowledgement, [
      "request",
      "engine",
      "success",
      "responseSHA256",
      "sequence",
    ]);
    assert.deepEqual(stage.acknowledgement.request, stage.activation.request);
    assert.deepEqual(stage.acknowledgement.engine, capability.engine);
    assert.equal(stage.acknowledgement.success, true);
    assert.match(stage.acknowledgement.responseSHA256, hash);
    positiveSequence(stage.acknowledgement.sequence);
    assert(stage.acknowledgement.sequence > stage.activation.sequence);
    keys(stage.authoritative, [
      "kind",
      "name",
      "reader",
      "observationID",
      "afterAcknowledgement",
      "observationSHA256",
      "expectedSHA256",
      "sequence",
    ]);
    assert.equal(stage.authoritative.kind, definition.observation.kind);
    assert.equal(stage.authoritative.name, definition.observation.name);
    assert.equal(stage.authoritative.reader, "independent-hosted-producer");
    assert.match(stage.authoritative.observationSHA256, hash);
    assert.equal(
      stage.authoritative.observationSHA256,
      stage.authoritative.expectedSHA256,
    );
    assert.match(stage.authoritative.observationID, uuid);
    assert(!requests.has(stage.authoritative.observationID));
    requests.add(stage.authoritative.observationID);
    assert.equal(stage.authoritative.afterAcknowledgement, true);
    positiveSequence(stage.authoritative.sequence);
    assert(stage.authoritative.sequence > stage.acknowledgement.sequence);
    keys(stage.transition, [
      "kind",
      "reader",
      "capabilitySHA256",
      "requestID",
      "before",
      "after",
    ]);
    assert.equal(stage.transition.kind, definition.activation.mutation.kind);
    assert.equal(stage.transition.reader, "independent-hosted-producer");
    assert.equal(
      stage.transition.capabilitySHA256,
      functionalDigest(capability),
    );
    assert.equal(
      stage.transition.requestID,
      stage.activation.request.requestID,
    );
    for (const [name, record] of Object.entries({
      before: stage.transition.before,
      after: stage.transition.after,
    })) {
      keys(record, [
        "observationID",
        "sequence",
        "observationSHA256",
        "expectedSHA256",
      ]);
      assert.match(record.observationID, uuid);
      assert(!requests.has(record.observationID));
      requests.add(record.observationID);
      assert.match(record.observationSHA256, hash);
      assert.equal(record.observationSHA256, record.expectedSHA256);
      positiveSequence(record.sequence);
      assert(
        name === "before"
          ? record.sequence < stage.activation.sequence
          : record.sequence > stage.acknowledgement.sequence,
      );
    }
    assert.notEqual(
      stage.transition.before.observationSHA256,
      stage.transition.after.observationSHA256,
      "An independently observed action effect is required",
    );
    assert.equal(
      stage.transition.after.observationSHA256,
      stage.authoritative.observationSHA256,
    );
    keys(stage.persistence, [
      "name",
      "readbackSHA256",
      "expectedSHA256",
      "beforeActivation",
      "sequence",
    ]);
    positiveSequence(stage.persistence.sequence);
    assert(stage.persistence.sequence > stage.authoritative.sequence);
    assert.equal(stage.persistence.name, definition.persistence.name);
    if (definition.persistence.applicable) {
      assert.match(stage.persistence.readbackSHA256, hash);
      assert.equal(
        stage.persistence.readbackSHA256,
        stage.persistence.expectedSHA256,
      );
      if (index > 0) {
        assert.equal(
          stage.persistence.readbackSHA256,
          observed.stages[0].persistence.readbackSHA256,
        );
        const prior = stage.persistence.beforeActivation;
        keys(prior, [
          "reader",
          "observationID",
          "capabilitySHA256",
          "engine",
          "ui",
          "beforeRequestID",
          "sequence",
          "readbackSHA256",
          "expectedSHA256",
        ]);
        assert.equal(prior.reader, "independent-hosted-producer");
        assert.match(prior.observationID, uuid);
        assert(!requests.has(prior.observationID));
        requests.add(prior.observationID);
        assert.equal(prior.capabilitySHA256, functionalDigest(capability));
        assert.deepEqual(prior.engine, capability.engine);
        assert.deepEqual(prior.ui, capability.ui);
        assert.equal(
          prior.beforeRequestID,
          journal.records[0].request.requestID,
        );
        for (const field of [
          "reader",
          "observationID",
          "sequence",
          "readbackSHA256",
          "expectedSHA256",
        ])
          assert.equal(prior[field], journal.baseline[field]);
        positiveSequence(prior.sequence);
        assert(prior.sequence < journal.loadSequence);
        assert.equal(
          prior.readbackSHA256,
          observed.stages[0].persistence.readbackSHA256,
        );
        assert.equal(prior.expectedSHA256, prior.readbackSHA256);
      } else assert.equal(stage.persistence.beforeActivation, null);
    } else {
      assert.equal(stage.persistence.readbackSHA256, null);
      assert.equal(stage.persistence.expectedSHA256, null);
      assert.equal(stage.persistence.beforeActivation, null);
    }
    keys(claim, [
      "phase",
      "requestID",
      "capabilitySHA256",
      "observationSHA256",
    ]);
    assert.equal(claim.phase, capability.phase);
    assert.equal(claim.requestID, stage.activation.request.requestID);
    assert.equal(claim.capabilitySHA256, functionalDigest(capability));
    assert.equal(
      claim.observationSHA256,
      stage.authoritative.observationSHA256,
    );
  }
  const first = observed.stages[0].capability,
    current = observed.stages[1].capability;
  keys(observed.packagePair, [
    "scope",
    "previous",
    "current",
    "publicAdmissionSHA256",
  ]);
  assert.equal(observed.packagePair.scope, first.pairScope);
  for (const [name, cap] of [
    ["previous", first],
    ["current", current],
  ]) {
    keys(observed.packagePair[name], ["version", "packageSHA256"]);
    assert.equal(observed.packagePair[name].version, cap.version);
    assert.equal(observed.packagePair[name].packageSHA256, cap.packageSHA256);
  }
  if (first.pairScope === "public-signed-pair") {
    assert.match(observed.packagePair.publicAdmissionSHA256, hash);
    keys(admittedPublicPair, [
      "owner",
      "sourceCommit",
      "previous",
      "current",
      "receiptSHA256",
    ]);
    assert.equal(admittedPublicPair.owner, observed.owner);
    assert.equal(admittedPublicPair.sourceCommit, observed.sourceCommit);
    assert.equal(
      admittedPublicPair.receiptSHA256,
      observed.packagePair.publicAdmissionSHA256,
    );
    assert.deepEqual(
      admittedPublicPair.previous,
      observed.packagePair.previous,
    );
    assert.deepEqual(admittedPublicPair.current, observed.packagePair.current);
  } else {
    assert.equal(observed.packagePair.publicAdmissionSHA256, null);
    assert.equal(admittedPublicPair, undefined);
  }
  const versions = [first.version, current.version];
  keys(observed.naturalExit, ["cleanupStarted", "captured", "absent"]);
  assert.equal(observed.naturalExit.cleanupStarted, false);
  const captured = observed.stages.flatMap(({ capability }) => [
    capability.engine,
    capability.ui,
  ]);
  assert.deepEqual(observed.naturalExit.captured, captured);
  assert.deepEqual(observed.naturalExit.absent, captured);
  keys(observed.removal, [
    "capturedVersions",
    "physicallyAbsentBeforeReinstall",
    "finalPhysicallyAbsent",
    "leasesReleased",
  ]);
  assert.deepEqual(observed.removal.capturedVersions, versions);
  assert.deepEqual(observed.removal.physicallyAbsentBeforeReinstall, versions);
  assert.deepEqual(observed.removal.finalPhysicallyAbsent, versions);
  assert.equal(observed.removal.leasesReleased, true);
  keys(observed.agenticSentinels, ["beforeSHA256", "afterSHA256"]);
  assert.match(observed.agenticSentinels.beforeSHA256, hash);
  assert.equal(
    observed.agenticSentinels.beforeSHA256,
    observed.agenticSentinels.afterSHA256,
  );
  return Object.freeze({
    schema: 1,
    owner: observed.owner,
    sourceCommit: observed.sourceCommit,
    session: observed.session,
    functionalActionsValidated: true,
    activationKind: definition.activation.kind,
    actionDeliveryScope: "source-original-control-to-installed-engine",
    downloadedUIBinaryActionsValidated: false,
    packagePairScope: first.pairScope,
    publicUpdateValidated: first.pairScope === "public-signed-pair",
    scope: [...definition.limits],
    nativeHardwareValidated: false,
    privilegedShippingRoleValidated: false,
  });
}

function positiveSequence(value) {
  assert(Number.isSafeInteger(value) && value > 0);
}

function uniqueJSON(value) {
  const result = JSON.parse(value);
  assert(result && typeof result === "object" && !Array.isArray(result));
  const tree = parseExpression(value);
  function visit(node) {
    if (node.type === "ObjectExpression") {
      const fields = node.properties.map((property) => property.key.value);
      assert.equal(
        new Set(fields).size,
        fields.length,
        "Duplicate payload key",
      );
      for (const property of node.properties) visit(property.value);
    } else if (node.type === "ArrayExpression") {
      for (const entry of node.elements) visit(entry);
    }
  }
  visit(tree);
  return result;
}
