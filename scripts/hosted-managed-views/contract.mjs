import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import { join } from "node:path";

export function validateManagedViewReview(review, definitions) {
  assert.equal(review.schema, 1);
  assert.match(review.reviewedSource, /^[a-f0-9]{40}$/);
  assert.equal(review.owners.length, 40);
  assert.deepEqual(
    review.owners.map(({ id }) => id).sort(),
    definitions.map(({ id }) => id).sort(),
  );
  assert.equal(new Set(review.owners.map(({ id }) => id)).size, 40);
  for (const owner of review.owners) {
    assert(["main", "settings"].includes(owner.location));
    assert.match(owner.section, /^[A-Za-z][A-Za-z0-9]{0,63}$/);
    assert.equal(owner.visible, false);
    assert.equal(owner.uiOnly, false);
    assert.equal(owner.scope, "original-view-creation-close-reopen-disable");
    assert.equal(owner.functionalActionsValidated, false);
    assert.equal(
      owner.factoryOverlay,
      ["plugins", "studio"].includes(owner.id),
    );
    assert(typeof owner.effects === "string" && owner.effects.length > 40);
    assert(owner.sources.length >= 1 && owner.sources.length <= 4);
    for (const source of owner.sources) {
      assert(source.path.startsWith(`Extensions/${owner.id}/`));
      assert(
        !source.path.split("/").some((part) => [".", "..", ""].includes(part)),
      );
      assert.match(source.sha256, /^[a-f0-9]{64}$/);
    }
  }
  const notch = review.owners.find(({ id }) => id === "notchShelf");
  assert.equal(notch.location, "settings");
  assert.equal(notch.section, "extension");
  const terminal = review.owners.find(({ id }) => id === "terminal");
  assert.equal(terminal.location, "main");
  assert.equal(terminal.section, "terminal");
  return review;
}

export async function loadManagedViewReview(root) {
  const review = validateManagedViewReview(
    JSON.parse(
      await readFile(
        join(root, "Tests/HostedManagedViews/routes.json"),
        "utf8",
      ),
    ),
    JSON.parse(await readFile(join(root, "Extensions/manifest.json"), "utf8")),
  );
  for (const owner of review.owners)
    for (const source of owner.sources)
      assert.equal(
        createHash("sha256")
          .update(await readFile(join(root, source.path)))
          .digest("hex"),
        source.sha256,
        `The ${owner.id} managed view source requires renewed effect review`,
      );
  return review;
}

export function validateManagedViewProof(proof, owner, package_) {
  assert.equal(proof.schema, 1);
  assert.equal(proof.outcome, "passed");
  assert.equal(proof.extensionID, owner.id);
  assert.equal(proof.selectedVersion, package_.version);
  assert.equal(proof.hostABI, package_.hostABI);
  assert.equal(proof.location, owner.location);
  assert.equal(proof.section, owner.section);
  assert.equal(proof.factoryOverlay, owner.factoryOverlay);
  assert.equal(proof.functionalActionsValidated, false);
  assert.equal(proof.visible, false);
  assert.equal(proof.productionExecutableUnchangedProof, false);
  for (const key of [
    "managedNativeViewValidated",
    "publicCarrierCheckIn",
    "freshSceneGeneration",
    "lastCloseExited",
    "disableExitedBothRoles",
    "packageLeaseReleased",
    "noVisibleWindows",
  ])
    assert.equal(proof[key], true, key);
  assert.equal(proof.disabledProcesses, 0);
  assert.equal(proof.presentations, 2);
  assert.equal(proof.featurePayloadUnchanged, !owner.factoryOverlay);
  return proof;
}
