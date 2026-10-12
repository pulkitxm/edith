import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import { join, resolve } from "node:path";
import {
  functionalCanonicalJSON,
  functionalDigest,
  validateFunctionalCapability,
  validateFunctionalCaseDefinition,
  verifyFunctionalEnvelope,
} from "./contract.mjs";
import { functionalActionOwners } from "./owners.mjs";

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

const validateOwnedLabel = (value) => {
  exact(value, ["name", "component"]);
  assert.equal(value.component, "basename");
  boundedText(value.name, 128);
  assert.match(value.name, /^[A-Za-z0-9_.-]+$/);
};
const validateSelector = (value) =>
  assert(["label", "help", "placeholder"].includes(value));
const boundedInput = (value) => {
  assert(
    typeof value === "string" &&
      value.length > 0 &&
      Buffer.byteLength(value) <= 4096,
  );
  assert(
    [...value].every((character) => {
      const code = character.codePointAt(0);
      return code !== 127 && (code > 31 || [9, 10, 13].includes(code));
    }),
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
  const settingsSections = {
    notchShelf: "extension",
    systemStats: "extension",
    quinjet: "extension",
    herdr: "backgroundAgent",
  };
  assert.equal(
    recipe.section,
    recipe.location === "settings" && settingsSections[recipe.owner]
      ? settingsSections[recipe.owner]
      : recipe.owner,
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
    for (const key of ["selector", "ownedLabel", "when"])
      if (Object.hasOwn(step, key)) fields.push(key);
    exact(step, fields);
    if (step.scope) {
      const fields = ["kind", "label"];
      if (Object.hasOwn(step.scope, "anchor")) fields.push("anchor");
      if (Object.hasOwn(step.scope, "ownedLabel")) fields.push("ownedLabel");
      exact(step.scope, fields);
      assert(
        ["window", "sheet", "menu", "row", "panel", "group", "button"].includes(
          step.scope.kind,
        ),
      );
      if (step.scope.ownedLabel) {
        validateOwnedLabel(step.scope.ownedLabel);
        assert.equal(step.scope.label, "");
      }
      if (step.scope.label !== "") boundedText(step.scope.label, 512);
      else
        assert(
          step.scope.anchor || step.scope.ownedLabel,
          "An unlabeled original scope requires a source anchor",
        );
      if (step.scope.anchor) {
        const fields = ["role", "label"];
        for (const key of ["selector", "ownedLabel"])
          if (Object.hasOwn(step.scope.anchor, key)) fields.push(key);
        exact(step.scope.anchor, fields);
        if (step.scope.anchor.selector)
          validateSelector(step.scope.anchor.selector);
        if (step.scope.anchor.ownedLabel) {
          validateOwnedLabel(step.scope.anchor.ownedLabel);
          assert.equal(step.scope.anchor.label, "");
        }
        assert(
          ["staticText", "button", "textField", "menuItem"].includes(
            step.scope.anchor.role,
          ),
        );
        if (!step.scope.anchor.ownedLabel)
          boundedText(step.scope.anchor.label, 512);
      }
    }
    if (step.ownedPath !== undefined) {
      boundedText(step.ownedPath, 128);
      assert.match(step.ownedPath, /^[A-Za-z0-9_.-]+$/);
    }
    if (step.selector) validateSelector(step.selector);
    if (step.ownedLabel) {
      validateOwnedLabel(step.ownedLabel);
      assert.equal(step.label, "");
    }
    if (step.label === "") assert(step.ownedLabel || step.scope?.anchor);
    else boundedText(step.label);
    assert(
      [
        "checkBox",
        "button",
        "textField",
        "secureTextField",
        "popUpButton",
        "menuItem",
        "row",
        "slider",
        "stepper",
        "column",
        "staticText",
        "textArea",
      ].includes(step.role),
    );
    if (step.action === "set-checkbox") {
      assert.equal(step.role, "checkBox");
      assert.equal(typeof step.value, "boolean");
    } else if (step.action === "select-menu") {
      assert.equal(step.role, "popUpButton");
      boundedText(step.value);
    } else if (step.action === "replace-text") {
      assert(["textField", "secureTextField", "textArea"].includes(step.role));
      boundedInput(step.value);
    } else if (step.action === "choose-owned-path") {
      assert.equal(step.role, "button");
      assert(["Save", "Choose", "Open", "Scan"].includes(step.label));
      assert.equal(step.value, null);
      assert(step.ownedPath);
      assert.equal(step.scope?.kind, "panel");
    } else if (step.action === "set-slider") {
      assert.equal(step.role, "slider");
      assert(Number.isFinite(step.value) && step.value >= 0 && step.value <= 1);
    } else if (step.action === "set-column-width") {
      assert.equal(step.role, "column");
      assert(
        Number.isFinite(step.value) && step.value >= 64 && step.value <= 2048,
      );
    } else if (step.action === "show-menu") {
      assert(["row", "button", "staticText"].includes(step.role));
      assert.equal(step.value, null);
    } else if (["increment", "decrement"].includes(step.action)) {
      assert.equal(step.role, "stepper");
      assert.equal(step.value, null);
    } else if (step.action === "submit") {
      assert.equal(step.role, "textField");
      assert.equal(step.value, null);
    } else {
      assert.equal(step.action, "click");
      assert.equal(step.value, null);
      assert(
        ["button", "popUpButton", "menuItem", "row", "column"].includes(
          step.role,
        ),
      );
    }
    assert(step.action === "choose-owned-path" || step.ownedPath === undefined);
    if (step.when !== undefined) {
      assert(["value-differs", "not-selected"].includes(step.when));
      if (step.when === "value-differs")
        assert(["set-checkbox", "select-menu"].includes(step.action));
      else assert.equal(step.action, "click");
    }
    if (step.selector === "placeholder") assert.equal(step.role, "textField");
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
    "stepInventories",
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
    observed.presentationID,
    installedPresentationID(admittedCapability),
  );
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
  const template = Object.fromEntries(
    Object.entries(capability).filter(
      ([key]) => !["engine", "ui"].includes(key),
    ),
  );
  const bytes = Buffer.from(functionalDigest(template).slice(0, 32), "hex");
  bytes[6] = (bytes[6] & 15) | 64;
  bytes[8] = (bytes[8] & 63) | 128;
  const hex = bytes.toString("hex");
  return [
    hex.slice(0, 8),
    hex.slice(8, 12),
    hex.slice(12, 16),
    hex.slice(16, 20),
    hex.slice(20),
  ].join("-");
}

export function heldInstalledPresentationSteps(recipe, definition, capability) {
  validateInstalledPresentationRecipe(recipe, definition);
  validateFunctionalCapability(capability, definition);
  return recipe.steps.map((step) => {
    const label = (entry) => {
      if (!entry.ownedLabel) return entry.label;
      const path = capability.ownedPaths.find(
        ({ name }) => name === entry.ownedLabel.name,
      );
      assert(path, "Missing source-derived label capability");
      return path.path.split("/").at(-1);
    };
    const originalScope = step.scope ?? {
      kind: "window",
      label: installedPresentationWindowTitle(capability),
    };
    const scope = { ...originalScope, label: label(originalScope) };
    if (scope.anchor)
      scope.anchor = { ...scope.anchor, label: label(scope.anchor) };
    const value = step.value;
    if (step.action === "choose-owned-path") {
      const path = capability.ownedPaths.find(
        (entry) => entry.name === step.ownedPath,
      );
      assert(path, "Missing independently admitted named chooser capability");
      assert(path.path.startsWith(`${capability.fixtureRoot}/`));
      assert(["file", "directory"].includes(path.kind));
    }
    return Object.freeze({
      ...step,
      label: label(step),
      scope,
      ownedPath: step.ownedPath ?? null,
      value,
    });
  });
}

export function installedPresentationWindowTitle(capability) {
  assert.match(capability.session, uuid);
  assert(["initial", "updated", "reinstalled"].includes(capability.phase));
  return `Synthetic functional ${capability.owner} ${capability.phase} ${capability.session}`;
}

function installedControlTypes() {
  return `    struct Step: Decodable {
        let role: String
        let label: String
        let action: String
        let value: Value
        let scope: Scope
        let ownedPath: String?
        let selector: String?
        let when: String?
        struct Scope: Decodable {
            let kind: String
            let label: String
            let anchor: Anchor?
            struct Anchor: Decodable { let role: String; let label: String; let selector: String? }
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

`;
}

function installedSecureInputSource(sourceCommit) {
  return `    private func pasteSyntheticSecureValue(_ value: String, into control: XCUIElement) throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["GITHUB_ACTIONS"] == "true", environment["RUNNER_ENVIRONMENT"] == "github-hosted",
            environment["RUNNER_OS"] == "macOS", environment["GITHUB_REPOSITORY"] == "pulkitxm/edith",
            environment["GITHUB_EVENT_NAME"] == "pull_request",
            environment["GITHUB_REPOSITORY_ID"] == "1289153439",
            environment["GITHUB_REF"] == "refs/pull/1014/merge",
            environment["GITHUB_SHA"] != "${sourceCommit}",
            environment["EXPECTED_SOURCE_SHA"] == "${sourceCommit}",
            environment["EDITH_HOSTED_FUNCTIONAL_ACTIONS"] == "1",
            value.utf8.count <= 4096, !value.utf8.contains(0)
        else { throw NSError(domain: "Synthetic secure input admission", code: 1) }
        let pasteboard = NSPasteboard.general
        guard (pasteboard.pasteboardItems ?? []).isEmpty else {
            throw NSError(domain: "Synthetic clipboard initial ownership", code: 1) }
        let initialCount = pasteboard.changeCount
        guard pasteboard.changeCount == initialCount else {
            throw NSError(domain: "Synthetic clipboard changed before input", code: 1) }
        pasteboard.clearContents()
        guard pasteboard.setString(value, forType: .string) else {
            throw NSError(domain: "Synthetic clipboard input", code: 1) }
        let ownedCount = pasteboard.changeCount
        defer {
            if pasteboard.changeCount == ownedCount { pasteboard.clearContents() }
        }
        control.typeKey("v", modifierFlags: .command)
        guard pasteboard.changeCount == ownedCount else {
            throw NSError(domain: "Synthetic clipboard ownership changed", code: 1) }
    }

`;
}

function installedControlActionSource() {
  return `    private func perform(_ step: Step, application: XCUIApplication, windows: XCUIElementQuery, window: XCUIElement, ownedPaths: [String: String]) throws {
            let type: XCUIElement.ElementType
            switch step.role {
            case "checkBox": type = .checkBox
            case "button": type = .button
            case "textField": type = .textField
            case "secureTextField": type = .secureTextField
            case "popUpButton": type = .popUpButton
            case "menuItem": type = .menuItem
            case "row": type = .tableRow
            case "slider": type = .slider
            case "stepper": type = .stepper
            case "column": type = .tableColumn
            case "staticText": type = .staticText
            case "textArea": type = .textView
            default: XCTFail("Unsupported original control"); return
            }
            let scopes: XCUIElementQuery
            switch step.scope.kind {
            case "window": scopes = windows
            case "sheet": scopes = window.sheets
            case "menu": scopes = application.menus
            case "row": scopes = window.descendants(matching: .tableRow)
            case "panel": scopes = application.windows
            case "group": scopes = window.descendants(matching: .group)
            case "button": scopes = window.buttons
            default: XCTFail("Unsupported original scope"); return
            }
            let deadline = Date().addingTimeInterval(30)
            func sourceScopes() -> [XCUIElement] {
                scopes.allElementsBoundByIndex.filter { candidate in
                    if !step.scope.label.isEmpty && candidate.label != step.scope.label && candidate.identifier != step.scope.label { return false }
                    if let anchor = step.scope.anchor {
                        let types: [String: XCUIElement.ElementType] = ["staticText": .staticText, "button": .button, "textField": .textField, "menuItem": .menuItem]
                        guard let anchorType = types[anchor.role] else { return false }
                        guard matching(candidate, application: application, type: anchorType, label: anchor.label, selector: anchor.selector ?? "label", deadline: deadline).count == 1 else { return false }
                    }
                    return matching(candidate, application: application, type: type, label: step.label, selector: step.selector ?? "label", deadline: deadline).count == 1
                }
            }
            func innermostScopes() -> [XCUIElement] {
                let candidates = sourceScopes()
                return candidates.filter { candidate in
                    !candidates.contains { child in child != candidate && candidate.descendants(matching: .any).allElementsBoundByIndex.contains(child) }
                }
            }
            XCTAssertTrue(wait(30) { innermostScopes().count == 1 })
            let innermost = innermostScopes()
            XCTAssertEqual(innermost.count, 1)
            let scoped = try XCTUnwrap(innermost.first)
            let controls = matching(scoped, application: application, type: type, label: step.label, selector: step.selector ?? "label", deadline: deadline)
            XCTAssertEqual(controls.count, 1)
            let control = try XCTUnwrap(controls.first)
            if let condition = step.when {
                switch condition {
                case "value-differs":
                    if case .boolean(let desired) = step.value {
                        let current = control.value as? String
                        XCTAssertTrue(current == "0" || current == "1")
                        if current == (desired ? "1" : "0") { return }
                    } else if case .text(let desired) = step.value {
                        let current = try XCTUnwrap(control.value as? String)
                        if current == desired { return }
                    } else { XCTFail("Invalid source value condition"); return }
                case "not-selected":
                    if control.isSelected { return }
                default: XCTFail("Invalid source condition"); return
                }
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
            case ("select-menu", .text(let value)):
                let before = try XCTUnwrap(control.value as? String)
                XCTAssertNotEqual(before, value)
                control.click()
                let options = application.menus.descendants(matching: .menuItem).matching(NSPredicate(format: "label == %@", value))
                XCTAssertTrue(wait(15) { options.count == 1 && options.element(boundBy: 0).isHittable })
                XCTAssertEqual(options.count, 1)
                options.element(boundBy: 0).click()
                XCTAssertTrue(wait(15) { control.value as? String == value })
            case ("replace-text", .text(let value)):
                control.click()
                control.typeKey("a", modifierFlags: .command)
                if step.role == "secureTextField" {
                    try pasteSyntheticSecureValue(value, into: control)
                } else {
                    control.typeText(value)
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
            case ("set-column-width", .number(let width)):
                XCTAssertGreaterThanOrEqual(width, 64)
                XCTAssertLessThanOrEqual(width, 2048)
                let original = control.frame.width
                XCTAssertGreaterThanOrEqual(abs(original - width), 1)
                let start = control.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0)).withOffset(CGVector(dx: -1, dy: 4))
                let end = start.withOffset(CGVector(dx: width - original, dy: 0))
                start.click(forDuration: 0.1, thenDragTo: end)
                XCTAssertTrue(wait(15) { abs(control.frame.width - width) <= 2 })
            case ("show-menu", .null): control.rightClick()
            case ("increment", .null): control.buttons["Increment"].click()
            case ("decrement", .null): control.buttons["Decrement"].click()
            case ("submit", .null): control.typeKey(.return, modifierFlags: [])
            case ("click", .null): control.click()
            default: XCTFail("Invalid original control action"); return
            }

    }
`;
}

function installedControlQuerySource() {
  return `    private func matching(_ root: XCUIElement, application: XCUIApplication, type: XCUIElement.ElementType, label: String, selector: String, deadline: Date) -> [XCUIElement] {
        var candidates = root.descendants(matching: type).allElementsBoundByIndex
        if root.elementType == type { candidates.insert(root, at: 0) }
        guard candidates.count <= 128, Date() < deadline else { return [] }
        switch selector {
        case "label": return candidates.filter { label.isEmpty || $0.label == label || $0.identifier == label }
        case "placeholder": return candidates.filter { $0.placeholderValue == label }
        case "help":
            guard candidates.count <= 32 else { return [] }
            var matches: [XCUIElement] = []
            for candidate in candidates where candidate.isHittable && Date() < deadline {
                root.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0)).hover()
                guard wait(min(1, max(0, deadline.timeIntervalSinceNow)), { application.helpTags.count == 0 }) else { return [] }
                candidate.hover()
                let tags = application.helpTags.matching(NSPredicate(format: "label == %@", label))
                if wait(min(1, max(0, deadline.timeIntervalSinceNow)), { tags.count == 1 }) { matches.append(candidate) }
            }
            return matches
        default: XCTFail("Invalid source selector"); return []
        }
    }

    private func wait(_ seconds: TimeInterval, _ condition: @escaping () -> Bool) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        return XCTWaiter.wait(for: [expectation], timeout: seconds) == .completed
    }`;
}

export function installedPresentationControlTestSource(
  recipe,
  definition,
  capability,
) {
  validateInstalledPresentationRecipe(recipe, definition);
  validateFunctionalCapability(capability, definition);
  const heldSteps = heldInstalledPresentationSteps(
    recipe,
    definition,
    capability,
  );
  const encoded = Buffer.from(JSON.stringify(heldSteps)).toString("base64");
  const identifier = JSON.stringify(capability.hostIdentifier);
  const title = JSON.stringify(installedPresentationWindowTitle(capability));
  const ownedPaths = `[${capability.ownedPaths.map(({ name, path }) => `${JSON.stringify(name)}: ${JSON.stringify(path)}`).join(", ")}]`;
  return `import AppKit
import Foundation
import XCTest

@MainActor
final class HostedFunctionalInstalledUITests: XCTestCase {
${installedControlTypes()}${installedSecureInputSource(capability.sourceCommit)}
${installedControlActionSource()}
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
            try perform(step, application: application, windows: windows, window: window, ownedPaths: ownedPaths)
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

${installedControlQuerySource()}
}
`;
}

export function installedPresentationUITestSource({ plan, issuerPublicKey }) {
  assert.match(plan.sourceCommit, /^[0-9a-f]{40}$/);
  assert.match(plan.session, uuid);
  assert.equal(resolve(plan.root), plan.root);
  assert.equal(
    plan.hostIdentifier,
    `com.pulkit.edith.tests.worker-${plan.session}`,
  );
  assert.match(issuerPublicKey, /^[A-Za-z0-9+/]{43}=$/);
  assert.equal(
    Buffer.from(issuerPublicKey, "base64").toString("base64"),
    issuerPublicKey,
  );
  assert.equal(plan.definitions.length, 39);
  assert.deepEqual(
    plan.definitions.map(({ owner }) => owner).sort(),
    [...functionalActionOwners].sort(),
  );
  assert.deepEqual(
    Object.keys(plan.recipes).sort(),
    [...functionalActionOwners].sort(),
  );
  for (const definition of plan.definitions)
    validateInstalledPresentationRecipe(
      plan.recipes[definition.owner],
      definition,
    );
  const data = Object.entries(plan.recipes)
    .map(
      ([owner, recipe]) =>
        `${JSON.stringify(owner)}: Data(base64Encoded: ${JSON.stringify(Buffer.from(functionalCanonicalJSON(recipe)).toString("base64"))})!`,
    )
    .join(",\n        ");
  const digests = Object.entries(plan.recipes)
    .map(
      ([owner, recipe]) =>
        `${JSON.stringify(owner)}: ${JSON.stringify(functionalDigest(recipe))}`,
    )
    .join(", ");
  return `import AppKit
import CryptoKit
import Darwin
import Foundation
import XCTest

@MainActor
final class HostedFunctionalInstalledUITests: XCTestCase {
    private let sourceCommit = ${JSON.stringify(plan.sourceCommit)}
    private let session = ${JSON.stringify(plan.session)}
    private let root = ${JSON.stringify(plan.root)}
    private let hostIdentifier = ${JSON.stringify(plan.hostIdentifier)}
    private let issuerPublicKey = Data(base64Encoded: ${JSON.stringify(issuerPublicKey)})!
    private let producerIdentifier = ${JSON.stringify(plan.producerIdentifier)}
    private let certificate = Data(base64Encoded: ${JSON.stringify(plan.certificateSHA256)})!
    private let recipes: [String: Data] = [${data}]
    private let recipeDigests: [String: String] = [${digests}]
${installedControlTypes()}
${installedSecureInputSource(plan.sourceCommit)}
${installedControlActionSource()}
${installedControlQuerySource()}
    private func signed(_ bytes: Data) throws -> [String: Any] {
        let envelope = try FunctionalBytes.object(bytes)
        try FunctionalBytes.exact(envelope, ["schema", "payload", "signature"])
        guard try FunctionalBytes.integer(envelope, "schema") == 1,
            let payload = envelope["payload"] as? String, let signatureText = envelope["signature"] as? String,
            let signature = Data(base64Encoded: signatureText), signature.count == 64,
            signature.base64EncodedString() == signatureText,
            try Curve25519.Signing.PublicKey(rawRepresentation: issuerPublicKey).isValidSignature(signature, for: Data(payload.utf8))
        else { throw FunctionalFailure.invalid("same live XCTest issuer signature") }
        let value = try FunctionalBytes.object(Data(payload.utf8))
        guard try FunctionalBytes.canonical(value) == Data(payload.utf8) else { throw FunctionalFailure.invalid("canonical XCTest signed payload") }
        return value
    }

    private func originalSteps(_ recipe: [String: Any], invocation: [String: Any]) throws -> [[String: Any]] {
        guard let values = recipe["steps"] as? [[String: Any]], let paths = invocation["ownedPaths"] as? [String: String],
            let windowTitle = invocation["windowTitle"] as? String else { throw FunctionalFailure.invalid("compiled XCTest step inputs") }
        func label(_ original: [String: Any]) throws -> [String: Any] {
            var value = original
            if let reference = value["ownedLabel"] as? [String: String] {
                guard reference["component"] == "basename", let name = reference["name"], let path = paths[name], path.hasPrefix(root + "/") else { throw FunctionalFailure.invalid("source owned XCTest label") }
                value["label"] = URL(fileURLWithPath: path).lastPathComponent
            }
            return value
        }
        return try values.map { original in
            var value = try label(original)
            var scope = try label(value["scope"] as? [String: Any] ?? ["kind": "window", "label": windowTitle])
            if let anchor = scope["anchor"] as? [String: Any] { scope["anchor"] = try label(anchor) }
            value["scope"] = scope
            if value["ownedPath"] == nil { value["ownedPath"] = NSNull() }
            return value
        }
    }

    private func calendarControlSnapshot(_ window: XCUIElement) throws -> [String: Any] {
        let labels = window.staticTexts.allElementsBoundByIndex.filter { $0.exists && $0.isHittable }.map { $0.label }
        guard labels.count <= 512, labels.allSatisfy({ $0.utf8.count <= 4096 && !$0.utf8.contains(0) }) else { throw FunctionalFailure.invalid("bounded actual Calendar visible static texts") }
        let value: [String: Any] = ["schema": 1, "kind": "calendar-details", "visibleStaticTexts": labels]
        guard try FunctionalBytes.canonical(value).count <= 131_072 else { throw FunctionalFailure.invalid("bounded actual Calendar snapshot bytes") }
        return value
    }

    private func boundary(_ operation: String, invocation: [String: Any], index: Int, stepSHA256: String, authorization: [String: Any]?, localControl: [String: Any]?) throws -> [String: Any] {
        let requestID = UUID().uuidString.lowercased()
        var message: [String: Any] = ["schema": 1, "sourceCommit": sourceCommit, "session": session,
            "requestID": requestID, "operation": operation, "owner": invocation["owner"]!, "phase": invocation["phase"]!,
            "stepIndex": index, "presentationID": invocation["presentationID"]!, "capabilitySHA256": invocation["capabilitySHA256"]!, "stepSHA256": stepSHA256]
        if invocation["owner"] as? String == "calendar" {
            guard index == 0, let localControl else { throw FunctionalFailure.invalid("missing original Calendar local snapshot") }
            message["localControl"] = localControl
        } else {
            guard localControl == nil else { throw FunctionalFailure.invalid("foreign local control snapshot") }
        }
        if let authorization { message["authorizationID"] = authorization["authorizationID"]! }
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        let descriptor = try FunctionalSocketWire.connect(path: root + "/p.sock", deadline: deadline)
        defer { Darwin.close(descriptor) }
        let peer = try FunctionalSocketPeer(descriptor: descriptor)
        let executable = root + "/Producer/functional-producer"
        guard peer.birth.executable == executable else { throw FunctionalFailure.invalid("XCTest actual producer executable") }
        try FunctionalSigner(identifier: producerIdentifier, certificateSHA256: certificate,
            requirement: ${JSON.stringify(`identifier "${plan.producerIdentifier}"`)}).verify(URL(fileURLWithPath: executable), birth: peer.birth)
        try FunctionalSocketWire.writeFrame(FunctionalBytes.canonical(message), descriptor: descriptor, deadline: deadline)
        let response = try signed(FunctionalSocketWire.readFrame(descriptor, deadline: deadline))
        try peer.birth.requireCurrent()
        var fields: Set<String> = ["schema", "sourceCommit", "session", "requestID", "operation", "owner", "phase", "authorizationID", "actor", "stepIndex", "stepSHA256", "sourceSHA256", "presentationID", "capabilitySHA256", "firstEventOrdinal", "lastEventOrdinal"]
        if let localControl {
            fields.insert("localControlSHA256")
            guard response["localControlSHA256"] as? String == FunctionalBytes.digest(try FunctionalBytes.canonical(localControl)) else { throw FunctionalFailure.invalid("Calendar signed actual snapshot digest") }
        }
        try FunctionalBytes.exact(response, fields)
        guard try FunctionalBytes.integer(response, "schema") == 1,
            response["sourceCommit"] as? String == sourceCommit, response["session"] as? String == session,
            response["requestID"] as? String == requestID, response["operation"] as? String == operation,
            response["owner"] as? String == invocation["owner"] as? String, response["phase"] as? String == invocation["phase"] as? String,
            try FunctionalBytes.integer(response, "stepIndex") == index,
            response["stepSHA256"] as? String == stepSHA256,
            response["sourceSHA256"] as? String == invocation["sourceSHA256"] as? String,
            response["presentationID"] as? String == invocation["presentationID"] as? String,
            response["capabilitySHA256"] as? String == invocation["capabilitySHA256"] as? String,
            let authorizationID = response["authorizationID"] as? String, FunctionalBytes.uuid(authorizationID),
            let actor = response["actor"] as? [String: Any],
            try FunctionalBytes.canonical(actor) == FunctionalBytes.canonical(FunctionalBirth.observe(getpid()).object),
            try FunctionalBytes.integer(response, "firstEventOrdinal") >= 0,
            try FunctionalBytes.integer(response, "lastEventOrdinal") >= FunctionalBytes.integer(response, "firstEventOrdinal")
        else { throw FunctionalFailure.invalid("actual XCTest source action boundary") }
        if let authorization {
            guard response["authorizationID"] as? String == authorization["authorizationID"] as? String,
                try FunctionalBytes.integer(response, "firstEventOrdinal") == FunctionalBytes.integer(authorization, "firstEventOrdinal"),
                try FunctionalBytes.canonical(actor) == FunctionalBytes.canonical(authorization["actor"]!)
            else { throw FunctionalFailure.invalid("XCTest action boundary changed actual actor") }
        }
        return response
    }

    func testOriginalDownloadedPresentationAction() throws {
        continueAfterFailure = false
        guard let path = ProcessInfo.processInfo.environment["EDITH_FUNCTIONAL_XCTEST_INVOCATION"] else { throw FunctionalFailure.invalid("source owned XCTest invocation selector") }
        let invocationFile = try FunctionalPinnedPath(URL(fileURLWithPath: path), directory: false, privateMode: true, maximum: 1_048_576)
        let invocation = try signed(invocationFile.read())
        try FunctionalBytes.exact(invocation, ["schema", "sourceCommit", "session", "owner", "phase", "presentationID", "capabilitySHA256", "recipeSHA256", "sourceSHA256", "fixtureRoot", "hostIdentifier", "windowTitle", "steps", "ownedPaths"])
        guard try FunctionalBytes.integer(invocation, "schema") == 1,
            invocation["sourceCommit"] as? String == sourceCommit, invocation["session"] as? String == session,
            invocation["fixtureRoot"] as? String == root, invocation["hostIdentifier"] as? String == hostIdentifier,
            let owner = invocation["owner"] as? String, let recipeBytes = recipes[owner],
            let phase = invocation["phase"] as? String, ["initial", "updated", "reinstalled"].contains(phase),
            path == root + "/XCTest/invocations/" + owner + "-" + phase + ".json",
            invocation["recipeSHA256"] as? String == recipeDigests[owner],
            let title = invocation["windowTitle"] as? String, title == "Synthetic functional " + owner + " " + phase + " " + session,
            let presentationID = invocation["presentationID"] as? String, FunctionalBytes.uuid(presentationID),
            let capabilitySHA256 = invocation["capabilitySHA256"] as? String, FunctionalBytes.hex(capabilitySHA256, length: 64),
            let sourceSHA256 = invocation["sourceSHA256"] as? String, FunctionalBytes.hex(sourceSHA256, length: 64),
            let ownedPaths = invocation["ownedPaths"] as? [String: String], ownedPaths.values.allSatisfy({ $0.hasPrefix(root + "/") })
        else { throw FunctionalFailure.invalid("compiled XCTest current source invocation") }
        let sourceFile = try FunctionalPinnedPath(URL(fileURLWithPath: root + "/XCTest/HostedFunctionalInstalledUITests.swift"), directory: false, privateMode: true, maximum: 1_048_576)
        guard FunctionalBytes.digest(try sourceFile.read()) == sourceSHA256 else { throw FunctionalFailure.invalid("XCTest source bytes changed") }
        let recipe = try FunctionalBytes.object(recipeBytes)
        let original = try originalSteps(recipe, invocation: invocation)
        guard try FunctionalBytes.canonical(original) == FunctionalBytes.canonical(invocation["steps"]!) else { throw FunctionalFailure.invalid("XCTest caller supplied recipe") }
        let steps = try JSONDecoder().decode([Step].self, from: FunctionalBytes.canonical(original))
        let application = XCUIApplication(bundleIdentifier: hostIdentifier)
        XCTAssertEqual(application.state, .runningForeground)
        let windows = application.windows.matching(NSPredicate(format: "label == %@", title))
        XCTAssertTrue(wait(30) { windows.count == 1 })
        XCTAssertEqual(windows.count, 1)
        let window = windows.element(boundBy: 0)
        for (index, step) in steps.enumerated() {
            try invocationFile.requireCurrent()
            let digest = FunctionalBytes.digest(try FunctionalBytes.canonical(original[index]))
            let beforeLocal = owner == "calendar" ? try calendarControlSnapshot(window) : nil
            let authorization = try boundary("authorize-original-step", invocation: invocation, index: index, stepSHA256: digest, authorization: nil, localControl: beforeLocal)
            try perform(step, application: application, windows: windows, window: window, ownedPaths: ownedPaths)
            let afterLocal = owner == "calendar" ? try calendarControlSnapshot(window) : nil
            _ = try boundary("complete-original-step", invocation: invocation, index: index, stepSHA256: digest, authorization: authorization, localControl: afterLocal)
        }
        try invocationFile.requireCurrent()
        let bytes = try FunctionalBytes.canonical(["schema": 1, "sourceCommit": sourceCommit, "owner": owner,
            "session": session, "phase": phase, "capabilitySHA256": capabilitySHA256,
            "recipeSHA256": recipeDigests[owner]!, "sourceSHA256": sourceSHA256, "producerObservationRequired": true])
        let attachment = XCTAttachment(data: bytes, uniformTypeIdentifier: "public.json")
        attachment.name = "Original downloaded functional action"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
`;
}
