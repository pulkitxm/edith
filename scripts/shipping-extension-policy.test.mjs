import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { test } from "node:test";
import {
  assertShippingExtensions,
  deferredExtensionIDs,
  shippingDefinitions,
  shippingExtensionIDs,
} from "./shipping-extension-policy.mjs";

const manifestDefinitions = async () =>
  JSON.parse(
    await readFile(
      new URL("../Extensions/manifest.json", import.meta.url),
      "utf8",
    ),
  );

test("the release selects every manifest extension without modifying the manifest", async () => {
  const definitions = await manifestDefinitions();
  const before = JSON.stringify(definitions);
  const selected = shippingDefinitions(definitions);
  assert.equal(definitions.length, 41);
  assert.deepEqual(
    selected.map((entry) => entry.id),
    definitions
      .map((entry) => entry.id)
      .filter((id) => !deferredExtensionIDs.includes(id)),
  );
  assert.deepEqual(
    shippingExtensionIDs(),
    selected.map((entry) => entry.id),
  );
  assert(selected.every((entry) => definitions.includes(entry)));
  for (const entry of selected)
    assert(
      entry.dependencies.every((id) => shippingExtensionIDs().includes(id)),
    );
  assert.equal(JSON.stringify(definitions), before);
  assert(Object.isFrozen(shippingExtensionIDs()));
  assert.equal(shippingExtensionIDs(), shippingExtensionIDs());
});

test("missing, duplicate, unknown and unreleased dependencies reject publication scope", async () => {
  const definitions = await manifestDefinitions();
  const keepAwake = definitions.find((entry) => entry.id === "keepAwake");
  const others = definitions.filter((entry) => entry.id !== "keepAwake");
  assert.throws(() => shippingDefinitions([]), /exactly one/);
  assert.throws(
    () => shippingDefinitions(others),
    /exactly one shipping extension definition: keepAwake/,
  );
  assert.throws(
    () => shippingDefinitions([...definitions, keepAwake]),
    /exactly one/,
  );
  assert.throws(
    () =>
      shippingDefinitions([
        ...definitions,
        { id: "unknownExtension", dependencies: [] },
      ]),
    /outside the shipping release scope/,
  );
  assert.throws(
    () =>
      shippingDefinitions([
        { ...keepAwake, dependencies: ["unknownExtension"] },
        ...others,
      ]),
    /Unreleased/,
  );
  assert.throws(
    () => shippingDefinitions([{ id: "keepAwake" }, ...others]),
    /Unreleased/,
  );
  assert.throws(() => shippingDefinitions({}), /Invalid/);
});

test("unknown and duplicate planned packages reject before publication", () => {
  assert.doesNotThrow(() => assertShippingExtensions([]));
  assert.doesNotThrow(() => assertShippingExtensions([{ id: "keepAwake" }]));
  assert.doesNotThrow(() =>
    assertShippingExtensions([{ id: "keepAwake" }, { id: "music" }]),
  );
  assert.doesNotThrow(() =>
    assertShippingExtensions(shippingExtensionIDs().map((id) => ({ id }))),
  );
  assert.throws(
    () => assertShippingExtensions([{ id: "unknownExtension" }]),
    /shipping/,
  );
  assert.throws(
    () =>
      assertShippingExtensions([
        { id: "keepAwake" },
        { id: "unknownExtension" },
      ]),
    /shipping/,
  );
  assert.throws(
    () => assertShippingExtensions([{ id: "keepAwake" }, { id: "keepAwake" }]),
    /shipping/,
  );
  assert.throws(() => assertShippingExtensions({}), /shipping/);
});
