import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { isAbsolute, posix } from "node:path";
import { parseExpression } from "@babel/parser";
import {
  functionalCanonicalJSON,
  functionalDigest,
  verifyFunctionalEnvelope,
} from "./contract.mjs";

const uuid =
  /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
const hash = /^[0-9a-f]{64}$/;
const phases = ["initial", "updated", "reinstalled"];
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

export function validateFunctionalCalendarSnapshot(value) {
  keys(value, ["schema", "kind", "visibleStaticTexts"]);
  assert.equal(value.schema, 1);
  assert.equal(value.kind, "calendar-details");
  assert(
    Array.isArray(value.visibleStaticTexts) &&
      value.visibleStaticTexts.length <= 512,
  );
  let total = 0;
  for (const label of value.visibleStaticTexts) {
    assert(typeof label === "string");
    const size = Buffer.byteLength(label);
    assert(size <= 4096);
    total += size;
  }
  assert(total <= 131072);
  assert(Buffer.byteLength(functionalCanonicalJSON(value)) <= 131072);
  assert(value.visibleStaticTexts.every((label) => !label.includes("\u0000")));
  return value;
}

function calendarBytes(value) {
  assert(typeof value === "string" && value.length <= 1398104);
  const bytes = Buffer.from(value, "base64");
  assert(bytes.length > 0 && bytes.length <= 1048576);
  assert.equal(bytes.toString("base64"), value);
  return bytes;
}

function calendarBirth(value, uid) {
  keys(value, [
    "pid",
    "birthSeconds",
    "birthMicroseconds",
    "uid",
    "executable",
    "executableSHA256",
  ]);
  const { executable, ...peer } = value;
  identity(peer, uid);
  path(executable);
  return peer;
}

function calendarReadonlyJournal(
  records,
  capability,
  host,
  presentationID,
  actionID,
  identifiers,
  completionSequence,
) {
  assert(
    Array.isArray(records) && records.length >= 5 && records.length <= 4096,
  );
  const events = [
    "before-original-request",
    "before-engine-receiver",
    "after-engine-receiver",
    "after-original-response",
    "native-emitted-reply",
  ];
  const pending = new Map(),
    completed = new Set();
  let sequence = 0;
  for (const [ordinal, record] of records.entries()) {
    keys(record, [
      "ordinal",
      "sequence",
      "activationID",
      "stepIndex",
      "payload",
      "response",
      "event",
      "token",
      "operation",
      "presentationID",
      "payloadSHA256",
      "responseSHA256",
      "caller",
      "outcome",
    ]);
    assert.equal(record.ordinal, ordinal);
    positiveSequence(record.sequence);
    assert(record.sequence > sequence);
    sequence = record.sequence;
    assert.match(record.token, uuid);
    assert(capability.operations.includes(record.operation));
    assert.equal(record.presentationID, presentationID);
    if (record.activationID === null) assert.equal(record.stepIndex, null);
    else {
      assert.equal(record.activationID, actionID);
      assert.equal(record.stepIndex, 0);
      assert(record.sequence < completionSequence);
    }
    const index = events.indexOf(record.event);
    assert(index >= 0);
    assert.deepEqual(
      record.caller,
      index === 1 || index === 2 ? capability.engine : host,
    );
    assert.match(record.payloadSHA256, hash);
    assert.equal(record.response, null);
    if (index === 0) {
      const payload = calendarBytes(record.payload);
      keys(uniqueJSON(payload.toString("utf8")), []);
      assert.equal(
        createHash("sha256").update(payload).digest("hex"),
        record.payloadSHA256,
      );
      assert(pending.size < 8);
      assert(!pending.has(record.token) && !completed.has(record.token));
      assert(
        !identifiers.has(record.token),
        "Replayed ordinary Calendar request token",
      );
      identifiers.add(record.token);
      pending.set(record.token, {
        index: 0,
        operation: record.operation,
        payloadSHA256: record.payloadSHA256,
        response: null,
      });
    } else assert.equal(record.payload, null);
    const current = pending.get(record.token);
    assert(current && current.index === index);
    assert.equal(current.operation, record.operation);
    assert.equal(current.payloadSHA256, record.payloadSHA256);
    if (index < 2) {
      assert.equal(record.responseSHA256, null);
      assert.equal(record.outcome, null);
    } else {
      assert.equal(record.outcome, true);
      assert.match(record.responseSHA256, hash);
      if (index === 2) current.response = record.responseSHA256;
      else assert.equal(record.responseSHA256, current.response);
    }
    current.index++;
    if (index === 4) {
      pending.delete(record.token);
      completed.add(record.token);
    }
  }
  assert.equal(pending.size, 0);
}

export function validateFunctionalCalendarJournal(
  envelope,
  capability,
  definition,
  issuer,
  stage,
  presentationID,
  admissionEnvelope,
  identifiers = new Set(),
  eventSequences = new Set(),
) {
  assert.equal(definition.owner, "calendar");
  assert.equal(definition.activation.kind, "original-calendar-details");
  assert.equal(definition.activation.operation, null);
  assert.equal(capability.activationOperation, null);
  assert.deepEqual(capability.operations, [
    "calendar.ui.metadata",
    "calendar.ui.list",
    "calendar.ui.loadMore",
  ]);
  const admission = verifyFunctionalEnvelope(admissionEnvelope, issuer);
  keys(admission, [
    "schema",
    "sourceCommit",
    "session",
    "owner",
    "caseSHA256",
    "rolePolicySHA256",
    "phases",
  ]);
  assert.equal(admission.schema, 1);
  for (const name of ["sourceCommit", "session", "owner", "caseSHA256"])
    assert.equal(admission[name], capability[name]);
  assert.match(admission.rolePolicySHA256, hash);
  keys(admission.phases, phases);
  const context = admission.phases[capability.phase];
  keys(context, [
    "presentationID",
    "actor",
    "host",
    "sourceSHA256",
    "recipeSHA256",
    "stepSHA256",
    "step",
    "readonlyJournal",
  ]);
  assert.equal(context.presentationID, presentationID);
  calendarBirth(context.actor, capability.uid);
  assert(
    context.actor.executable.startsWith(`${capability.fixtureRoot}/XCTest/`),
  );
  identity(context.host, capability.uid);
  for (const name of ["sourceSHA256", "recipeSHA256", "stepSHA256"])
    assert.match(context[name], hash);
  assert.deepEqual(context.step, {
    role: "button",
    label: "Show event details",
    selector: "help",
    action: "click",
    value: null,
  });
  assert.equal(
    context.stepSHA256,
    functionalDigest({
      ...context.step,
      scope: {
        kind: "window",
        label: `Synthetic functional calendar ${capability.phase} ${capability.session}`,
      },
      ownedPath: null,
    }),
  );
  const journal = verifyFunctionalEnvelope(envelope, issuer);
  keys(journal, [
    "schema",
    "kind",
    "sourceCommit",
    "session",
    "owner",
    "phase",
    "capabilitySHA256",
    "presentationID",
    "baseline",
    "loadSequence",
    "action",
    "sealedThroughSequence",
  ]);
  assert.equal(journal.kind, "authenticated-original-local-control");
  assert.equal(journal.schema, 1);
  for (const name of ["sourceCommit", "session", "owner", "phase"])
    assert.equal(journal[name], capability[name]);
  assert.equal(journal.capabilitySHA256, functionalDigest(capability));
  assert.equal(journal.presentationID, presentationID);
  keys(journal.baseline, [
    "reader",
    "observationID",
    "sequence",
    "readbackSHA256",
    "expectedSHA256",
  ]);
  assert.equal(journal.baseline.reader, "independent-hosted-producer");
  assert.equal(journal.baseline.readbackSHA256, null);
  assert.equal(journal.baseline.expectedSHA256, null);
  positiveSequence(journal.baseline.sequence);
  positiveSequence(journal.loadSequence);
  assert(journal.baseline.sequence < journal.loadSequence);
  const take = (id) => {
    assert.match(id, uuid);
    assert(!identifiers.has(id), "Replayed Calendar observation or action");
    identifiers.add(id);
  };
  take(journal.baseline.observationID);
  const action = journal.action;
  keys(action, [
    "authorizationID",
    "actor",
    "sourceSHA256",
    "stepIndex",
    "stepSHA256",
    "authorization",
    "completion",
    "before",
    "after",
  ]);
  assert.equal(action.stepIndex, 0);
  const control = stage.localControl;
  keys(control, [
    "kind",
    "actionID",
    "actor",
    "sourceSHA256",
    "recipeSHA256",
    "stepSHA256",
    "authorization",
    "completion",
  ]);
  assert.equal(control.actionID, action.authorizationID);
  for (const name of [
    "actor",
    "sourceSHA256",
    "stepSHA256",
    "authorization",
    "completion",
  ])
    assert.deepEqual(control[name], action[name]);
  assert.equal(control.kind, "original-calendar-details");
  take(control.actionID);
  assert.deepEqual(control.actor, context.actor);
  for (const name of ["sourceSHA256", "recipeSHA256", "stepSHA256"])
    assert.equal(control[name], context[name]);
  const replies = [control.authorization, control.completion].map((value) =>
    verifyFunctionalEnvelope(value, issuer),
  );
  for (const [index, reply] of replies.entries()) {
    keys(reply, [
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
      "localControlSHA256",
    ]);
    assert.equal(reply.schema, 1);
    for (const name of ["sourceCommit", "session", "owner", "phase"])
      assert.equal(reply[name], capability[name]);
    take(reply.requestID);
    assert.equal(
      reply.operation,
      index === 0 ? "authorize-original-step" : "complete-original-step",
    );
    assert.equal(reply.authorizationID, control.actionID);
    assert.deepEqual(reply.actor, context.actor);
    assert.equal(reply.stepIndex, 0);
    assert.equal(reply.stepSHA256, context.stepSHA256);
    assert.equal(reply.sourceSHA256, context.sourceSHA256);
    assert.equal(reply.presentationID, presentationID);
    assert.equal(reply.capabilitySHA256, journal.capabilitySHA256);
    for (const name of ["firstEventOrdinal", "lastEventOrdinal"])
      positiveSequence(reply[name]);
    assert(reply.firstEventOrdinal <= reply.lastEventOrdinal);
  }
  assert.equal(replies[0].firstEventOrdinal, replies[1].firstEventOrdinal);
  assert(replies[0].lastEventOrdinal <= replies[1].lastEventOrdinal);
  const providerValues = [],
    snapshots = [];
  for (const [index, name] of ["before", "after"].entries()) {
    const observation = action[name];
    keys(observation, ["visibleControl", "backend"]);
    keys(observation.visibleControl, ["bytes", "sha256"]);
    const bytes = calendarBytes(observation.visibleControl.bytes);
    const snapshot = validateFunctionalCalendarSnapshot(
      uniqueJSON(bytes.toString("utf8")),
    );
    assert.equal(bytes.toString("utf8"), functionalCanonicalJSON(snapshot));
    assert.equal(functionalDigest(snapshot), observation.visibleControl.sha256);
    assert.equal(
      observation.visibleControl.sha256,
      replies[index].localControlSHA256,
    );
    snapshots.push(snapshot);
    const backend = observation.backend;
    keys(backend, ["observationID", "sequence", "bytes", "sha256"]);
    take(backend.observationID);
    positiveSequence(backend.sequence);
    assert(backend.sequence > journal.loadSequence);
    const providerBytes = calendarBytes(backend.bytes);
    assert.equal(
      createHash("sha256").update(providerBytes).digest("hex"),
      backend.sha256,
    );
    const value = uniqueJSON(providerBytes.toString("utf8"));
    assert.equal(value.authorized, true);
    assert.equal(value.blurEvents, false);
    assert(Array.isArray(value.events) && value.events.length <= 512);
    const events = value.events.filter(
      (event) => event.id === "synthetic-calendar-meeting",
    );
    assert.equal(events.length, 1);
    assert.equal(events[0].notes, "Synthetic agenda notes");
    providerValues.push(events[0]);
    keys(stage.transition[name], [
      "observationID",
      "sequence",
      "observationSHA256",
      "expectedSHA256",
    ]);
    const transition = stage.transition[name];
    assert.equal(transition.observationID, backend.observationID);
    assert.equal(transition.sequence, backend.sequence);
    assert.equal(
      transition.observationSHA256,
      observation.visibleControl.sha256,
    );
    assert.equal(transition.expectedSHA256, transition.observationSHA256);
  }
  assert.deepEqual(providerValues[0], providerValues[1]);
  assert(!snapshots[0].visibleStaticTexts.includes("Synthetic agenda notes"));
  assert.equal(
    snapshots[1].visibleStaticTexts.filter(
      (label) => label === "Synthetic agenda notes",
    ).length,
    1,
  );
  assert(action.before.backend.sequence < action.after.backend.sequence);
  keys(stage.transition, [
    "kind",
    "reader",
    "capabilitySHA256",
    "actionID",
    "before",
    "after",
  ]);
  assert.equal(stage.transition.kind, "original-calendar-details");
  assert.equal(stage.transition.reader, "independent-hosted-producer");
  assert.equal(stage.transition.capabilitySHA256, journal.capabilitySHA256);
  assert.equal(stage.transition.actionID, control.actionID);
  keys(stage.authoritative, [
    "kind",
    "name",
    "reader",
    "observationID",
    "afterCompletion",
    "observationSHA256",
    "expectedSHA256",
    "sequence",
  ]);
  assert.equal(stage.authoritative.kind, definition.observation.kind);
  assert.equal(stage.authoritative.name, definition.observation.name);
  assert.equal(stage.authoritative.reader, "independent-hosted-producer");
  take(stage.authoritative.observationID);
  assert.equal(stage.authoritative.afterCompletion, true);
  assert.equal(
    stage.authoritative.observationSHA256,
    stage.transition.after.observationSHA256,
  );
  assert.equal(
    stage.authoritative.expectedSHA256,
    stage.authoritative.observationSHA256,
  );
  positiveSequence(stage.authoritative.sequence);
  assert(action.before.backend.sequence < replies[0].lastEventOrdinal);
  assert.equal(replies[0].firstEventOrdinal, replies[0].lastEventOrdinal);
  assert(replies[0].lastEventOrdinal < action.after.backend.sequence);
  assert.equal(replies[1].firstEventOrdinal, replies[0].lastEventOrdinal);
  assert(action.after.backend.sequence < replies[1].lastEventOrdinal);
  assert(stage.authoritative.sequence > replies[1].lastEventOrdinal);
  positiveSequence(stage.persistence.sequence);
  assert(stage.persistence.sequence > stage.authoritative.sequence);
  assert.equal(stage.persistence.name, "no-owned-persistent-record");
  assert.equal(stage.persistence.readbackSHA256, null);
  assert.equal(stage.persistence.expectedSHA256, null);
  assert.equal(stage.persistence.beforeActivation, null);
  const occupied = new Set();
  const occupy = (sequence) => {
    positiveSequence(sequence);
    assert(
      !occupied.has(sequence),
      "Distinct Calendar global source event sequence required",
    );
    occupied.add(sequence);
  };
  for (const sequence of [
    journal.baseline.sequence,
    journal.loadSequence,
    action.before.backend.sequence,
    action.after.backend.sequence,
    replies[0].lastEventOrdinal,
    replies[1].lastEventOrdinal,
    stage.authoritative.sequence,
    stage.persistence.sequence,
  ])
    occupy(sequence);
  calendarReadUnion(
    context.readonlyJournal,
    capability,
    context.host,
    presentationID,
    action,
    replies,
    identifiers,
    journal.loadSequence,
    occupy,
  );
  const previous = Math.max(0, ...eventSequences);
  assert(
    [...occupied].every((sequence) => sequence > previous),
    "Replayed Calendar session global source event",
  );
  for (const sequence of occupied) eventSequences.add(sequence);
  positiveSequence(journal.sealedThroughSequence);
  assert(journal.sealedThroughSequence >= stage.persistence.sequence);
  return journal;
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

function calendarReadUnion(
  union,
  capability,
  host,
  presentationID,
  action,
  replies,
  identifiers,
  loadSequence,
  occupy,
) {
  keys(union, ["uiRequests", "before", "after"]);
  calendarReadonlyJournal(
    union.uiRequests,
    capability,
    host,
    presentationID,
    action.authorizationID,
    identifiers,
    replies[1].lastEventOrdinal,
  );
  for (const row of union.uiRequests) occupy(row.sequence);
  let previous = loadSequence;
  for (const [index, name] of ["before", "after"].entries()) {
    const rows = union[name];
    assert(Array.isArray(rows) && rows.length === 2);
    const observation = action[name].backend;
    let token;
    for (const [ordinal, row] of rows.entries()) {
      keys(row, [
        "ordinal",
        "sequence",
        "event",
        "token",
        "operation",
        "presentationID",
        "caller",
        "source",
        "receiver",
        "payload",
        "payloadSHA256",
        "response",
        "responseSHA256",
        "outcome",
      ]);
      assert.equal(row.ordinal, ordinal);
      occupy(row.sequence);
      assert(row.sequence > previous && row.sequence < observation.sequence);
      assert.equal(
        row.event,
        ordinal === 0 ? "before-engine-receiver" : "after-engine-receiver",
      );
      assert.equal(row.operation, "calendar.ui.list");
      assert.equal(row.presentationID, presentationID);
      assert.deepEqual(row.caller, capability.engine);
      assert.deepEqual(row.receiver, capability.engine);
      assert.deepEqual(row.source, host);
      assert.equal(row.payload, Buffer.from("{}").toString("base64"));
      assert.equal(
        row.payloadSHA256,
        createHash("sha256").update("{}").digest("hex"),
      );
      assert.match(row.token, uuid);
      if (ordinal === 0) {
        assert(
          !identifiers.has(row.token),
          "Replayed independent Calendar read token",
        );
        identifiers.add(row.token);
        token = row.token;
        assert.equal(row.response, null);
        assert.equal(row.responseSHA256, null);
        assert.equal(row.outcome, null);
      } else {
        assert.equal(row.token, token);
        assert.equal(row.response, observation.bytes);
        assert.equal(row.responseSHA256, observation.sha256);
        assert.equal(row.outcome, true);
      }
      previous = row.sequence;
    }
    previous = observation.sequence;
    if (index === 1) assert(previous > replies[0].lastEventOrdinal);
  }
}
