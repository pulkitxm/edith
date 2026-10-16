import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { definition } from "./cases/notchShelf.mjs";
import {
  functionalDigest,
  validateFunctionalCapability,
  validateFunctionalRequest,
} from "./contract.mjs";
import {
  functionalLiteralJSON,
  validateFunctionalLiteralPolicies,
  validateFunctionalPreparationPolicy,
  validateFunctionalSavedReaderPolicy,
} from "./controller.mjs";
import { functionalFixtureRolePolicySource } from "./fixture-trust.mjs";
import { functionalActionOwners } from "./owners.mjs";

const hash = (bytes) => createHash("sha256").update(bytes).digest("hex");
const document = async (directory) =>
  functionalLiteralJSON(
    await readFile(new URL(`./${directory}/notchShelf.json`, import.meta.url)),
  );
const policy = await document("policies");
const preparation = await document("preparation");
const saved = await document("saved-readers");
const recipe = await document("presentations");
const nativePath =
  "Tests/HostedFunctionalActions/OwnerCases/notchShelfActionCase.swift";
const native = await readFile(new URL(`../../${nativePath}`, import.meta.url));
const manifestBytes = await readFile(
  new URL("../../Extensions/manifest.json", import.meta.url),
);
const manifest = JSON.parse(manifestBytes);
const sourceCommit = "3267aa9e5f4ffda2bb9365a60563ae84fc0d4741";

function syntheticCompilerCounterfixture() {
  const cases = [],
    recipes = {},
    nativeSources = {},
    literalPolicies = {};
  for (const owner of functionalActionOwners) {
    const selected = owner === "notchShelf";
    const bytes = selected
      ? native
      : Buffer.from(`struct SyntheticCase { static let owner = "${owner}" }`);
    const source = `Tests/HostedFunctionalActions/OwnerCases/${owner}ActionCase.swift`;
    const item = selected
      ? structuredClone(definition)
      : {
          schema: 1,
          owner,
          activation: {
            kind: "native-accessibility",
            control: "Synthetic compiler control",
            operation: `${owner}.probe`,
            mutation: { kind: "state-transition", payloadKeys: ["value"] },
            sources: [
              {
                path: `Extensions/${owner}/Runtime.swift`,
                sha256: "a".repeat(64),
              },
            ],
          },
          operations: [`${owner}.probe`],
          observation: {
            kind: "checked-engine-readback",
            name: "synthetic compiler observation",
          },
          persistence: {
            applicable: false,
            name: "no-owned-persistent-record",
          },
          limits: ["synthetic-platform-adapter"],
        };
    const presentation = selected
      ? structuredClone(recipe)
      : {
          schema: 1,
          owner,
          location: "main",
          section: owner,
          operation: item.activation.operation,
          steps: [
            {
              role: "checkBox",
              label: "Synthetic compiler control",
              action: "set-checkbox",
              value: true,
            },
          ],
          sources: item.activation.sources,
        };
    cases.push({
      definition: item,
      sourceCommit,
      sourcePins: [{ path: source, sha256: hash(bytes) }],
    });
    recipes[owner] = { recipe: presentation };
    nativeSources[owner] = bytes;
    literalPolicies[owner] = selected
      ? structuredClone(policy)
      : {
          owner,
          primaryRole: Object.hasOwn(
            manifest.find(({ id }) => id === owner).roles,
            "app",
          )
            ? "app"
            : "helper",
          operations: item.operations,
          presentations: [{ location: "main", section: owner }],
          inputs: [],
          outputs: [],
          fileScopes: [],
        };
  }
  return {
    cases,
    recipes,
    manifestBytes,
    nativeSources,
    literalPolicies,
    sourceCommit,
  };
}

function compile(counterfixture) {
  const admitted = validateFunctionalLiteralPolicies(counterfixture);
  return functionalFixtureRolePolicySource(
    admitted.policyBytes,
    admitted.admittedPolicies,
  );
}

test("actual Notch policy passes the closed compiler with current manifest and original native source", () => {
  const fixture = syntheticCompilerCounterfixture();
  const compiled = compile(fixture);
  const selected = compiled.swiftExpression
    .split("\n")
    .find((line) => line.includes('owner: "notchShelf"'));
  assert(selected.includes("primaryRole: .helper"));
  assert(
    selected.includes(
      'operations: ["notch.settings.read", "notch.settings.write", "notchShelf.cli.catalog"]',
    ),
  );
  assert(selected.includes('location: "settings", section: "extension"'));
  assert(selected.includes(".workerDefaultsPlist(.engine)"));
  assert(selected.includes(`manifestSHA256: "${hash(manifestBytes)}"`));
  assert(selected.includes(`caseSHA256: "${hash(native)}"`));
  assert.deepEqual(policy.operations, definition.operations);
  assert.deepEqual(policy.inputs, []);
  assert.deepEqual(policy.outputs, []);
});

test("removing catalog metadata or adding feature actions fails the existing Notch compiler guard", () => {
  for (const operations of [
    ["notch.settings.read", "notch.settings.write"],
    [...policy.operations, "notch.browser.detach"],
    [...policy.operations, "notch.panel.attach"],
  ]) {
    const fixture = syntheticCompilerCounterfixture();
    fixture.literalPolicies.notchShelf.operations = operations;
    fixture.cases.find(
      ({ definition }) => definition.owner === "notchShelf",
    ).definition.operations = operations;
    assert.throws(() => compile(fixture));
  }
});

test("wrong role, changed manifest, changed native source and mismatched exact source fail policy admission", () => {
  const changes = [
    (f) => {
      f.literalPolicies.notchShelf.primaryRole = "app";
    },
    (f) => {
      f.manifestBytes = Buffer.from(
        f.manifestBytes
          .toString()
          .replace('"id": "notchShelf"', '"id": "foreign"'),
      );
    },
    (f) => {
      f.nativeSources.notchShelf = Buffer.concat([native, Buffer.from("\n")]);
    },
    (f) => {
      f.cases.find(
        ({ definition }) => definition.owner === "notchShelf",
      ).sourceCommit = "b".repeat(40);
    },
    (f) => {
      delete f.literalPolicies.notchShelf;
    },
  ];
  for (const change of changes) {
    const fixture = syntheticCompilerCounterfixture();
    change(fixture);
    assert.throws(() => compile(fixture));
  }
});

test("owned engine preference starts absent and preparation cannot preseed successful state", () => {
  assert.equal(
    validateFunctionalPreparationPolicy(preparation, policy),
    preparation,
  );
  assert.deepEqual(preparation.files, []);
  assert.equal(policy.fileScopes.length, 1);
  assert.equal(policy.fileScopes[0].initialState, "absent");
  assert.deepEqual(policy.fileScopes[0].allowedStates, ["absent", "present"]);
  assert.equal(policy.fileScopes[0].maximumBytes, 1048576);
  assert.equal(policy.fileScopes[0].maximumEntries, 1);
  assert.equal(validateFunctionalSavedReaderPolicy(saved, policy), saved);
  for (const components of [
    policy.fileScopes[0].components,
    [
      { literal: "Library" },
      { literal: "Preferences" },
      { literal: "production.plist" },
    ],
  ]) {
    assert.throws(() =>
      validateFunctionalPreparationPolicy(
        {
          ...preparation,
          files: [
            {
              root: "owner-home",
              components,
              codec: "property-list",
              value: { notchShelfRequireOption: true },
              maximumBytes: 1048576,
            },
          ],
        },
        policy,
      ),
    );
  }
  assert.throws(() =>
    validateFunctionalPreparationPolicy(
      { ...preparation, owner: "music" },
      policy,
    ),
  );
  const initialPresent = structuredClone(policy);
  initialPresent.fileScopes[0].initialState = "present";
  assert.throws(() =>
    validateFunctionalPreparationPolicy(preparation, initialPresent),
  );
});

test("foreign defaults, roots, traversal and excess file grants cannot replace the independent engine read", () => {
  const changes = [
    (p) => {
      p.fileScopes[0].components[2] = { workerDefaultsPlist: "ui" };
    },
    (p) => {
      p.fileScopes[0].components[2] = { literal: "production.plist" };
    },
    (p) => {
      p.fileScopes[0].root = "owner-data";
    },
    (p) => {
      p.fileScopes[0].components[0] = { literal: ".." };
    },
    (p) => {
      p.fileScopes[0].maximumBytes -= 1;
    },
    (p) => {
      p.fileScopes = [];
    },
  ];
  for (const change of changes) {
    const changed = structuredClone(policy);
    change(changed);
    assert.throws(() => validateFunctionalSavedReaderPolicy(saved, changed));
  }
});

const session = "12345678-1234-4123-8123-123456789abc";
function capability(phase) {
  const root = `/private/synthetic/functional-fixture-${session}`;
  const identity = (pid) => ({
    pid,
    birthSeconds: 1000,
    birthMicroseconds: pid,
    uid: 501,
    executableSHA256: "a".repeat(64),
  });
  return {
    schema: 1,
    sourceCommit,
    session,
    owner: "notchShelf",
    uid: 501,
    fixtureRoot: root,
    hostIdentifier: `com.pulkit.edith.tests.worker-${session}`,
    home: `${root}/notchShelf-home`,
    dataDirectory: `${root}/Edith Tests/worker-${session}/Data/notchShelf`,
    hostABI: "edith-host-2",
    caseSHA256: functionalDigest(definition),
    activationOperation: "notch.settings.write",
    phase,
    pairScope: "synthetic-development",
    previousVersion: "1.0.0",
    currentVersion: "1.1.0",
    version: phase === "initial" ? "1.0.0" : "1.1.0",
    packageSHA256: (phase === "initial" ? "b" : "c").repeat(64),
    engine: identity(12),
    ui: identity(13),
    operations: policy.operations,
    ownedPaths: [
      {
        name: "preferences",
        kind: "file",
        path: `${root}/notchShelf-home/Library/Preferences/com.pulkit.edith.tests.worker-${session}.extensions.notchShelf.plist`,
      },
    ],
  };
}

test("Notch capability admits only the exact synthetic host, owner home and current phase version", () => {
  for (const phase of ["initial", "updated", "reinstalled"]) {
    const value = capability(phase);
    assert.equal(validateFunctionalCapability(value, definition), value);
    for (const change of [
      (v) => {
        v.hostIdentifier = "com.pulkit.edith";
      },
      (v) => {
        v.home = v.home.replace("notchShelf-home", "music-home");
      },
      (v) => {
        v.owner = "music";
      },
      (v) => {
        v.version = "9.0.0";
      },
      (v) => {
        v.ui.pid = v.engine.pid;
      },
      (v) => {
        v.operations = [...v.operations, "notch.browser.detach"];
      },
    ]) {
      const changed = structuredClone(value);
      change(changed);
      assert.throws(() => validateFunctionalCapability(changed, definition));
    }
  }
});

test("stale source, session, owner, phase, generation and feature requests fail current capability binding", () => {
  const current = capability("updated");
  const request = {
    schema: 1,
    sourceCommit,
    session,
    owner: current.owner,
    phase: current.phase,
    capabilitySHA256: functionalDigest(current),
    requestID: "12345678-1234-4123-8123-123456789abd",
    operation: "notch.settings.write",
    payloadSHA256: "d".repeat(64),
  };
  assert.equal(validateFunctionalRequest(request, current), request);
  for (const [field, value] of [
    ["sourceCommit", "e".repeat(40)],
    ["session", "12345678-1234-4123-8123-123456789abe"],
    ["owner", "music"],
    ["phase", "initial"],
    ["capabilitySHA256", "f".repeat(64)],
    ["operation", "notch.camera.capture"],
  ])
    assert.throws(() =>
      validateFunctionalRequest({ ...request, [field]: value }, current),
    );
});
