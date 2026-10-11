import assert from "node:assert/strict";
import { generateKeyPairSync, sign } from "node:crypto";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { definition } from "./cases/keepAwake.mjs";
import { functionalCanonicalJSON, functionalDigest } from "./contract.mjs";
import {
  installedPresentationUITestSource,
  installedPresentationWindowTitle,
  loadInstalledPresentationRecipe,
  validateInstalledPresentationObservation,
  validateInstalledPresentationRecipe,
} from "./presentation.mjs";

const key = generateKeyPairSync("ed25519");
const issuer = key.publicKey.export({ type: "spki", format: "der" });
export const recipe = JSON.parse(
  await readFile(new URL("./presentations/keepAwake.json", import.meta.url)),
);
const session = "12345678-1234-4123-8123-123456789abc";
const digest = (character) => character.repeat(64);
const processIdentity = (pid) => ({
  pid,
  birthSeconds: 1000,
  birthMicroseconds: pid,
  uid: 501,
  executableSHA256: digest("a"),
});
export const capability = {
  schema: 1,
  sourceCommit: "a".repeat(40),
  session,
  owner: "keepAwake",
  uid: 501,
  fixtureRoot: `/private/synthetic/functional-fixture-${session}`,
  hostIdentifier: `com.pulkit.edith.tests.worker-${session}`,
  home: `/private/synthetic/functional-fixture-${session}/keepAwake-home`,
  dataDirectory: `/private/synthetic/functional-fixture-${session}/data/keepAwake`,
  hostABI: "edith-host-2",
  caseSHA256: functionalDigest(definition),
  activationOperation: definition.activation.operation,
  phase: "initial",
  pairScope: "synthetic-development",
  previousVersion: "1.0.0",
  currentVersion: "1.1.0",
  version: "1.0.0",
  packageSHA256: digest("b"),
  engine: processIdentity(12),
  ui: processIdentity(13),
  operations: definition.operations,
  ownedPaths: [
    {
      name: "data",
      path: `/private/synthetic/functional-fixture-${session}/data/keepAwake`,
      kind: "directory",
    },
  ],
};
const presentationID = "12345678-1234-4123-8123-123456789abd";
const inventory = () => ({
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
  bundleTreeSHA256: digest("c"),
  engine: capability.engine,
  ui: capability.ui,
  presentationID,
});
const observation = () => ({
  schema: 1,
  authority: "independent-hosted-producer",
  execution: "hosted-macos-native",
  capabilitySHA256: functionalDigest(capability),
  recipeSHA256: functionalDigest(recipe),
  presentationID,
  windowTitle: installedPresentationWindowTitle(capability),
  before: inventory(),
  after: inventory(),
  steps: recipe.steps,
  mutation: {
    origin: "authenticated-downloaded-ui-engine-receiver",
    operation: recipe.operation,
    presentationID,
    ui: capability.ui,
    engine: capability.engine,
    requestID: "12345678-1234-4123-8123-123456789abe",
    payloadSHA256: digest("d"),
    responseSHA256: digest("e"),
    success: true,
    beforeAuthoritativeRead: true,
  },
  authoritative: {
    reader: "independent-hosted-producer",
    ...definition.observation,
    observationID: "12345678-1234-4123-8123-123456789abf",
    engine: capability.engine,
    observedSHA256: digest("f"),
    expectedSHA256: digest("f"),
  },
  presentationClosed: true,
  leasesReleased: true,
});
const seal = (value) => {
  const payload = functionalCanonicalJSON(value);
  return {
    schema: 1,
    payload,
    signature: sign(null, Buffer.from(payload), key.privateKey).toString(
      "base64",
    ),
  };
};
const validate = (value) =>
  validateInstalledPresentationObservation(
    seal(value),
    recipe,
    definition,
    issuer,
    capability,
  );

test("installed UI action has a separate qualified receipt requiring source and exact downloaded generation stability", () => {
  const result = validate(observation());
  assert.equal(result.downloadedUIBinaryActionsValidated, true);
  assert.equal(result.phase, "initial");
  assert.equal(result.nativeHardwareValidated, false);
  assert.equal(result.privilegedShippingRoleValidated, false);
});

test("signed factory overlays, changed bundle bytes, source or roles cannot qualify original downloaded UI actions", () => {
  const mutations = [
    (o) => {
      o.before.factoryOverlay = true;
      o.after.factoryOverlay = true;
    },
    (o) => {
      o.before.rolePayloadUnchanged = false;
      o.after.rolePayloadUnchanged = false;
    },
    (o) => {
      o.after.bundleTreeSHA256 = digest("0");
    },
    (o) => {
      o.after.sourceCommit = "b".repeat(40);
    },
    (o) => {
      o.after.sourceClean = false;
    },
    (o) => {
      o.after.heldRootPinned = false;
    },
    (o) => {
      o.after.heldDescriptorPinned = false;
    },
    (o) => {
      o.before.hostSignatureVerified = false;
    },
    (o) => {
      o.after.workerSignatureVerified = false;
    },
    (o) => {
      o.after.roleSignatureVerified = false;
    },
    (o) => {
      o.after.originalFactoriesUnchanged = false;
    },
    (o) => {
      o.after.originalControlsUnchanged = false;
    },
    (o) => {
      o.after.ui = { ...o.after.ui, birthMicroseconds: 44 };
    },
    (o) => {
      o.after.engine = { ...o.after.engine, pid: 44 };
    },
    (o) => {
      o.after.presentationID = session;
    },
    (o) => {
      o.after.version = "1.1.0";
    },
    (o) => {
      o.after.hostABI = "runtime-1";
    },
    (o) => {
      o.after.packageSHA256 = digest("0");
    },
  ];
  for (const mutate of mutations) {
    const value = structuredClone(observation());
    mutate(value);
    assert.throws(() => validate(value));
  }
});

test("readonly, failed, wrong-presentation or self-reported readback never proves a mutation", () => {
  const mutations = [
    (o) => {
      o.mutation.operation = "keepAwake.ui.read";
    },
    (o) => {
      o.mutation.origin = "source-original-control";
    },
    (o) => {
      o.mutation.success = false;
    },
    (o) => {
      o.mutation.beforeAuthoritativeRead = false;
    },
    (o) => {
      o.mutation.presentationID = session;
    },
    (o) => {
      o.authoritative.reader = "case";
    },
    (o) => {
      o.authoritative.expectedSHA256 = digest("0");
    },
    (o) => {
      o.authoritative.observationID = o.mutation.requestID;
    },
    (o) => {
      o.steps = [];
    },
    (o) => {
      o.presentationClosed = false;
    },
    (o) => {
      o.leasesReleased = false;
    },
  ];
  for (const mutate of mutations) {
    const value = structuredClone(observation());
    mutate(value);
    assert.throws(() => validate(value));
  }
});

test("recipes pin actual original sources and missing per-owner selectors fail closed", async () => {
  const root = new URL("../../", import.meta.url).pathname;
  assert.equal(
    (await loadInstalledPresentationRecipe(root, "keepAwake", definition))
      .recipe.owner,
    "keepAwake",
  );
  await assert.rejects(
    loadInstalledPresentationRecipe(root, "keepAwake", definition, async () => {
      throw new Error("missing maintained recipe");
    }),
  );
  assert.throws(() =>
    validateInstalledPresentationRecipe({ ...recipe, steps: [] }, definition),
  );
  assert.throws(() =>
    validateInstalledPresentationRecipe(
      { ...recipe, operation: "keepAwake.ui.read" },
      definition,
    ),
  );
  assert.throws(() =>
    validateInstalledPresentationRecipe(
      { ...recipe, owner: "music" },
      definition,
    ),
  );
});

test("actual generated XCTest acts on an already held original window and never launches a substitute presentation", () => {
  const source = installedPresentationUITestSource(
    recipe,
    definition,
    capability,
  );
  assert(source.includes("testOriginalDownloadedPresentationAction"));
  assert(source.includes("control.click()"));
  assert(source.includes("producerObservationRequired"));
  assert(!source.includes("application.launch("));
  assert(!source.includes("application.terminate("));
  assert(!source.includes("NSHostingController"));
});
