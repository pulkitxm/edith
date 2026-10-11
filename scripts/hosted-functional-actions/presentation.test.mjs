import assert from "node:assert/strict";
import { generateKeyPairSync, sign } from "node:crypto";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { definition } from "./cases/keepAwake.mjs";
import { functionalCanonicalJSON, functionalDigest } from "./contract.mjs";
import {
  heldInstalledPresentationSteps,
  installedPresentationID,
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
const presentationID = installedPresentationID(capability);
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
  stepInventories: recipe.steps.map((_, index) => ({
    index,
    before: inventory(),
    after: inventory(),
  })),
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

test("external capability presentation ID and every held original step inventory reject drift", () => {
  const wrong = observation();
  wrong.presentationID = "12345678-1234-4123-8123-123456789abd";
  assert.throws(() => validate(wrong));
  const drift = observation();
  drift.stepInventories[0].after.engine = structuredClone(
    drift.stepInventories[0].after.engine,
  );
  drift.stepInventories[0].after.engine.pid++;
  assert.throws(() => validate(drift));
  const missing = observation();
  missing.stepInventories = [];
  assert.throws(() => validate(missing));
});

test("original named chooser requires explicit owned path and held panel scope", () => {
  const scoped = structuredClone(recipe);
  scoped.steps = [
    {
      role: "button",
      label: "Choose",
      action: "choose-owned-path",
      value: null,
      scope: { kind: "panel", label: "Save" },
      ownedPath: "data",
    },
  ];
  const steps = heldInstalledPresentationSteps(scoped, definition, capability);
  assert.equal(steps[0].value, null);
  assert.equal(steps[0].ownedPath, "data");
  const wrong = structuredClone(scoped);
  wrong.steps[0].ownedPath = "unrelated";
  assert.throws(() =>
    heldInstalledPresentationSteps(wrong, definition, capability),
  );
  delete scoped.steps[0].scope;
  assert.throws(() => validateInstalledPresentationRecipe(scoped, definition));
});

test("source anchors select unlabeled original groups, menu options and variable row buttons without invented labels", () => {
  const scoped = structuredClone(recipe);
  scoped.steps = [
    {
      role: "button",
      label: "",
      action: "click",
      value: null,
      scope: {
        kind: "button",
        label: "",
        anchor: { role: "staticText", label: "Standard" },
      },
    },
  ];
  validateInstalledPresentationRecipe(scoped, definition);
  const source = installedPresentationUITestSource(
    scoped,
    definition,
    capability,
  );
  assert(source.includes('case "button": scopes = window.buttons'));
  const missing = structuredClone(scoped);
  delete missing.steps[0].scope.anchor;
  assert.throws(() => validateInstalledPresentationRecipe(missing, definition));
  scoped.steps = [
    {
      role: "menuItem",
      label: "Custom",
      action: "click",
      value: null,
      scope: {
        kind: "menu",
        label: "",
        anchor: { role: "menuItem", label: "Custom" },
      },
    },
  ];
  validateInstalledPresentationRecipe(scoped, definition);
});

test("source-scoped unnamed controls, multiline editor input and actual menu or header actions retain original selectors", () => {
  const steps = [
    {
      role: "slider",
      label: "",
      action: "set-slider",
      value: 0.25,
      scope: {
        kind: "group",
        label: "",
        anchor: { role: "staticText", label: "Synthetic audio" },
      },
    },
    {
      role: "textArea",
      label: "",
      action: "replace-text",
      value: "synthetic\nsecond line",
      scope: {
        kind: "group",
        label: "Editor",
        anchor: { role: "staticText", label: "Editor" },
      },
    },
    {
      role: "row",
      label: "synthetic-machine",
      action: "show-menu",
      value: null,
    },
    { role: "column", label: "Name", action: "set-column-width", value: 238 },
    {
      role: "textField",
      label: "Ask a question",
      selector: "placeholder",
      action: "submit",
      value: null,
    },
    {
      role: "button",
      label: "New terminal (⌘T)",
      selector: "help",
      action: "click",
      value: null,
    },
  ];
  const value = { ...recipe, steps };
  validateInstalledPresentationRecipe(value, definition);
  const source = installedPresentationUITestSource(
    value,
    definition,
    capability,
  );
  assert(source.includes("control.rightClick()"));
  assert(source.includes("start.click(forDuration: 0.1, thenDragTo: end)"));
  assert(source.includes("$0.placeholderValue == label"));
  assert(source.includes("candidate.hover()"));
  assert(source.includes("let sourceScopes") === false);
  assert(source.includes("func sourceScopes()"));
});

test("unsupported selectors, unscoped empty controls, invalid guards and unsafe text fail before original UI generation", () => {
  const values = [
    { role: "slider", label: "", action: "set-slider", value: 0.25 },
    {
      role: "button",
      label: "New",
      selector: "ordinal",
      action: "click",
      value: null,
    },
    {
      role: "button",
      label: "New",
      selector: "placeholder",
      action: "click",
      value: null,
    },
    {
      role: "textArea",
      label: "Editor",
      action: "replace-text",
      value: "synthetic\u0000secret",
    },
    { role: "column", label: "Name", action: "set-column-width", value: 2049 },
    { role: "row", label: "machine", action: "show-menu", value: "pretend" },
    {
      role: "button",
      label: "New",
      action: "click",
      value: null,
      when: "value-differs",
    },
    {
      role: "checkBox",
      label: "Enabled",
      action: "set-checkbox",
      value: true,
      when: "always",
    },
  ];
  for (const step of values)
    assert.throws(() =>
      validateInstalledPresentationRecipe(
        { ...recipe, steps: [step] },
        definition,
      ),
    );
});

test("basename labels come only from exact named signed capabilities and missing names cannot generate a chooser", () => {
  const step = {
    role: "button",
    label: "",
    ownedLabel: { name: "data", component: "basename" },
    action: "click",
    value: null,
  };
  const value = { ...recipe, steps: [step] };
  const held = heldInstalledPresentationSteps(value, definition, capability);
  assert.equal(held[0].label, "keepAwake");
  assert.equal(held[0].ownedLabel.name, "data");
  const missing = structuredClone(value);
  missing.steps[0].ownedLabel.name = "another-owner";
  assert.throws(() =>
    heldInstalledPresentationSteps(missing, definition, capability),
  );
  missing.steps[0].ownedLabel.component = "arbitrary-path";
  assert.throws(() => validateInstalledPresentationRecipe(missing, definition));
});
