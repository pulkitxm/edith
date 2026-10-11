import assert from "node:assert/strict";
import { createHash, generateKeyPairSync, sign } from "node:crypto";
import test from "node:test";
import {
  loadAllFunctionalActionCases,
  loadFunctionalActionCase,
} from "./case-loader.mjs";
import {
  functionalCanonicalJSON,
  functionalDigest,
  validateFunctionalActionProof,
  validateFunctionalCapability,
  validateFunctionalCaseDefinition,
  validateFunctionalMutationJournal,
  validateFunctionalRequest,
  verifyFunctionalEnvelope,
} from "./contract.mjs";
import {
  functionalActionBatches,
  functionalActionCasePaths,
  functionalActionOwners,
  validateFunctionalOwnerInventory,
} from "./owners.mjs";

const digest = (value) => value.repeat(64);
const session = "12345678-1234-4123-8123-123456789abc";
const sourceCommit = "a".repeat(40);
const root = `/private/synthetic/functional-fixture-${session}`;
const keys = generateKeyPairSync("ed25519");
const issuer = keys.publicKey.export({ format: "der", type: "spki" });
const definition = {
  schema: 1,
  owner: "keepAwake",
  activation: {
    kind: "original-control-callback",
    control: "Keep awake",
    operation: "keepAwake.ui.update",
    mutation: {
      kind: "state-transition",
      payloadKeys: ["values", "removed"],
    },
    sources: [
      {
        path: "Extensions/keepAwake/Views/KeepAwakeSettings.swift",
        sha256: digest("a"),
      },
    ],
  },
  operations: ["keepAwake.ui.update"],
  observation: {
    kind: "checked-engine-readback",
    name: "owned sleep assertion",
  },
  persistence: { applicable: true, name: "preventSleep" },
  limits: ["synthetic-platform-adapter"],
};
function peer(pid) {
  return {
    pid,
    birthSeconds: 1000 + pid,
    birthMicroseconds: pid,
    uid: 501,
    executableSHA256: digest("b"),
  };
}
function capability(phase, index) {
  return {
    schema: 1,
    sourceCommit,
    session,
    owner: definition.owner,
    uid: 501,
    fixtureRoot: root,
    hostIdentifier: `com.pulkit.edith.tests.worker-${session}`,
    home: `${root}/keepAwake-home`,
    dataDirectory: `${root}/data/keepAwake`,
    hostABI: "edith-host-2",
    caseSHA256: functionalDigest(definition),
    activationOperation: definition.activation.operation,
    phase,
    pairScope: "synthetic-development",
    previousVersion: "1.0.0",
    currentVersion: "1.1.0",
    version: phase === "initial" ? "1.0.0" : "1.1.0",
    packageSHA256: digest(index === 0 ? "c" : "d"),
    engine: peer(10 + 2 * index),
    ui: peer(11 + 2 * index),
    operations: definition.operations,
    ownedPaths: [
      {
        name: "data",
        path: `${root}/data/keepAwake`,
        kind: "directory",
      },
    ],
  };
}
function seal(payload, key = keys.privateKey) {
  const bytes = functionalCanonicalJSON(payload);
  return {
    schema: 1,
    payload: bytes,
    signature: sign(null, Buffer.from(bytes), key).toString("base64"),
  };
}
function fixture() {
  const payload = Buffer.from(
    '{"removed":[],"values":"synthetic-preference-bytes"}',
  );
  const stages = ["initial", "updated", "reinstalled"].map((phase, index) => {
    const cap = capability(phase, index);
    const request = {
      schema: 1,
      sourceCommit,
      session,
      owner: definition.owner,
      phase,
      capabilitySHA256: functionalDigest(cap),
      requestID: `12345678-1234-4123-8123-123456789ab${index}`,
      operation: "keepAwake.ui.update",
      payloadSHA256: createHash("sha256").update(payload).digest("hex"),
    };
    return {
      capability: cap,
      admission: {
        heldRootPinned: true,
        heldDescriptorPinned: true,
        sourceClean: true,
        sourcePinned: true,
        payloadSignatureVerified: true,
        architectureVerified: true,
        hostABIVerified: true,
        originalFactoryUnchanged: true,
        originalControlsUnchanged: true,
        staleGenerationRejected: true,
      },
      activation: {
        ...definition.activation,
        ui: cap.ui,
        request,
        payload: payload.toString("base64"),
        sequence: 4,
      },
      acknowledgement: {
        request,
        engine: cap.engine,
        success: true,
        responseSHA256: digest("f"),
        sequence: 5,
      },
      authoritative: {
        ...definition.observation,
        reader: "independent-hosted-producer",
        observationID: `12345678-1234-4123-8123-123456789ac${index}`,
        afterAcknowledgement: true,
        observationSHA256: digest("1"),
        expectedSHA256: digest("1"),
        sequence: 7,
      },
      retired:
        index === 0
          ? []
          : [
              capability("initial", index - 1).engine,
              capability("initial", index - 1).ui,
            ],
      persistence: {
        name: "preventSleep",
        readbackSHA256: digest("2"),
        expectedSHA256: digest("2"),
        sequence: 8,
        beforeActivation:
          index === 0
            ? null
            : {
                reader: "independent-hosted-producer",
                observationID: `12345678-1234-4123-8123-123456789ad${index}`,
                capabilitySHA256: functionalDigest(cap),
                engine: cap.engine,
                ui: cap.ui,
                beforeRequestID: request.requestID,
                sequence: 1,
                readbackSHA256: digest("2"),
                expectedSHA256: digest("2"),
              },
      },
      transition: {
        kind: "state-transition",
        reader: "independent-hosted-producer",
        capabilitySHA256: functionalDigest(cap),
        requestID: request.requestID,
        before: {
          observationID: `12345678-1234-4123-8123-123456789ae${index}`,
          sequence: 3,
          observationSHA256: digest("0"),
          expectedSHA256: digest("0"),
        },
        after: {
          observationID: `12345678-1234-4123-8123-123456789af${index}`,
          sequence: 6,
          observationSHA256: digest("1"),
          expectedSHA256: digest("1"),
        },
      },
    };
  });
  for (const [index, stage] of stages.entries()) {
    const prior = stage.persistence.beforeActivation;
    stage.mutationJournal = seal({
      schema: 1,
      sourceCommit,
      session,
      owner: definition.owner,
      phase: stage.capability.phase,
      capabilitySHA256: functionalDigest(stage.capability),
      presentationID: `12345678-1234-4123-8123-123456789b0${index}`,
      baseline: {
        reader: "independent-hosted-producer",
        observationID:
          prior?.observationID ?? `12345678-1234-4123-8123-123456789b1${index}`,
        sequence: 1,
        readbackSHA256: digest("2"),
        expectedSHA256: digest("2"),
      },
      loadSequence: 2,
      records: [
        {
          request: stage.activation.request,
          activationID: `12345678-1234-4123-8123-123456789b2${index}`,
          origin: "authenticated-original-control",
          ui: stage.capability.ui,
          engine: stage.capability.engine,
          payload: stage.activation.payload,
          sendSequence: stage.activation.sequence,
          acknowledgement: stage.acknowledgement,
          transition: stage.transition,
        },
      ],
      sealedThroughSequence: 9,
    });
  }
  const captured = stages.flatMap(({ capability: cap }) => [
    cap.engine,
    cap.ui,
  ]);
  const observed = {
    schema: 1,
    authority: "independent-hosted-producer",
    execution: "hosted-macos-native",
    sourceCommit,
    session,
    owner: definition.owner,
    uid: 501,
    caseSHA256: functionalDigest(definition),
    stages,
    packagePair: {
      scope: "synthetic-development",
      previous: { version: "1.0.0", packageSHA256: digest("c") },
      current: { version: "1.1.0", packageSHA256: digest("d") },
      publicAdmissionSHA256: null,
    },
    naturalExit: {
      cleanupStarted: false,
      captured,
      absent: captured,
    },
    removal: {
      capturedVersions: ["1.0.0", "1.1.0"],
      physicallyAbsentBeforeReinstall: ["1.0.0", "1.1.0"],
      finalPhysicallyAbsent: ["1.0.0", "1.1.0"],
      leasesReleased: true,
    },
    agenticSentinels: {
      beforeSHA256: digest("3"),
      afterSHA256: digest("3"),
    },
  };
  const proof = {
    schema: 1,
    sourceCommit,
    session,
    owner: definition.owner,
    caseSHA256: functionalDigest(definition),
    stages: stages.map((s) => ({
      phase: s.capability.phase,
      requestID: s.activation.request.requestID,
      capabilitySHA256: functionalDigest(s.capability),
      observationSHA256: s.authoritative.observationSHA256,
    })),
  };
  return { observed, proof };
}
function presentations(
  owner = definition.owner,
  caseSHA256 = functionalDigest(definition),
) {
  return {
    sourceCommit,
    session,
    owner,
    caseSHA256,
    presentations: {
      initial: "12345678-1234-4123-8123-123456789b00",
      updated: "12345678-1234-4123-8123-123456789b01",
      reinstalled: "12345678-1234-4123-8123-123456789b02",
    },
  };
}
function validate(f) {
  return validateFunctionalActionProof(
    f.proof,
    definition,
    seal(f.observed),
    issuer,
    undefined,
    presentations(),
  );
}

test("all owners have disjoint case ownership and the exact maintained inventory", () => {
  assert.equal(functionalActionOwners.length, 39);
  assert.equal(functionalActionBatches.controls.length, 20);
  assert.equal(functionalActionBatches.applications.length, 19);
  validateFunctionalOwnerInventory(
    functionalActionOwners.map((id) => ({ id })),
  );
  for (const owner of functionalActionOwners)
    assert(
      functionalActionCasePaths(owner).native.endsWith(
        `${owner}ActionCase.swift`,
      ),
    );
  assert.throws(() => functionalActionCasePaths("foreign"));
  assert.throws(() =>
    validateFunctionalOwnerInventory(
      functionalActionOwners.slice(1).map((id) => ({ id })),
    ),
  );
});

test("canonical signed descriptors reject unknown issuer, byte tampering and duplicate decoded keys", () => {
  const good = seal(definition);
  assert.deepEqual(verifyFunctionalEnvelope(good, issuer), definition);
  const foreign = generateKeyPairSync("ed25519");
  assert.throws(() =>
    verifyFunctionalEnvelope(seal(definition, foreign.privateKey), issuer),
  );
  assert.throws(() =>
    verifyFunctionalEnvelope(
      {
        ...good,
        payload: good.payload.replace("Keep awake", "Changed"),
      },
      issuer,
    ),
  );
  const duplicate = '{"owner":"foreign","owner":"keepAwake"}';
  assert.throws(() =>
    verifyFunctionalEnvelope(
      {
        schema: 1,
        payload: duplicate,
        signature: sign(null, Buffer.from(duplicate), keys.privateKey).toString(
          "base64",
        ),
      },
      issuer,
    ),
  );
  const escaped = '{"owner":"foreign","\\u006fwner":"keepAwake"}';
  assert.throws(() =>
    verifyFunctionalEnvelope(
      {
        schema: 1,
        payload: escaped,
        signature: sign(null, Buffer.from(escaped), keys.privateKey).toString(
          "base64",
        ),
      },
      issuer,
    ),
  );
});

test("capabilities close source session owner UID generation operations and private paths", () => {
  const cap = capability("initial", 0);
  validateFunctionalCapability(cap, definition);
  const mutations = [
    (c) => {
      c.owner = "music";
    },
    (c) => {
      c.session = "foreign";
    },
    (c) => {
      c.home = "/Users/actual";
    },
    (c) => {
      c.dataDirectory = `${root}/../data`;
    },
    (c) => {
      c.fixtureRoot += "/extra";
    },
    (c) => {
      c.uid = 502;
    },
    (c) => {
      c.engine.birthMicroseconds = 1000000;
    },
    (c) => {
      c.ui.pid = c.engine.pid;
    },
    (c) => {
      c.operations.push("system.arbitrary");
    },
    (c) => {
      c.ownedPaths[0].path = `${root}-outside/data`;
    },
    (c) => {
      c.version = "1.1.0";
    },
    (c) => {
      c.hostABI = "foreign";
    },
    (c) => {
      c.unreviewed = true;
    },
    (c) => {
      c.ownedPaths[0].path += "\n";
    },
  ];
  for (const mutate of mutations) {
    const changed = structuredClone(cap);
    mutate(changed);
    assert.throws(() => validateFunctionalCapability(changed, definition));
  }
  const request = fixture().observed.stages[0].activation.request;
  validateFunctionalRequest(request, cap);
  for (const patch of [
    { phase: "updated" },
    { operation: "system.arbitrary" },
    { capabilitySHA256: digest("0") },
    { session: "foreign" },
    { sourceCommit: "b".repeat(40) },
  ])
    assert.throws(() =>
      validateFunctionalRequest({ ...request, ...patch }, cap),
    );
});

test("separate native action proof requires positive current generations, independent readback and natural exits", () => {
  const result = validate(fixture());
  assert.equal(result.functionalActionsValidated, true);
  assert.equal(result.nativeHardwareValidated, false);
  assert.equal(result.publicUpdateValidated, false);
  assert.equal(result.privilegedShippingRoleValidated, false);
  const mutations = [
    (f) => {
      f.observed.stages.pop();
    },
    (f) => {
      f.observed.execution = "compile-only";
    },
    (f) => {
      f.observed.stages[0].admission.sourceClean = false;
    },
    (f) => {
      f.observed.stages[0].admission.originalFactoryUnchanged = false;
    },
    (f) => {
      f.observed.stages[0].admission.staleGenerationRejected = false;
    },
    (f) => {
      f.observed.stages[0].acknowledgement.success = false;
    },
    (f) => {
      f.observed.stages[0].activation.request.operation = "keepAwake.ui.read";
    },
    (f) => {
      f.observed.stages[0].authoritative.reader = "ui-case";
    },
    (f) => {
      f.observed.stages[0].authoritative.afterAcknowledgement = false;
    },
    (f) => {
      f.observed.stages[0].authoritative.observationID =
        f.observed.stages[0].activation.request.requestID;
    },
    (f) => {
      f.observed.stages[0].authoritative.observationSHA256 = digest("4");
    },
    (f) => {
      f.observed.stages[1].capability.engine =
        f.observed.stages[0].capability.engine;
    },
    (f) => {
      f.observed.stages[1].retired = [];
    },
    (f) => {
      f.observed.stages[1].capability.packageSHA256 =
        f.observed.stages[0].capability.packageSHA256;
    },
    (f) => {
      f.observed.stages[2].persistence.readbackSHA256 = digest("4");
      f.observed.stages[2].persistence.expectedSHA256 = digest("4");
    },
    (f) => {
      f.observed.naturalExit.cleanupStarted = true;
    },
    (f) => {
      f.observed.naturalExit.captured = [];
      f.observed.naturalExit.absent = [];
    },
    (f) => {
      f.observed.naturalExit.absent.pop();
    },
    (f) => {
      f.observed.removal.physicallyAbsentBeforeReinstall = [];
    },
    (f) => {
      f.observed.removal.finalPhysicallyAbsent = ["1.0.0"];
    },
    (f) => {
      f.observed.removal.leasesReleased = false;
    },
    (f) => {
      f.observed.packagePair.publicAdmissionSHA256 = digest("4");
    },
    (f) => {
      f.observed.packagePair.previous.packageSHA256 = digest("4");
    },
    (f) => {
      f.observed.agenticSentinels.afterSHA256 = digest("4");
    },
    (f) => {
      f.proof.stages[0].observationSHA256 = digest("4");
    },
    (f) => {
      f.proof.functionalActionsValidated = true;
    },
  ];
  for (const mutate of mutations) {
    const f = fixture();
    mutate(f);
    assert.throws(() => validate(f));
  }
});

test("missing native cases and readonly definitions cannot become complete action coverage", async () => {
  const read = async () => {
    throw new Error("No maintained owner case");
  };
  await assert.rejects(
    loadAllFunctionalActionCases("/private/synthetic", read),
  );
  await assert.rejects(
    loadFunctionalActionCase("/private/synthetic", "keepAwake", read),
  );
  assert.throws(() =>
    validateFunctionalCaseDefinition({
      ...definition,
      functionalActionsValidated: false,
    }),
  );
  assert.throws(() =>
    validateFunctionalCaseDefinition({
      ...definition,
      activation: {
        ...definition.activation,
        kind: "readonly-view-creation",
      },
    }),
  );
  assert.throws(() =>
    validateFunctionalCaseDefinition({
      ...definition,
      operations: [],
    }),
  );
});

test("literal-only case admission binds the externally pinned definition bytes without evaluation or import caching", async () => {
  const paths = functionalActionCasePaths("keepAwake");
  const bytes = Buffer.from("original source");
  const sha = (value) => createHash("sha256").update(value).digest("hex");
  const def = structuredClone(definition);
  def.activation.sources[0].sha256 = sha(bytes);
  const files = new Map([
    [
      paths.definition,
      Buffer.from(`export const definition = ${JSON.stringify(def)};`),
    ],
    [paths.native, Buffer.from("synthetic native case")],
    [def.activation.sources[0].path, bytes],
  ]);
  const read = async (path) =>
    files.get(path.replace("/private/synthetic/", ""));
  const snapshot = () => ({
    sourceCommit,
    files: [...files].map(([path, value]) => ({
      path,
      sha256: sha(value),
    })),
  });
  const admitted = snapshot();
  const first = await loadFunctionalActionCase(
    "/private/synthetic",
    "keepAwake",
    read,
    admitted,
  );
  assert.deepEqual(first.definition, def);
  assert(Object.isFrozen(first.definition.activation.sources[0]));
  files.set(
    paths.definition,
    Buffer.from(
      `export const definition = ${JSON.stringify(def)}; export const extra = 1;`,
    ),
  );
  await assert.rejects(
    loadFunctionalActionCase("/private/synthetic", "keepAwake", read, admitted),
  );
  await assert.rejects(
    loadFunctionalActionCase(
      "/private/synthetic",
      "keepAwake",
      read,
      snapshot(),
    ),
  );
  for (const source of [
    "export const definition = (() => { throw Error('must not execute'); })();",
    "export const definition = {owner:'foreign', '\\u006fwner':'keepAwake'};",
    "export const definition = {get owner() { return 'keepAwake'; }};",
    "export const definition = {...globalThis};",
  ]) {
    files.set(paths.definition, Buffer.from(source));
    await assert.rejects(
      loadFunctionalActionCase(
        "/private/synthetic",
        "keepAwake",
        read,
        snapshot(),
      ),
    );
  }
});

test("public pair qualification requires separate admitted production receipt, not a producer hash claim", () => {
  const f = fixture();
  f.observed.packagePair.scope = "public-signed-pair";
  f.observed.packagePair.publicAdmissionSHA256 = digest("4");
  for (const stage of f.observed.stages)
    stage.capability.pairScope = "public-signed-pair";
  for (let index = 0; index < 3; index++) {
    const stage = f.observed.stages[index];
    stage.activation.request.capabilitySHA256 = functionalDigest(
      stage.capability,
    );
    stage.transition.capabilitySHA256 = functionalDigest(stage.capability);
    if (stage.persistence.beforeActivation)
      stage.persistence.beforeActivation.capabilitySHA256 = functionalDigest(
        stage.capability,
      );
    const journal = JSON.parse(stage.mutationJournal.payload);
    journal.capabilitySHA256 = functionalDigest(stage.capability);
    for (const record of journal.records) {
      record.request = stage.activation.request;
      record.acknowledgement = stage.acknowledgement;
      record.transition = stage.transition;
    }
    stage.mutationJournal = seal(journal);
    f.proof.stages[index].capabilitySHA256 = functionalDigest(stage.capability);
  }
  assert.throws(() => validate(f));
  const admitted = {
    owner: f.observed.owner,
    sourceCommit,
    previous: f.observed.packagePair.previous,
    current: f.observed.packagePair.current,
    receiptSHA256: digest("4"),
  };
  assert.equal(
    validateFunctionalActionProof(
      f.proof,
      definition,
      seal(f.observed),
      issuer,
      admitted,
      presentations(),
    ).publicUpdateValidated,
    true,
  );
  assert.throws(() =>
    validateFunctionalActionProof(
      f.proof,
      definition,
      seal(f.observed),
      issuer,
      { ...admitted, receiptSHA256: digest("5") },
      presentations(),
    ),
  );
});

test("semantic action proof rejects readonly declarations, unchanged outcomes and persistence repaired after activation", () => {
  assert.throws(() =>
    validateFunctionalCaseDefinition({
      ...definition,
      operations: ["keepAwake.ui.read"],
      activation: {
        ...definition.activation,
        operation: "keepAwake.ui.read",
      },
    }),
  );
  const mutations = [
    (f) => {
      f.observed.stages[1].persistence.beforeActivation = null;
    },
    (f) => {
      f.observed.stages[1].persistence.beforeActivation.sequence = 3;
    },
    (f) => {
      f.observed.stages[1].persistence.beforeActivation.beforeFirstMutation = false;
    },
    (f) => {
      f.observed.stages[1].persistence.beforeActivation.engine =
        f.observed.stages[0].capability.engine;
    },
    (f) => {
      f.observed.stages[1].persistence.beforeActivation.readbackSHA256 =
        digest("0");
    },
    (f) => {
      f.observed.stages[1].persistence.beforeActivation.observationID =
        f.observed.stages[1].activation.request.requestID;
    },
    (f) => {
      f.observed.stages[0].transition.before.observationSHA256 = digest("1");
      f.observed.stages[0].transition.before.expectedSHA256 = digest("1");
    },
    (f) => {
      f.observed.stages[0].activation.payload = Buffer.from(
        '{"removed":[],"values":"synthetic-preference-bytes","extra":true}',
      ).toString("base64");
    },
    (f) => {
      const bytes = Buffer.from(
        '{"removed":[],"values":"synthetic-preference-bytes","\\u0076alues":"synthetic-preference-bytes"}',
      );
      f.observed.stages[0].activation.payload = bytes.toString("base64");
      f.observed.stages[0].activation.request.payloadSHA256 = createHash(
        "sha256",
      )
        .update(bytes)
        .digest("hex");
    },
    (f) => {
      f.observed.stages[0].acknowledgement.sequence = 3;
    },
  ];
  for (const mutate of mutations) {
    const f = fixture();
    mutate(f);
    assert.throws(() => validate(f));
  }
});

function restoreFixture() {
  const f = fixture();
  for (const [index, stage] of f.observed.stages.entries()) {
    const journal = JSON.parse(stage.mutationJournal.payload);
    const first = structuredClone(journal.records[0]);
    first.request.requestID = `12345678-1234-4123-8123-123456789c0${index}`;
    first.acknowledgement.request = first.request;
    first.transition.requestID = first.request.requestID;
    first.transition.before.observationID = `12345678-1234-4123-8123-123456789c1${index}`;
    first.transition.after.observationID = `12345678-1234-4123-8123-123456789c2${index}`;
    first.transition.before.observationSHA256 = digest("1");
    first.transition.before.expectedSHA256 = digest("1");
    first.transition.after.observationSHA256 = digest("0");
    first.transition.after.expectedSHA256 = digest("0");
    stage.activation.sequence = 8;
    stage.acknowledgement.sequence = 9;
    stage.transition.before.sequence = 7;
    stage.transition.after.sequence = 10;
    stage.authoritative.sequence = 11;
    stage.persistence.sequence = 12;
    if (stage.persistence.beforeActivation)
      stage.persistence.beforeActivation.beforeRequestID =
        first.request.requestID;
    journal.records = [
      first,
      {
        ...journal.records[0],
        request: stage.activation.request,
        sendSequence: stage.activation.sequence,
        acknowledgement: stage.acknowledgement,
        transition: stage.transition,
      },
    ];
    journal.sealedThroughSequence = 13;
    stage.mutationJournal = seal(journal);
  }
  return f;
}

test("signed first mutation journal permits original change and restore with a distinct final qualifying action", () => {
  assert.equal(validate(restoreFixture()).functionalActionsValidated, true);
});

test("journal rejects invented first request, stale generation, missing routes and tampered ordering", () => {
  const mutations = [
    (j) => {
      j.records.reverse();
    },
    (j) => {
      j.records.shift();
    },
    (j) => {
      j.records.push(j.records[0]);
    },
    (j) => {
      j.baseline.sequence = j.loadSequence;
    },
    (j) => {
      j.baseline.beforeFirstMutation = true;
    },
    (j) => {
      j.records[0].ui.pid += 10;
    },
    (j) => {
      j.records[0].engine.birthMicroseconds += 1;
    },
    (j) => {
      j.records[0].request.sourceCommit = "b".repeat(40);
    },
    (j) => {
      j.records[0].request.capabilitySHA256 = digest("4");
    },
    (j) => {
      j.records[0].request.operation = "keepAwake.ui.read";
    },
    (j) => {
      j.records[0].sendSequence = j.records[0].acknowledgement.sequence;
    },
    (j) => {
      j.records[1].transition.before.sequence =
        j.records[0].transition.after.sequence;
    },
    (j) => {
      j.records[0].origin = "ui-case";
    },
    (j) => {
      j.records[0].activationID = "foreign";
    },
    (j) => {
      j.records[0].acknowledgement.success = false;
    },
    (j) => {
      j.records[0].transition.requestID = j.records[1].request.requestID;
    },
    (j) => {
      j.records[0].transition.before.observationID = j.baseline.observationID;
    },
    (j) => {
      j.sealedThroughSequence = 10;
    },
    (j) => {
      j.records = Array.from({ length: 129 }, () => j.records[0]);
    },
  ];
  for (const mutate of mutations) {
    const f = restoreFixture();
    const stage = f.observed.stages[1];
    const journal = JSON.parse(stage.mutationJournal.payload);
    mutate(journal);
    stage.mutationJournal = seal(journal);
    assert.throws(() => validate(f));
  }
  for (const mutate of [
    (s) => {
      s.persistence.beforeActivation.beforeRequestID =
        s.activation.request.requestID;
    },
    (s) => {
      s.persistence.beforeActivation.beforeFirstMutation = true;
    },
    (s) => {
      s.mutationJournal.signature =
        fixture().observed.stages[0].mutationJournal.signature;
    },
  ]) {
    const f = restoreFixture();
    mutate(f.observed.stages[1]);
    assert.throws(() => validate(f));
  }
});

test("empty mutation payload is admitted only for the exact Terminal open object schema", () => {
  const def = structuredClone(definition);
  def.owner = "terminal";
  def.activation.operation = "terminal.open";
  def.operations = ["terminal.open"];
  def.activation.sources[0].path = "Extensions/terminal/TerminalPage.swift";
  def.activation.mutation.payloadKeys = [];
  validateFunctionalCaseDefinition(def);
  for (const [owner, operation] of [
    ["terminal", "terminal.read"],
    ["terminal", "terminal.close"],
    ["keepAwake", "terminal.open"],
  ]) {
    const bad = structuredClone(def);
    bad.owner = owner;
    bad.activation.sources[0].path = `Extensions/${owner}/Page.swift`;
    bad.activation.operation = operation;
    bad.operations = [operation];
    assert.throws(() => validateFunctionalCaseDefinition(bad));
  }
  const stage = fixture().observed.stages[0];
  const cap = structuredClone(stage.capability);
  cap.owner = "terminal";
  cap.operations = ["terminal.open"];
  cap.activationOperation = "terminal.open";
  for (const value of [
    "{}",
    "null",
    "[]",
    "0",
    "true",
    '{"extra":true}',
    '{"x":1,"\\u0078":2}',
  ]) {
    const bytes = Buffer.from(value);
    const selected = structuredClone(stage);
    selected.activation.payload = bytes.toString("base64");
    selected.activation.request.owner = "terminal";
    selected.activation.request.operation = "terminal.open";
    selected.activation.request.capabilitySHA256 = functionalDigest(cap);
    selected.activation.request.payloadSHA256 = createHash("sha256")
      .update(bytes)
      .digest("hex");
    selected.acknowledgement.request = selected.activation.request;
    selected.transition.capabilitySHA256 = functionalDigest(cap);
    const journal = JSON.parse(stage.mutationJournal.payload);
    journal.owner = "terminal";
    journal.capabilitySHA256 = functionalDigest(cap);
    journal.records[0] = {
      ...journal.records[0],
      request: selected.activation.request,
      payload: selected.activation.payload,
      acknowledgement: selected.acknowledgement,
      transition: selected.transition,
    };
    const call = () =>
      validateFunctionalMutationJournal(
        seal(journal),
        cap,
        def,
        issuer,
        selected,
        presentations().presentations[cap.phase],
      );
    if (value === "{}") call();
    else assert.throws(call);
  }
});

test("a signed journal from another presentation cannot qualify the admitted controller scope", () => {
  const f = fixture();
  assert.equal(validate(f).functionalActionsValidated, true);
  for (const stage of f.observed.stages) {
    const journal = JSON.parse(stage.mutationJournal.payload);
    journal.presentationID = "12345678-1234-4123-8123-123456789fff";
    stage.mutationJournal = seal(journal);
  }
  assert.throws(() => validate(f));
  const original = fixture();
  assert.throws(() =>
    validateFunctionalActionProof(
      original.proof,
      definition,
      seal(original.observed),
      issuer,
    ),
  );
  const changed = presentations();
  changed.owner = "studio";
  assert.throws(() =>
    validateFunctionalActionProof(
      original.proof,
      definition,
      seal(original.observed),
      issuer,
      undefined,
      changed,
    ),
  );
});
