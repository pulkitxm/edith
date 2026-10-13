import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { validateFunctionalPreparationPolicy } from "./controller.mjs";

const read = async (directory) =>
  JSON.parse(
    await readFile(new URL(`./${directory}/blitztree.json`, import.meta.url)),
  );
const policy = await read("policies");
const preparation = await read("preparation");

function reject(mutate) {
  const changed = structuredClone(preparation);
  mutate(changed);
  assert.throws(() => validateFunctionalPreparationPolicy(changed, policy));
}

test("the original one-file fixture seeds exactly the admitted synthetic victim", () => {
  validateFunctionalPreparationPolicy(preparation, policy);
  assert.equal(preparation.files.length, 1);
  assert.equal(policy.owner, "blitztree");
  assert.deepEqual(policy.inputs, []);
  const victim = Buffer.from(preparation.files[0].bytesBase64, "base64");
  assert.equal(victim.length, 4096);
  assert.deepEqual(victim, Buffer.alloc(4096, 42));
});

test("preparation rejects another owner and an unowned root or leaf", () => {
  reject((value) => {
    value.owner = "cleaner";
  });
  reject((value) => {
    value.files[0].root = "owner-home";
  });
  reject((value) => {
    value.files[0].components.at(-1).literal = "other.bin";
  });
});

test("preparation rejects a prepopulated destination and duplicate source writes", () => {
  reject((value) => {
    value.files[0].components[1].literal = "trash";
  });
  reject((value) => {
    value.files.push(structuredClone(value.files[0]));
  });
});

test("preparation rejects noncanonical or oversized bytes without changing the bound", () => {
  reject((value) => {
    value.files[0].bytesBase64 += "=";
  });
  reject((value) => {
    value.files[0].bytesBase64 = Buffer.alloc(4097, 42).toString("base64");
  });
  reject((value) => {
    value.files[0].maximumBytes = 4097;
  });
});
