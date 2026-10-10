import { test } from "bun:test";
import assert from "node:assert/strict";
import {
  validateManagedNativeProof,
  validateWorkerLifecycleScope,
} from "./extension-worker-proof.mjs";

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

const package_ = { id: "calendar", version: "1.0.0", hostABI: "fixture-abi-2" };
const managed = {
  outcome: "passed",
  extensionID: package_.id,
  selectedVersion: package_.version,
  hostABI: package_.hostABI,
  managedNativeViewValidated: true,
  originalDownloadedRole: true,
  readonlyControlVerified: true,
  publicCarrierCheckIn: true,
  freshSceneGeneration: true,
  lastCloseExited: true,
  disableExitedBothRoles: true,
  packageLeaseReleased: true,
  noVisibleWindows: true,
  nativeWindow: false,
  disabledProcesses: 0,
};

test("managed evidence admits original-role readiness and complete background drain", () => {
  assert.doesNotThrow(() => validateManagedNativeProof(managed, package_));
});

for (const [name, overrides] of [
  ["approval without readiness", { readonlyControlVerified: false }],
  ["a retained version", { selectedVersion: "0.9.0" }],
  ["a foreign extension", { extensionID: "sample" }],
  ["an old ABI", { hostABI: "fixture-abi-1" }],
  ["fixture-only direct check-in", { publicCarrierCheckIn: false }],
  ["a replacement generic view", { originalDownloadedRole: false }],
  ["a visible window", { noVisibleWindows: false }],
  ["a standalone window claim", { nativeWindow: true }],
  ["a leaked engine", { disabledProcesses: 1 }],
  ["an unreleased payload", { packageLeaseReleased: false }],
  ["a stale scene", { freshSceneGeneration: false }],
  ["a failed fixture", { outcome: "failed" }],
]) {
  test(`managed evidence rejects ${name}`, () => {
    assert.throws(() =>
      validateManagedNativeProof({ ...managed, ...overrides }, package_),
    );
  });
}
