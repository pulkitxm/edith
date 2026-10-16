import assert from "node:assert/strict";
import { createHash, generateKeyPairSync, sign } from "node:crypto";
import test from "node:test";
import { functionalCanonicalJSON, functionalDigest } from "./contract.mjs";
import {
  validateFunctionalCalendarJournal,
  validateFunctionalCalendarSnapshot,
} from "./shared-proof.mjs";

const sourceCommit = "a".repeat(40);
const session = "00000000-0000-4000-8000-000000000001";
const definition = {
  owner: "calendar",
  activation: { kind: "original-calendar-details", operation: null },
  observation: { kind: "checked-engine-readback", name: "calendar-events" },
};
const phases = ["initial", "updated", "reinstalled"];
const key = generateKeyPairSync("ed25519");
const issuer = key.publicKey.export({ format: "der", type: "spki" });
const id = (n) => `00000000-0000-4000-8000-${String(n).padStart(12, "0")}`;
const sha = (bytes) => createHash("sha256").update(bytes).digest("hex");
const seal = (object) => {
  const payload = functionalCanonicalJSON(object);
  return {
    schema: 1,
    payload,
    signature: sign(null, Buffer.from(payload), key.privateKey).toString(
      "base64",
    ),
  };
};
const peer = (n) => ({
  pid: n,
  birthSeconds: n + 1000,
  birthMicroseconds: 42,
  uid: 501,
  executableSHA256: "b".repeat(64),
});

function fixture(index = 0, interleaved = false, startup = false) {
  const offset = index * 100;
  const delta = startup ? 1 : 0;
  const phase = phases[index];
  const presentationID = id(2 + offset);
  const capability = {
    schema: 1,
    sourceCommit,
    session,
    owner: "calendar",
    uid: 501,
    phase,
    fixtureRoot: `/synthetic/functional-fixture-${session}`,
    caseSHA256: "c".repeat(64),
    activationOperation: null,
    engine: peer(100 + offset),
    ui: peer(101 + offset),
    operations: [
      "calendar.ui.metadata",
      "calendar.ui.list",
      "calendar.ui.loadMore",
    ],
  };
  const actor = {
    ...peer(102 + offset),
    executable: `${capability.fixtureRoot}/XCTest/Runner`,
  };
  const host = peer(103);
  const step = {
    role: "button",
    label: "Show event details",
    selector: "help",
    action: "click",
    value: null,
  };
  const context = {
    presentationID,
    actor,
    host,
    sourceSHA256: "d".repeat(64),
    recipeSHA256: "e".repeat(64),
    step,
    stepSHA256: functionalDigest({
      ...step,
      scope: {
        kind: "window",
        label: `Synthetic functional calendar ${phase} ${session}`,
      },
      ownedPath: null,
    }),
  };
  const actionID = id(70 + offset);
  const provider = Buffer.from(
    '{"events":[{"notes":"Synthetic agenda notes","title":"Synthetic meeting","id":"synthetic-calendar-meeting"}],"blurEvents":false,"authorized":true}',
  );
  const payload = Buffer.from("{}");
  const beforeSequence = (interleaved ? 8 : 10 + delta) + offset;
  const authorizeSequence = (interleaved ? 10 : 11 + delta) + offset;
  const completionSequence = 15 + delta + offset;
  const snapshot = (labels) => {
    const value = {
      schema: 1,
      kind: "calendar-details",
      visibleStaticTexts: labels,
    };
    const bytes = Buffer.from(functionalCanonicalJSON(value));
    return { bytes: bytes.toString("base64"), sha256: sha(bytes) };
  };
  const action = {
    authorizationID: actionID,
    actor,
    sourceSHA256: context.sourceSHA256,
    stepIndex: 0,
    stepSHA256: context.stepSHA256,
    before: {
      visibleControl: snapshot(["Synthetic meeting"]),
      backend: {
        observationID: id(20 + offset),
        sequence: beforeSequence,
        bytes: provider.toString("base64"),
        sha256: sha(provider),
      },
    },
    after: {
      visibleControl: snapshot([
        "Synthetic meeting",
        "Notes",
        "Synthetic agenda notes",
      ]),
      backend: {
        observationID: id(21 + offset),
        sequence: 14 + delta + offset,
        bytes: provider.toString("base64"),
        sha256: sha(provider),
      },
    },
  };
  function boundary(completion) {
    return seal({
      schema: 1,
      sourceCommit,
      session,
      owner: "calendar",
      phase,
      requestID: id((completion ? 73 : 72) + offset),
      operation: completion
        ? "complete-original-step"
        : "authorize-original-step",
      authorizationID: actionID,
      actor,
      stepIndex: 0,
      stepSHA256: context.stepSHA256,
      sourceSHA256: context.sourceSHA256,
      presentationID,
      capabilitySHA256: functionalDigest(capability),
      firstEventOrdinal: authorizeSequence,
      lastEventOrdinal: completion ? completionSequence : authorizeSequence,
      localControlSHA256: completion
        ? action.after.visibleControl.sha256
        : action.before.visibleControl.sha256,
    });
  }
  action.authorization = boundary(false);
  action.completion = boundary(true);
  const uiRequests = [
    "before-original-request",
    "before-engine-receiver",
    "after-engine-receiver",
    "after-original-response",
    "native-emitted-reply",
  ].map((event, ordinal) => ({
    ordinal,
    sequence: (interleaved ? [3, 5, 7, 9, 11][ordinal] : ordinal + 3) + offset,
    activationID: interleaved && ordinal > 0 ? actionID : null,
    stepIndex: interleaved && ordinal > 0 ? 0 : null,
    payload: ordinal === 0 ? payload.toString("base64") : null,
    response: null,
    event,
    token: id(10 + offset),
    operation: "calendar.ui.list",
    presentationID,
    payloadSHA256: sha(payload),
    responseSHA256: ordinal < 2 ? null : sha(provider),
    caller: ordinal === 1 || ordinal === 2 ? capability.engine : host,
    outcome: ordinal < 2 ? null : true,
  }));
  const reads = (after) =>
    [0, 1].map((ordinal) => ({
      ordinal,
      sequence:
        (after
          ? ordinal + 12 + delta
          : interleaved
            ? [4, 6][ordinal]
            : ordinal + 8 + delta) + offset,
      event: ordinal === 0 ? "before-engine-receiver" : "after-engine-receiver",
      token: id((after ? 81 : 80) + offset),
      operation: "calendar.ui.list",
      presentationID,
      caller: capability.engine,
      source: host,
      receiver: capability.engine,
      payload: payload.toString("base64"),
      payloadSHA256: sha(payload),
      response: ordinal === 0 ? null : provider.toString("base64"),
      responseSHA256: ordinal === 0 ? null : sha(provider),
      outcome: ordinal === 0 ? null : true,
    }));
  context.readonlyJournal = {
    uiRequests,
    before: reads(false),
    after: reads(true),
  };
  const transition = (observation) => ({
    observationID: observation.backend.observationID,
    sequence: observation.backend.sequence,
    observationSHA256: observation.visibleControl.sha256,
    expectedSHA256: observation.visibleControl.sha256,
  });
  const stage = {
    capability,
    localControl: {
      kind: "original-calendar-details",
      actionID,
      actor,
      sourceSHA256: context.sourceSHA256,
      recipeSHA256: context.recipeSHA256,
      stepSHA256: context.stepSHA256,
      authorization: action.authorization,
      completion: action.completion,
    },
    transition: {
      kind: "original-calendar-details",
      reader: "independent-hosted-producer",
      capabilitySHA256: functionalDigest(capability),
      actionID,
      before: transition(action.before),
      after: transition(action.after),
    },
    authoritative: {
      ...definition.observation,
      reader: "independent-hosted-producer",
      observationID: id(23 + offset),
      afterCompletion: true,
      observationSHA256: action.after.visibleControl.sha256,
      expectedSHA256: action.after.visibleControl.sha256,
      sequence: 16 + delta + offset,
    },
    persistence: {
      name: "no-owned-persistent-record",
      readbackSHA256: null,
      expectedSHA256: null,
      beforeActivation: null,
      sequence: 17 + delta + offset,
    },
  };
  const journal = {
    schema: 1,
    kind: "authenticated-original-local-control",
    sourceCommit,
    session,
    owner: "calendar",
    phase,
    capabilitySHA256: functionalDigest(capability),
    presentationID,
    baseline: {
      reader: "independent-hosted-producer",
      observationID: id(22 + offset),
      sequence: 1 + offset,
      readbackSHA256: null,
      expectedSHA256: null,
    },
    loadSequence: (startup ? 8 : 2) + offset,
    action,
    sealedThroughSequence: stage.persistence.sequence,
  };
  return { capability, context, stage, journal };
}

function validate(f, identifiers = new Set(), sequences = new Set()) {
  const admission = {
    schema: 1,
    sourceCommit,
    session,
    owner: "calendar",
    caseSHA256: f.capability.caseSHA256,
    rolePolicySHA256: "f".repeat(64),
    phases: Object.fromEntries(phases.map((phase) => [phase, f.context])),
  };
  return validateFunctionalCalendarJournal(
    seal(f.journal),
    f.capability,
    definition,
    issuer,
    f.stage,
    f.context.presentationID,
    seal(admission),
    identifiers,
    sequences,
  );
}

function rebind(f, which, edit) {
  const changed = JSON.parse(f.journal.action[which].payload);
  edit(changed);
  f.journal.action[which] = seal(changed);
  f.stage.localControl[which] = f.journal.action[which];
}

test("Calendar signed local receipts preserve ordinary five events and independent two event reads across all phases", () => {
  for (const [interleaved, startup] of [
    [false, false],
    [true, false],
    [false, true],
  ]) {
    const identifiers = new Set(),
      sequences = new Set();
    for (let index = 0; index < 3; index++) {
      const f = fixture(index, interleaved, startup);
      assert.equal(f.context.readonlyJournal.uiRequests.length, 5);
      assert.equal(f.context.readonlyJournal.before.length, 2);
      assert.equal(f.context.readonlyJournal.after.length, 2);
      assert.equal(
        validate(f, identifiers, sequences).sealedThroughSequence,
        f.stage.persistence.sequence,
      );
    }
  }
});

test("Calendar refuses cross-stream global collisions, reused read tokens and incoherent seals", () => {
  const edits = [
    (f) =>
      f.context.readonlyJournal.uiRequests.forEach((row, index) => {
        row.sequence = index + 8;
      }),
    (f) => {
      f.context.readonlyJournal.before[0].sequence =
        f.journal.action.before.backend.sequence;
    },
    (f) => {
      f.context.readonlyJournal.after[0].sequence = 11;
    },
    (f) =>
      f.context.readonlyJournal.after.forEach((row) => {
        row.token = f.context.readonlyJournal.before[0].token;
      }),
    (f) =>
      f.context.readonlyJournal.before.forEach((row) => {
        row.token = f.context.readonlyJournal.uiRequests[0].token;
      }),
    (f) => {
      f.journal.sealedThroughSequence = f.stage.persistence.sequence - 1;
    },
    (f) => {
      f.context.readonlyJournal.after.pop();
    },
    (f) => {
      f.context.readonlyJournal.before[1].response =
        Buffer.from("{}").toString("base64");
    },
    (f) => {
      f.context.readonlyJournal.uiRequests[4].caller = f.capability.ui;
    },
    (f) => {
      f.context.readonlyJournal.uiRequests[4].activationID = id(999);
      f.context.readonlyJournal.uiRequests[4].stepIndex = 0;
    },
    (f) => {
      f.capability.activationOperation = "calendar.ui.list";
    },
    (f) => {
      f.context.stepSHA256 = functionalDigest(f.context.step);
    },
    (f) =>
      rebind(f, "completion", (reply) => {
        reply.lastEventOrdinal = 14;
      }),
    (f) =>
      rebind(f, "completion", (reply) => {
        reply.localControlSHA256 = "0".repeat(64);
      }),
  ];
  for (const edit of edits) {
    const f = fixture();
    edit(f);
    assert.throws(() => validate(f));
  }
  const sequences = new Set();
  validate(fixture(0), new Set(), sequences);
  assert.throws(() => validate(fixture(0), new Set(), sequences));
});

test("Calendar protocol bounds actual snapshots and authenticates every envelope", () => {
  for (const value of [
    {
      schema: 1,
      kind: "calendar-details",
      visibleStaticTexts: ["x".repeat(4097)],
    },
    { schema: 1, kind: "calendar-details", visibleStaticTexts: ["\u0000"] },
    {
      schema: 1,
      kind: "calendar-details",
      visibleStaticTexts: Array(513).fill("x"),
    },
  ])
    assert.throws(() => validateFunctionalCalendarSnapshot(value));
  const f = fixture();
  f.journal.action.authorization.signature =
    Buffer.alloc(64).toString("base64");
  f.stage.localControl.authorization = f.journal.action.authorization;
  assert.throws(() => validate(f));
});
