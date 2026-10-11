import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import { join } from "node:path";
import {
  functionalDigest,
  validateFunctionalCapability,
  validateFunctionalCaseDefinition,
  verifyFunctionalEnvelope,
} from "./contract.mjs";

const hash = /^[0-9a-f]{64}$/;
const uuid =
  /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
const exact = (value, fields) => {
  assert(value && Object.getPrototypeOf(value) === Object.prototype);
  assert.deepEqual(Object.keys(value).sort(), [...fields].sort());
};
const boundedText = (value, maximum = 256) => {
  assert(
    typeof value === "string" &&
      value.length > 0 &&
      Buffer.byteLength(value) <= maximum,
  );
  assert(
    [...value].every(
      (character) =>
        character.codePointAt(0) > 31 && character.codePointAt(0) !== 127,
    ),
  );
};

export function validateInstalledPresentationRecipe(recipe, definition) {
  validateFunctionalCaseDefinition(definition);
  exact(recipe, [
    "schema",
    "owner",
    "location",
    "section",
    "operation",
    "steps",
    "sources",
  ]);
  assert.equal(recipe.schema, 1);
  assert.equal(recipe.owner, definition.owner);
  assert(["main", "settings"].includes(recipe.location));
  assert.equal(
    recipe.section,
    recipe.owner === "notchShelf" || recipe.owner === "systemStats" && recipe.location === "settings" ? "extension" : recipe.owner,
  );
  assert.equal(recipe.operation, definition.activation.operation);
  assert(
    Array.isArray(recipe.sources) &&
      recipe.sources.length > 0 &&
      recipe.sources.length <= 16,
  );
  assert.equal(
    new Set(recipe.sources.map(({ path }) => path)).size,
    recipe.sources.length,
  );
  for (const source of recipe.sources) {
    exact(source, ["path", "sha256"]);
    assert(
      source.path.startsWith(`Extensions/${recipe.owner}/`) &&
        !source.path.split("/").some((part) => ["", ".", ".."].includes(part)),
    );
    boundedText(source.path, 4096);
    assert.match(source.sha256, hash);
  }
  assert(
    Array.isArray(recipe.steps) &&
      recipe.steps.length > 0 &&
      recipe.steps.length <= 16,
  );
  for (const step of recipe.steps) {
    const fields = ["role", "label", "action", "value"];
    if (Object.hasOwn(step, "scope")) fields.push("scope");
    if (Object.hasOwn(step, "ownedPath")) fields.push("ownedPath");
    exact(step, fields);
    if (step.scope) {
      const fields = ["kind", "label"];
      if (Object.hasOwn(step.scope, "anchor")) fields.push("anchor");
      exact(step.scope, fields);
      assert(["window", "sheet", "menu", "row", "panel", "group", "button"].includes(step.scope.kind));
      if (step.scope.label !== "") boundedText(step.scope.label, 512);
      else assert(step.scope.anchor, "An unlabeled original scope requires a source anchor");
      if (step.scope.anchor) {
        exact(step.scope.anchor, ["role", "label"]);
        assert(["staticText", "button", "textField", "menuItem"].includes(step.scope.anchor.role));
        boundedText(step.scope.anchor.label, 512);
      }
    }
    if (step.ownedPath !== undefined) {
      boundedText(step.ownedPath, 128);
      assert.match(step.ownedPath, /^[A-Za-z0-9_.-]+$/);
    }
    if (step.label === "") assert(step.scope?.kind === "button" && step.scope.anchor);
    else boundedText(step.label);
    assert(
      [
        "checkBox",
        "button",
        "textField",
        "secureTextField",
        "popUpButton",
        "menuItem", "row", "slider", "stepper", "column", "staticText", "textArea",
      ].includes(step.role),
    );
    if (step.action === "set-checkbox") {
      assert.equal(step.role, "checkBox");
      assert.equal(typeof step.value, "boolean");
    } else if (step.action === "replace-text") {
      assert(["textField", "secureTextField"].includes(step.role));
      boundedText(step.value, 4096);
    } else if (step.action === "choose-owned-path") {
      assert.equal(step.role, "button");
      assert(["Save", "Choose", "Open"].includes(step.label));
      assert.equal(step.value, null);
      assert(step.ownedPath);
      assert.equal(step.scope?.kind, "panel");
    } else if (step.action === "set-slider") {
      assert.equal(step.role, "slider");
      assert(Number.isFinite(step.value) && step.value >= 0 && step.value <= 1);
    } else if (["increment", "decrement"].includes(step.action)) {
      assert.equal(step.role, "stepper");
      assert.equal(step.value, null);
    } else if (step.action === "submit") {
      assert.equal(step.role, "textField");
      assert.equal(step.value, null);
    } else {
      assert.equal(step.action, "click");
      assert.equal(step.value, null);
      assert(["button", "popUpButton", "menuItem", "row", "column"].includes(step.role));
    }
    assert(step.action === "choose-owned-path" || step.ownedPath === undefined);
  }
  return recipe;
}

export async function loadInstalledPresentationRecipe(
  root,
  owner,
  definition,
  read = readFile,
) {
  validateFunctionalCaseDefinition(definition);
  assert.equal(owner, definition.owner);
  const path = `scripts/hosted-functional-actions/presentations/${owner}.json`;
  const bytes = await read(join(root, path));
  assert(bytes.length > 0 && bytes.length <= 32768);
  const recipe = validateInstalledPresentationRecipe(
    JSON.parse(bytes),
    definition,
  );
  for (const pin of recipe.sources)
    assert.equal(
      createHash("sha256")
        .update(await read(join(root, pin.path)))
        .digest("hex"),
      pin.sha256,
    );
  assert(
    (await read(join(root, path))).equals(bytes),
    "Presentation recipe changed during admission",
  );
  return {
    recipe,
    sourcePin: {
      path,
      sha256: createHash("sha256").update(bytes).digest("hex"),
    },
  };
}

export function validateInstalledPresentationObservation(
  envelope,
  recipe,
  definition,
  issuer,
  admittedCapability,
) {
  validateInstalledPresentationRecipe(recipe, definition);
  validateFunctionalCapability(admittedCapability, definition);
  const observed = verifyFunctionalEnvelope(envelope, issuer);
  exact(observed, [
    "schema",
    "authority",
    "execution",
    "capabilitySHA256",
    "recipeSHA256",
    "presentationID",
    "windowTitle",
    "before",
    "after",
    "steps", "stepInventories",
    "mutation",
    "authoritative",
    "presentationClosed",
    "leasesReleased",
  ]);
  assert.equal(observed.schema, 1);
  assert.equal(observed.authority, "independent-hosted-producer");
  assert.equal(observed.execution, "hosted-macos-native");
  assert.equal(observed.capabilitySHA256, functionalDigest(admittedCapability));
  assert.equal(observed.recipeSHA256, functionalDigest(recipe));
  assert.match(observed.presentationID, uuid);
  assert.equal(observed.presentationID, installedPresentationID(admittedCapability));
  assert.equal(
    observed.windowTitle,
    installedPresentationWindowTitle(admittedCapability),
  );
  const inventory = (state) => {
    exact(state, [
      "sourceCommit",
      "sourceClean",
      "heldRootPinned",
      "heldDescriptorPinned",
      "hostSignatureVerified",
      "workerSignatureVerified",
      "roleSignatureVerified",
      "rolePayloadUnchanged",
      "factoryOverlay",
      "originalFactoriesUnchanged",
      "originalControlsUnchanged",
      "hostABI",
      "version",
      "packageSHA256",
      "bundleTreeSHA256",
      "engine",
      "ui",
      "presentationID",
    ]);
    assert.equal(state.sourceCommit, admittedCapability.sourceCommit);
    for (const field of [
      "sourceClean",
      "heldRootPinned",
      "heldDescriptorPinned",
      "hostSignatureVerified",
      "workerSignatureVerified",
      "roleSignatureVerified",
      "rolePayloadUnchanged",
      "originalFactoriesUnchanged",
      "originalControlsUnchanged",
    ])
      assert.equal(state[field], true);
    assert.equal(state.factoryOverlay, false);
    assert.equal(state.hostABI, admittedCapability.hostABI);
    assert.equal(state.version, admittedCapability.version);
    assert.equal(state.packageSHA256, admittedCapability.packageSHA256);
    assert.match(state.bundleTreeSHA256, hash);
    assert.deepEqual(state.engine, admittedCapability.engine);
    assert.deepEqual(state.ui, admittedCapability.ui);
    assert.equal(state.presentationID, observed.presentationID);
  };
  inventory(observed.before);
  inventory(observed.after);
  assert.deepEqual(
    observed.before,
    observed.after,
    "Source, downloaded bundle or native generation changed across action",
  );
  assert.deepEqual(observed.steps, recipe.steps);
  assert.equal(observed.stepInventories.length, recipe.steps.length);
  for (const [index, step] of observed.stepInventories.entries()) {
    exact(step, ["index", "before", "after"]);
    assert.equal(step.index, index);
    inventory(step.before);
    inventory(step.after);
    assert.deepEqual(step.before, observed.before);
    assert.deepEqual(step.after, observed.before);
  }
  const mutation = observed.mutation;
  exact(mutation, [
    "origin",
    "operation",
    "presentationID",
    "ui",
    "engine",
    "requestID",
    "payloadSHA256",
    "responseSHA256",
    "success",
    "beforeAuthoritativeRead",
  ]);
  assert.equal(mutation.origin, "authenticated-downloaded-ui-engine-receiver");
  assert.equal(mutation.operation, recipe.operation);
  assert.equal(mutation.presentationID, observed.presentationID);
  assert.deepEqual(mutation.ui, admittedCapability.ui);
  assert.deepEqual(mutation.engine, admittedCapability.engine);
  assert.match(mutation.requestID, uuid);
  assert.match(mutation.payloadSHA256, hash);
  assert.match(mutation.responseSHA256, hash);
  assert.equal(mutation.success, true);
  assert.equal(mutation.beforeAuthoritativeRead, true);
  const authoritative = observed.authoritative;
  exact(authoritative, [
    "reader",
    "kind",
    "name",
    "observationID",
    "engine",
    "observedSHA256",
    "expectedSHA256",
  ]);
  assert.equal(authoritative.reader, "independent-hosted-producer");
  assert.equal(authoritative.kind, definition.observation.kind);
  assert.equal(authoritative.name, definition.observation.name);
  assert.match(authoritative.observationID, uuid);
  assert.notEqual(authoritative.observationID, mutation.requestID);
  assert.deepEqual(authoritative.engine, admittedCapability.engine);
  assert.match(authoritative.observedSHA256, hash);
  assert.equal(authoritative.observedSHA256, authoritative.expectedSHA256);
  assert.equal(observed.presentationClosed, true);
  assert.equal(observed.leasesReleased, true);
  return Object.freeze({
    schema: 1,
    owner: recipe.owner,
    sourceCommit: admittedCapability.sourceCommit,
    session: admittedCapability.session,
    phase: admittedCapability.phase,
    version: admittedCapability.version,
    downloadedUIBinaryActionsValidated: true,
    nativeHardwareValidated: false,
    privilegedShippingRoleValidated: false,
    limits: [...definition.limits],
  });
}

export function installedPresentationID(capability) {
  const bytes = Buffer.from(functionalDigest(capability).slice(0, 32), "hex");
  bytes[6] = (bytes[6] & 15) | 64;
  bytes[8] = (bytes[8] & 63) | 128;
  const hex = bytes.toString("hex");
  return [hex.slice(0, 8), hex.slice(8, 12), hex.slice(12, 16), hex.slice(16, 20), hex.slice(20)].join("-");
}

export function heldInstalledPresentationSteps(recipe, definition, capability) {
  validateInstalledPresentationRecipe(recipe, definition);
  validateFunctionalCapability(capability, definition);
  return recipe.steps.map((step) => {
    const scope = step.scope ?? { kind: "window", label: installedPresentationWindowTitle(capability) };
    let value = step.value;
    if (step.action === "choose-owned-path") {
      const path = capability.ownedPaths.find((entry) => entry.name === step.ownedPath);
      assert(path, "Missing independently admitted named chooser capability");
      assert(path.path.startsWith(`${capability.fixtureRoot}/`));
      assert(["file", "directory"].includes(path.kind));
    }
    return Object.freeze({ ...step, scope, ownedPath: step.ownedPath ?? null, value });
  });
}

export function installedPresentationWindowTitle(capability) {
  assert.match(capability.session, uuid);
  assert(["initial", "updated", "reinstalled"].includes(capability.phase));
  return `Synthetic functional ${capability.owner} ${capability.phase} ${capability.session}`;
}

export function installedPresentationUITestSource(
  recipe,
  definition,
  capability,
) {
  validateInstalledPresentationRecipe(recipe, definition);
  validateFunctionalCapability(capability, definition);
  const heldSteps = heldInstalledPresentationSteps(recipe, definition, capability);
  const encoded = Buffer.from(JSON.stringify(heldSteps)).toString("base64");
  const identifier = JSON.stringify(capability.hostIdentifier);
  const title = JSON.stringify(installedPresentationWindowTitle(capability));
  const ownedPaths = `[${capability.ownedPaths.map(({ name, path }) => `${JSON.stringify(name)}: ${JSON.stringify(path)}`).join(", ")}]`;
  return `import Foundation
import XCTest

@MainActor
final class HostedFunctionalInstalledUITests: XCTestCase {
    struct Step: Decodable {
        let role: String
        let label: String
        let action: String
        let value: Value
        let scope: Scope
        let ownedPath: String?
        struct Scope: Decodable {
            let kind: String
            let label: String
            let anchor: Anchor?
            struct Anchor: Decodable { let role: String; let label: String }
        }
        enum Value: Decodable {
            case boolean(Bool), number(Double), text(String), null
            init(from decoder: any Decoder) throws {
                let container = try decoder.singleValueContainer()
                if container.decodeNil() { self = .null }
                else if let boolean = try? container.decode(Bool.self) { self = .boolean(boolean) }
                else if let number = try? container.decode(Double.self) { self = .number(number) }
                else { self = .text(try container.decode(String.self)) }
            }
        }
    }

    func testOriginalDownloadedPresentationAction() throws {
        continueAfterFailure = false
        let application = XCUIApplication(bundleIdentifier: ${identifier})
        XCTAssertEqual(application.state, .runningForeground)
        let windows = application.windows.matching(NSPredicate(format: "label == %@", ${title}))
        XCTAssertTrue(wait(30) { windows.count == 1 })
        XCTAssertEqual(windows.count, 1)
        let window = windows.element(boundBy: 0)
        let presentationID = "${installedPresentationID(capability)}"
        XCTAssertFalse(presentationID.isEmpty)
        let ownedPaths: [String: String] = ${ownedPaths}
        let steps = try JSONDecoder().decode([Step].self, from: XCTUnwrap(Data(base64Encoded: "${encoded}")))
        for step in steps {
            let type: XCUIElement.ElementType
            switch step.role {
            case "checkBox": type = .checkBox
            case "button": type = .button
            case "textField": type = .textField
            case "secureTextField": type = .secureTextField
            case "popUpButton": type = .popUpButton
            case "menuItem": type = .menuItem
            case "row": type = .row
            case "slider": type = .slider
            case "stepper": type = .stepper
            case "column": type = .column
            case "staticText": type = .staticText
            case "textArea": type = .textView
            default: XCTFail("Unsupported original control"); return
            }
            let scopes: XCUIElementQuery
            switch step.scope.kind {
            case "window": scopes = windows
            case "sheet": scopes = window.sheets
            case "menu": scopes = application.menus
            case "row": scopes = window.descendants(matching: .row)
            case "panel": scopes = application.windows
            case "group": scopes = window.descendants(matching: .group)
            case "button": scopes = window.buttons
            default: XCTFail("Unsupported original scope"); return
            }
            let sourceScopes = scopes.allElementsBoundByIndex.filter { candidate in
                if !step.scope.label.isEmpty && candidate.label != step.scope.label && candidate.identifier != step.scope.label { return false }
                if let anchor = step.scope.anchor {
                    let types: [String: XCUIElement.ElementType] = ["staticText": .staticText, "button": .button, "textField": .textField, "menuItem": .menuItem]
                    guard let anchorType = types[anchor.role] else { return false }
                    let anchors = candidate.descendants(matching: anchorType).matching(NSPredicate(format: "label == %@ OR identifier == %@", anchor.label, anchor.label))
                    guard anchors.count == 1 else { return false }
                }
                if step.label.isEmpty { return step.scope.kind == "button" && type == .button }
                return candidate.descendants(matching: type).matching(NSPredicate(format: "label == %@ OR identifier == %@", step.label, step.label)).count == 1
            }
            let innermost = sourceScopes.filter { candidate in
                !sourceScopes.contains { child in child != candidate && candidate.descendants(matching: .any).allElementsBoundByIndex.contains(child) }
            }
            XCTAssertEqual(innermost.count, 1)
            let scoped = try XCTUnwrap(innermost.first)
            let control: XCUIElement
            if step.label.isEmpty { control = scoped }
            else {
                let controls = scoped.descendants(matching: type).matching(NSPredicate(format: "label == %@ OR identifier == %@", step.label, step.label))
                XCTAssertTrue(wait(30) { controls.count == 1 })
                XCTAssertEqual(controls.count, 1)
                control = controls.element(boundBy: 0)
            }
            XCTAssertTrue(wait(30) { control.isHittable && (step.action == "choose-owned-path" || control.isEnabled) })
            switch (step.action, step.value) {
            case ("set-checkbox", .boolean(let desired)):
                let current = control.value as? String
                XCTAssertTrue(current == "0" || current == "1")
                let target = desired ? "1" : "0"
                XCTAssertNotEqual(current, target)
                control.click()
                XCTAssertTrue(wait(15) { control.value as? String == target })
            case ("replace-text", .text(let value)):
                control.click()
                control.typeKey("a", modifierFlags: .command)
                control.typeText(value)
                if step.role != "secureTextField" {
                    XCTAssertTrue(wait(15) { control.value as? String == value })
                }
            case ("choose-owned-path", .null):
                let value = try XCTUnwrap(ownedPaths[try XCTUnwrap(step.ownedPath)])
                XCTAssertEqual(step.scope.kind, "panel")
                application.typeKey("g", modifierFlags: [.command, .shift])
                let fields = application.sheets.textFields
                XCTAssertTrue(wait(15) { fields.count == 1 })
                XCTAssertEqual(fields.count, 1)
                let field = fields.element(boundBy: 0)
                field.click()
                field.typeKey("a", modifierFlags: .command)
                field.typeText(value)
                XCTAssertTrue(wait(15) { field.value as? String == value })
                field.typeKey(.return, modifierFlags: [])
                XCTAssertTrue(wait(15) { control.isEnabled && control.isHittable })
                control.click()
            case ("set-slider", .number(let value)):
                XCTAssertGreaterThanOrEqual(value, 0)
                XCTAssertLessThanOrEqual(value, 1)
                control.adjust(toNormalizedSliderPosition: value)
            case ("increment", .null): control.buttons["Increment"].click()
            case ("decrement", .null): control.buttons["Decrement"].click()
            case ("submit", .null): control.typeKey(.return, modifierFlags: [])
            case ("click", .null): control.click()
            default: XCTFail("Invalid original control action"); return
            }
        }
        let bytes = try JSONSerialization.data(withJSONObject: [
            "schema": 1, "sourceCommit": "${capability.sourceCommit}",
            "owner": "${capability.owner}", "session": "${capability.session}",
            "phase": "${capability.phase}", "version": "${capability.version}",
            "capabilitySHA256": "${functionalDigest(capability)}",
            "recipeSHA256": "${functionalDigest(recipe)}", "producerObservationRequired": true
        ], options: [.sortedKeys])
        let attachment = XCTAttachment(data: bytes, uniformTypeIdentifier: "public.json")
        attachment.name = "Original downloaded functional action"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func wait(_ seconds: TimeInterval, _ condition: @escaping () -> Bool) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        return XCTWaiter.wait(for: [expectation], timeout: seconds) == .completed
    }
}
`;
}
