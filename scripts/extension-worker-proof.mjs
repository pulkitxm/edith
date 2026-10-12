import assert from "node:assert/strict";

export function validateWorkerLifecycleScope(result) {
  assert.equal(result.engineLifecycleValidated, true);
  assert.equal(result.managedNativeViewValidated, false);
  assert.equal(result.nativeWindow, false);
}

export function validateManagedNativeProof(result, package_) {
  assert.equal(result.outcome, "passed", result.error);
  assert.equal(result.extensionID, package_.id);
  assert.equal(result.selectedVersion, package_.version);
  assert.equal(result.hostABI, package_.hostABI);
  for (const key of [
    "managedNativeViewValidated",
    "originalDownloadedRole",
    "readonlyControlVerified",
    "publicCarrierCheckIn",
    "freshSceneGeneration",
    "lastCloseExited",
    "disableExitedBothRoles",
    "packageLeaseReleased",
    "noVisibleWindows",
  ])
    assert.equal(result[key], true, key);
  assert.equal(result.nativeWindow, false);
  assert.equal(result.disabledProcesses, 0);
}
