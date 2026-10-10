import assert from "node:assert/strict";

export function validateWorkerLifecycleScope(result) {
  assert.equal(result.engineLifecycleValidated, true);
  assert.equal(result.managedNativeViewValidated, false);
  assert.equal(result.nativeWindow, false);
}
