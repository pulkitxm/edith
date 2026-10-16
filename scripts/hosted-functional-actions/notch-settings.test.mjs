import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import test from "node:test";
import { loadFunctionalActionCase } from "./case-loader.mjs";
import { definition } from "./cases/notchShelf.mjs";
import {
  validateFunctionalObservationPolicy,
  validateFunctionalSavedReaderPolicy,
} from "./controller.mjs";
import {
  loadInstalledPresentationRecipe,
  validateInstalledPresentationRecipe,
} from "./presentation.mjs";
import { functionalProducerBootstrapSource } from "./producer-project.mjs";

const root = resolve(import.meta.dir, "../..");
const digest = (bytes) => createHash("sha256").update(bytes).digest("hex");
const native =
  "Tests/HostedFunctionalActions/OwnerCases/notchShelfActionCase.swift";
const casePath = "scripts/hosted-functional-actions/cases/notchShelf.mjs";
const snapshot = {
  sourceCommit: "1".repeat(40),
  files: await Promise.all(
    [
      casePath,
      native,
      ...definition.activation.sources.map(({ path }) => path),
    ].map(async (path) => ({
      path,
      sha256: digest(await readFile(resolve(root, path))),
    })),
  ),
};
const recipe = JSON.parse(
  await readFile(new URL("./presentations/notchShelf.json", import.meta.url)),
);
const saved = JSON.parse(
  await readFile(new URL("./saved-readers/notchShelf.json", import.meta.url)),
);
const observation = JSON.parse(
  await readFile(
    new URL("./observation-policies/notchShelf.json", import.meta.url),
  ),
);
const policy = {
  owner: "notchShelf",
  fileScopes: [
    {
      root: "owner-home",
      kind: "file",
      components: [
        { literal: "Library" },
        { literal: "Preferences" },
        { workerDefaultsPlist: "engine" },
      ],
      maximumBytes: 1048576,
    },
  ],
};

test("Notch settings binds the original control, model and signed preference receiver", async () => {
  const loaded = await loadFunctionalActionCase(
    root,
    "notchShelf",
    readFile,
    snapshot,
  );
  assert.equal(loaded.definition.activation.operation, "notch.settings.write");
  assert.equal(loaded.definition.activation.control, "Require ⌥ to trigger");
  assert.deepEqual(loaded.definition.activation.mutation.payloadKeys, [
    "key",
    "value",
  ]);
  const installed = await loadInstalledPresentationRecipe(
    root,
    "notchShelf",
    definition,
  );
  assert.equal(installed.recipe.section, "extension");
  assert.deepEqual(
    installed.recipe.steps.map(({ value }) => value),
    [false, true],
  );
});

test("changed original controls and changed native cases fail independent source admission", async () => {
  for (const changed of [
    native,
    ...definition.activation.sources.map(({ path }) => path),
  ]) {
    const read = async (path) => {
      const bytes = await readFile(path);
      return path === resolve(root, changed)
        ? Buffer.concat([bytes, Buffer.from("\n")])
        : bytes;
    };
    await assert.rejects(
      loadFunctionalActionCase(root, "notchShelf", read, snapshot),
    );
  }
});

test("presentation source drift and a recipe changed during admission are rejected", async () => {
  const changed = resolve(root, recipe.sources[0].path);
  await assert.rejects(
    loadInstalledPresentationRecipe(
      root,
      "notchShelf",
      definition,
      async (path) => {
        const bytes = await readFile(path);
        return path === changed
          ? Buffer.concat([bytes, Buffer.from("\n")])
          : bytes;
      },
    ),
  );
  let reads = 0;
  await assert.rejects(
    loadInstalledPresentationRecipe(
      root,
      "notchShelf",
      definition,
      async (path) => {
        const bytes = await readFile(path);
        if (path.endsWith("/presentations/notchShelf.json") && ++reads > 1)
          return Buffer.from("{}");
        return bytes;
      },
    ),
  );
});

test("Notch cannot redirect settings into a foreign section or arbitrary operation", () => {
  for (const [key, value] of [
    ["owner", "music"],
    ["section", "notchShelf"],
    ["operation", "notch.panel.attach"],
  ]) {
    const changed = structuredClone(recipe);
    changed[key] = value;
    assert.throws(() =>
      validateInstalledPresentationRecipe(changed, definition),
    );
  }
  const changed = structuredClone(recipe);
  changed.steps[0].value = "true";
  assert.throws(() => validateInstalledPresentationRecipe(changed, definition));
});

test("independent saved read admits only the scoped engine plist and typed option key", () => {
  assert.equal(validateFunctionalSavedReaderPolicy(saved, policy), saved);
  assert.deepEqual(saved.reads[0].components, [
    "Library",
    "Preferences",
    { derived: "engine-suite-plist" },
  ]);
  assert.deepEqual(saved.reads[0].selections, [
    {
      name: "requireOption",
      path: ["notchShelfRequireOption"],
      codec: "value",
    },
  ]);
  assert.deepEqual(saved.initial, {
    preferences: { requireOption: { present: false } },
  });
  assert.deepEqual(saved.final, {
    preferences: { requireOption: { present: true, value: true } },
  });
});

test("unowned, literal, UI-suite, traversal and oversized saved reads are rejected", () => {
  const changes = [
    (value) => {
      value.owner = "music";
    },
    (value) => {
      value.reads[0].root = "owner-data";
    },
    (value) => {
      value.reads[0].components[2] = "production.plist";
    },
    (value) => {
      value.reads[0].components[2].derived = "ui-suite-plist";
    },
    (value) => {
      value.reads[0].components[0] = "..";
    },
    (value) => {
      value.reads[0].maximumBytes += 1;
    },
    (value) => {
      value.reads[0].selections.push(value.reads[0].selections[0]);
    },
  ];
  for (const change of changes) {
    const value = structuredClone(saved);
    change(value);
    assert.throws(() => validateFunctionalSavedReaderPolicy(value, policy));
  }
  assert.throws(() =>
    validateFunctionalSavedReaderPolicy(saved, { ...policy, fileScopes: [] }),
  );
});

test("authoritative readback is bound to the original engine field through all three phases", () => {
  assert.equal(
    validateFunctionalObservationPolicy(observation, definition, policy),
    observation,
  );
  assert.equal(observation.readback.operation, "notch.settings.read");
  assert.deepEqual(observation.readback.normalizer.fields.requireOption.path, [
    "preferences",
    "notchShelfRequireOption",
  ]);
  assert.deepEqual(
    observation.phases.map(({ phase }) => phase),
    ["initial", "updated", "reinstalled"],
  );
  for (const phase of observation.phases) {
    assert.deepEqual(phase.after, {
      kind: "object",
      fields: { requireOption: { kind: "literal", value: "1" } },
    });
  }
});

test("observation cannot add commands, lose update or reinstall phases, or select an unowned file", () => {
  const changes = [
    (value) => {
      value.readback.operation = "notch.browser.detach";
    },
    (value) => {
      value.phases.pop();
    },
    (value) => {
      value.phases[1].phase = "initial";
    },
    (value) => {
      value.phases[0].after = {
        kind: "literal",
        value: {
          $binding: "owned-path",
          root: "owner-home",
          components: ["unowned"],
        },
      };
    },
  ];
  for (const change of changes) {
    const value = structuredClone(observation);
    change(value);
    assert.throws(() =>
      validateFunctionalObservationPolicy(value, definition, policy),
    );
  }
});

test("modern producer compiles the maintained Notch saved reader and readback into its actual consumer tables", () => {
  const session = "12345678-1234-4123-8123-123456789abc";
  const sourceCommit = "a".repeat(40);
  const source = functionalProducerBootstrapSource(
    {
      sourceCommit,
      hostedRunPins: {
        sourceCommit,
        mergeCommit: "b".repeat(40),
        baseCommit: "c".repeat(40),
        runID: 10,
        jobID: 11,
        runAttempt: 1,
        runnerName: "synthetic-hosted-runner",
        workflowSHA256: "d".repeat(64),
      },
      sourceSHA256: "e".repeat(64),
      toolchainSHA256: "f".repeat(64),
      sourcePins: snapshot,
      session,
      root: `/private/synthetic/functional-fixture-${session}`,
      hostIdentifier: `com.pulkit.edith.tests.worker-${session}`,
      producerIdentifier: `com.pulkit.edith.tests.functional-producer-${session}`,
      certificateSHA256: Buffer.alloc(32, 9).toString("base64"),
      definitions: [definition],
      roles: { notchShelf: ["helper"] },
      recipes: { notchShelf: recipe },
      preparationPolicies: {
        notchShelf: { schema: 1, owner: "notchShelf", files: [] },
      },
      savedReaderPolicies: { notchShelf: saved },
      observationPolicies: { notchShelf: observation },
      policySHA256: "b".repeat(64),
      rolePolicySwiftExpression: "[]",
    },
    "/private/synthetic/repository",
  );
  const decodeTable = (name) => {
    const line = source
      .split("\n")
      .find((line) => line.includes(`static let ${name}:`));
    const encoded = line.match(
      /\["notchShelf": Data\(base64Encoded: "([A-Za-z0-9+/=]+)"\)!\]/,
    )[1];
    return JSON.parse(Buffer.from(encoded, "base64").toString("utf8"));
  };
  assert.deepEqual(decodeTable("savedReaderPolicies"), saved);
  assert.deepEqual(decodeTable("authoritativeReadPolicies"), {
    schema: 1,
    owner: "notchShelf",
    operation: "notch.settings.read",
    payload: {},
  });
  assert.deepEqual(decodeTable("authoritativeNormalizers"), {
    schema: 1,
    owner: "notchShelf",
    normalizer: observation.readback.normalizer,
  });
});
