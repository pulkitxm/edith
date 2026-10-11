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
    recipe.owner === "notchShelf" ? "extension" : recipe.owner,
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
    exact(step, ["role", "label", "action", "value"]);
    boundedText(step.label);
    assert(
      [
        "checkBox",
        "button",
        "textField",
        "secureTextField",
        "popUpButton",
        "menuItem",
      ].includes(step.role),
    );
    if (step.action === "set-checkbox") {
      assert.equal(step.role, "checkBox");
      assert.equal(typeof step.value, "boolean");
    } else if (step.action === "replace-text") {
      assert(["textField", "secureTextField"].includes(step.role));
      boundedText(step.value, 4096);
    } else {
      assert.equal(step.action, "click");
      assert.equal(step.value, null);
    }
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
    "steps",
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
  const encoded = Buffer.from(JSON.stringify(recipe.steps)).toString("base64");
  const identifier = JSON.stringify(capability.hostIdentifier);
  const title = JSON.stringify(installedPresentationWindowTitle(capability));
  return `import Foundation
import XCTest

@MainActor
final class HostedFunctionalInstalledUITests: XCTestCase {
    struct Step: Decodable {
        let role: String
        let label: String
        let action: String
        let value: Value
        enum Value: Decodable {
            case boolean(Bool), text(String), null
            init(from decoder: any Decoder) throws {
                let container = try decoder.singleValueContainer()
                if container.decodeNil() { self = .null }
                else if let boolean = try? container.decode(Bool.self) { self = .boolean(boolean) }
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
            default: XCTFail("Unsupported original control"); return
            }
            let controls = window.descendants(matching: type).matching(NSPredicate(format: "label == %@ OR identifier == %@", step.label, step.label))
            XCTAssertTrue(wait(30) { controls.count == 1 })
            XCTAssertEqual(controls.count, 1)
            let control = controls.element(boundBy: 0)
            XCTAssertTrue(wait(30) { control.isEnabled && control.isHittable })
            switch (step.action, step.value) {
            case ("set-checkbox", .boolean(let desired)):
                let current = control.value as? String
                XCTAssertTrue(current == "0" || current == "1")
                let target = desired ? "1" : "0"
                if current != target { control.click() }
                XCTAssertTrue(wait(15) { control.value as? String == target })
            case ("replace-text", .text(let value)):
                control.click()
                control.typeKey("a", modifierFlags: .command)
                control.typeText(value)
                XCTAssertTrue(wait(15) { control.value as? String == value })
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
