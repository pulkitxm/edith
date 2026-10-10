import { test } from "bun:test";
import assert from "node:assert/strict";
import { validateWorkerLifecycleScope } from "./extension-worker-proof.mjs";

const lifecycle = {
  engineLifecycleValidated: true,
  managedNativeViewValidated: false,
  nativeWindow: false,
};

test("worker lifecycle accepts truthful engine-only evidence", () => {
  assert.doesNotThrow(() => validateWorkerLifecycleScope(lifecycle));
});

for (const key of Object.keys(lifecycle)) {
  test(`worker lifecycle rejects an unsupported ${key} claim`, () => {
    assert.throws(() =>
      validateWorkerLifecycleScope({ ...lifecycle, [key]: !lifecycle[key] }),
    );
  });
  test(`worker lifecycle requires explicit ${key} evidence`, () => {
    const incomplete = { ...lifecycle };
    delete incomplete[key];
    assert.throws(() => validateWorkerLifecycleScope(incomplete));
  });
}
