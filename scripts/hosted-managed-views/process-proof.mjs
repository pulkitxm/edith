import assert from "node:assert/strict";
import { join } from "node:path";

export function recordManagedHostObservation(
  ledger,
  observations,
  fixture,
  uid,
) {
  assert(Array.isArray(ledger) && ledger.length <= 2);
  assert(Array.isArray(observations) && observations.length <= 1);
  assert(Number.isSafeInteger(uid) && uid >= 0);
  for (const row of observations) {
    assert.deepEqual(
      Object.keys(row).sort(),
      ["pid", "generation", "uid", "executable", "hostIdentifier"].sort(),
    );
    assert(Number.isSafeInteger(row.pid) && row.pid > 1);
    assert.match(row.generation, /^[0-9]{1,20}\.[0-9]{1,6}$/);
    assert.equal(row.uid, uid);
    assert.equal(row.hostIdentifier, fixture.identifier);
    assert.equal(row.executable, join(fixture.app, "Contents/MacOS/Edith"));
    const existing = ledger.find(
      ({ pid, generation }) => pid === row.pid && generation === row.generation,
    );
    if (existing) assert.deepEqual(existing, row);
    else {
      assert.equal(
        ledger.length,
        0,
        "Managed fixture unexpectedly changed Host generation",
      );
      ledger.push({ ...row });
    }
  }
  return ledger;
}

export function validateManagedApprovalReceipt(receipt, fixture, ledger) {
  assert.equal(
    ledger.length,
    1,
    "Approval requires independently observed kernel Host identity",
  );
  const expected = ledger[0];
  assert.equal(receipt.schema, 1);
  assert.equal(receipt.sourceCommit, fixture.sourceCommit);
  assert.equal(receipt.extensionID, fixture.extensionID);
  assert.equal(receipt.selectedVersion, fixture.package.version);
  assert.equal(receipt.hostABI, fixture.package.hostABI);
  assert.equal(receipt.sourceFingerprint, fixture.package.sourceFingerprint);
  assert.equal(receipt.packageSHA256, fixture.package.sha256);
  assert.equal(receipt.hostIdentifier, fixture.identifier);
  assert.equal(
    receipt.workerIdentifier,
    `${fixture.identifier}.extension.${fixture.extensionID}.worker`,
  );
  assert.equal(
    receipt.extensionPointIdentifier,
    `${fixture.identifier}.ExtensionUI`,
  );
  assert.equal(receipt.expectedLabel, `Edith ${fixture.extensionID}`);
  assert.equal(receipt.hostPID, expected.pid);
  assert.equal(receipt.hostGeneration, expected.generation);
  assert.equal(receipt.outcome, "approved");
  for (const key of [
    "publicDiscovery",
    "ownedBrowserClosed",
    "activationPolicyRestored",
  ])
    assert.equal(receipt[key], true);
  assert.equal(receipt.managedViewReady, false);
  assert.equal(typeof receipt.publicBrowser, "boolean");
  return {
    publicApprovalValidated: true,
    publicBrowser: receipt.publicBrowser,
    hostPID: expected.pid,
    hostGeneration: expected.generation,
    managedViewReady: false,
  };
}
