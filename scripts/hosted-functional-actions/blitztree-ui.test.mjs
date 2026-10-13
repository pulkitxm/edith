import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { loadFunctionalActionCase } from "./case-loader.mjs";
import { definition } from "./cases/blitztree.mjs";
import {
  blitzTreeSavedDigests,
  functionalCanonicalJSON,
  functionalDigest,
} from "./contract.mjs";
import {
  FunctionalJourneyOrder,
  validateFunctionalObservationPolicy,
  validateFunctionalOriginalCaseSource,
  validateFunctionalSavedReaderPolicy,
} from "./controller.mjs";
import {
  loadInstalledPresentationRecipe,
  validateInstalledPresentationRecipe,
} from "./presentation.mjs";
import { functionalProducerBootstrapSource } from "./producer-project.mjs";

const root = resolve(fileURLToPath(new URL("../..", import.meta.url)));
const digest = (bytes) => createHash("sha256").update(bytes).digest("hex");
const native =
  "Tests/HostedFunctionalActions/OwnerCases/blitztreeActionCase.swift";
const casePath = "scripts/hosted-functional-actions/cases/blitztree.mjs";
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
const read = async (directory) =>
  JSON.parse(
    await readFile(new URL(`./${directory}/blitztree.json`, import.meta.url)),
  );
const policy = await read("policies");
const recipe = await read("presentations");
const saved = await read("saved-readers");
const observation = await read("observation-policies");

test("the BlitzTree case and installed recipe bind original chooser and both Trash controls", async () => {
  const loaded = await loadFunctionalActionCase(
    root,
    "blitztree",
    readFile,
    snapshot,
  );
  assert.equal(loaded.definition.activation.operation, "blitztree.ui.trash");
  assert.deepEqual(loaded.definition.activation.mutation.payloadKeys, [
    "confirmed",
    "path",
    "previewToken",
  ]);
  validateFunctionalOriginalCaseSource(
    await readFile(resolve(root, native)),
    definition,
  );
  const admitted = await loadInstalledPresentationRecipe(
    root,
    "blitztree",
    definition,
  );
  assert.deepEqual(
    admitted.recipe.steps.map(({ label }) => label),
    ["Choose folder", "Scan", "Move to Trash", "Move to Trash"],
  );
  assert.equal(admitted.recipe.steps[1].ownedPath, "scan-directory");
  assert.equal(admitted.recipe.steps[2].scope.anchor.ownedLabel.name, "victim");
  assert.equal(
    admitted.recipe.steps[3].scope.anchor.label,
    "Move this item to Trash?",
  );
});

test("changed controls, models, receiver, signed adapter and native case fail source admission", async () => {
  for (const changed of [
    native,
    ...definition.activation.sources.map(({ path }) => path),
  ]) {
    await assert.rejects(
      loadFunctionalActionCase(
        root,
        "blitztree",
        async (path) => {
          const bytes = await readFile(path);
          return path === resolve(root, changed)
            ? Buffer.concat([bytes, Buffer.from("\n")])
            : bytes;
        },
        snapshot,
      ),
    );
  }
});

test("original presentation cannot redirect the chooser, owner or activation", () => {
  for (const mutation of [
    (value) => {
      value.owner = "cleaner";
    },
    (value) => {
      value.operation = "blitztree.ui.scan";
    },
    (value) => {
      value.steps[1].action = "click";
    },
    (value) => {
      value.steps[2].scope.anchor.ownedLabel.component = "path";
    },
  ]) {
    const changed = structuredClone(recipe);
    mutation(changed);
    assert.throws(() =>
      validateInstalledPresentationRecipe(changed, definition),
    );
  }
});

test("the independent saved policy checks actual source absence and exact private-trash bytes", () => {
  assert.equal(validateFunctionalSavedReaderPolicy(saved, policy), saved);
  assert.equal(saved.reads.length, 2);
  assert.deepEqual(
    saved.reads.map(({ components }) => components),
    [
      [{ derived: "phase" }, "scan", "victim.bin"],
      [{ derived: "phase" }, "trash", "victim.bin"],
    ],
  );
  assert.equal(saved.initial.victim.bytes.value, 4096);
  assert.equal(
    saved.initial.victim.sha256.value,
    digest(Buffer.alloc(4096, 42)),
  );
  assert.deepEqual(saved.final.victim, saved.initial["private-trash"]);
  assert.deepEqual(saved.final["private-trash"], saved.initial.victim);
});

test("raw metadata never admits another owner, unowned file, content selection or larger bound", () => {
  for (const mutation of [
    (value) => {
      value.owner = "music";
    },
    (value) => {
      value.reads[0].root = "owner-home";
    },
    (value) => {
      value.reads[0].components[1] = "other";
    },
    (value) => {
      value.reads[0].maximumBytes += 1;
    },
    (value) => {
      value.reads[0].selections[0].path = ["contents"];
    },
    (value) => {
      value.reads[0].selections[0].path = ["sha256"];
    },
    (value) => {
      value.reads[0].selections[0].codec = "masked-utf8";
    },
  ]) {
    const changed = structuredClone(saved);
    mutation(changed);
    assert.throws(() => validateFunctionalSavedReaderPolicy(changed, policy));
  }
  assert.throws(() =>
    validateFunctionalSavedReaderPolicy(saved, { ...policy, fileScopes: [] }),
  );
});

test("all phases compare the original scanner progress and compile fresh baseline and final readers", () => {
  validateFunctionalObservationPolicy(observation, definition, policy);
  assert.equal(observation.readback.operation, "blitztree.ui.snapshot");
  assert.deepEqual(observation.readback.normalizer.fields.entries.path, [
    "scannedEntries",
  ]);
  for (const phase of observation.phases) {
    assert.equal(phase.before.fields.entries.value, 2);
    assert.equal(phase.after.fields.entries.value, 1);
  }
  const session = "12345678-1234-4123-8123-123456789abc";
  const source = functionalProducerBootstrapSource(
    {
      sourceCommit: snapshot.sourceCommit,
      hostedRunPins: {
        sourceCommit: snapshot.sourceCommit,
        baseCommit: "2".repeat(40),
        mergeCommit: "3".repeat(40),
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
      roles: { blitztree: ["app"] },
      recipes: { blitztree: recipe },
      preparationPolicies: {
        blitztree: { schema: 1, owner: "blitztree", files: [] },
      },
      savedReaderPolicies: { blitztree: saved },
      observationPolicies: { blitztree: observation },
      policySHA256: "b".repeat(64),
      rolePolicySwiftExpression: "[]",
    },
    "/private/synthetic/repository",
  );
  const before = source
    .split("savedBefore: ")
    .slice(1)
    .map((value) => value.split(", savedAfter:")[0]);
  assert.equal(before.length, 3);
  assert.equal(new Set(before).size, 1);
  assert(before[0].includes('"victim"'));
  assert(before[0].includes('"value": .integer(4096'));
  const table = source
    .split("\n")
    .find((line) => line.includes("static let savedReaderPolicies:"));
  const encoded = table.match(/Data\(base64Encoded: "([A-Za-z0-9+/=]+)"\)!/)[1];
  assert.deepEqual(JSON.parse(Buffer.from(encoded, "base64")), saved);
});

test("fresh-phase portable admission requires the fixed seed and cannot accept an arbitrary or final baseline", () => {
  assert.equal(functionalDigest(saved.initial), blitzTreeSavedDigests.initial);
  assert.equal(functionalDigest(saved.final), blitzTreeSavedDigests.final);
  for (const invalid of [
    null,
    Buffer.from("{}"),
    Buffer.from(functionalCanonicalJSON(saved.final)),
  ]) {
    const order = new FunctionalJourneyOrder("blitztree");
    assert.throws(() => order.captureBaseline(invalid));
  }
  const order = new FunctionalJourneyOrder("blitztree");
  order.captureBaseline(Buffer.from(functionalCanonicalJSON(saved.initial)));
  assert.throws(() => new FunctionalJourneyOrder("foreign"));
});
