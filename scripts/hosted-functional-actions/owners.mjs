import assert from "node:assert/strict";

export const functionalActionOwners = Object.freeze([
  "keepAwake",
  "audioMixer",
  "focusDim",
  "windowSweaters",
  "micMute",
  "keystrokeHighlight",
  "presenter",
  "colorPicker",
  "systemStats",
  "emoji",
  "homebrew",
  "calendar",
  "jev",
  "system",
  "timeLapse",
  "cleaner",
  "appMaintenance",
  "blitztree",
  "plugins",
  "notchShelf",
  "clipboard",
  "music",
  "docs",
  "latex",
  "companion",
  "terminal",
  "studio",
  "usage",
  "bifrost",
  "lidAwake",
  "attention",
  "machines",
  "downloads",
  "seoAudit",
  "virtualCamera",
  "codeStats",
  "herdr",
  "quinjet",
  "database",
]);

export const functionalActionBatches = Object.freeze({
  controls: Object.freeze([
    "keepAwake",
    "focusDim",
    "windowSweaters",
    "micMute",
    "keystrokeHighlight",
    "presenter",
    "colorPicker",
    "systemStats",
    "emoji",
    "homebrew",
    "jev",
    "system",
    "timeLapse",
    "cleaner",
    "appMaintenance",
    "blitztree",
    "plugins",
    "notchShelf",
    "bifrost",
    "lidAwake",
  ]),
  applications: Object.freeze([
    "audioMixer",
    "calendar",
    "clipboard",
    "music",
    "docs",
    "latex",
    "companion",
    "terminal",
    "studio",
    "usage",
    "attention",
    "machines",
    "downloads",
    "seoAudit",
    "virtualCamera",
    "codeStats",
    "herdr",
    "quinjet",
    "database",
  ]),
});

export function functionalActionCasePaths(owner) {
  assert(
    functionalActionOwners.includes(owner),
    "Unknown functional action owner",
  );
  return Object.freeze({
    definition: `scripts/hosted-functional-actions/cases/${owner}.mjs`,
    native: `Tests/HostedFunctionalActions/OwnerCases/${owner}ActionCase.swift`,
  });
}

export function validateFunctionalOwnerInventory(definitions) {
  assert.equal(definitions.length, 39);
  assert.deepEqual(
    definitions.map(({ id }) => id).sort(),
    [...functionalActionOwners].sort(),
  );
  assert.equal(new Set(definitions.map(({ id }) => id)).size, 39);
  const batches = Object.values(functionalActionBatches).flat();
  assert.equal(batches.length, 39);
  assert.deepEqual([...batches].sort(), [...functionalActionOwners].sort());
  assert.equal(new Set(batches).size, 39);
  return definitions;
}
