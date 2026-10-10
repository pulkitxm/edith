import { expect, test } from "bun:test";
import {
  recordManagedHostObservation,
  validateManagedApprovalReceipt,
} from "./hosted-managed-views/process-proof.mjs";

const fixture = {
  identifier:
    "com.pulkit.edith.tests.worker-00000000-0000-4000-8000-000000000001",
  app: "/synthetic/Fixture.app",
  sourceCommit: "a".repeat(40),
  extensionID: "music",
  package: {
    version: "1.2.3",
    hostABI: "edith-host-2",
    sourceFingerprint: "b".repeat(64),
    sha256: "c".repeat(64),
  },
};
const row = {
  pid: 101,
  generation: "1000.123",
  uid: 501,
  executable: "/synthetic/Fixture.app/Contents/MacOS/Edith",
  hostIdentifier: fixture.identifier,
};
const approval = () => ({
  schema: 1,
  sourceCommit: fixture.sourceCommit,
  extensionID: "music",
  selectedVersion: "1.2.3",
  hostABI: "edith-host-2",
  sourceFingerprint: fixture.package.sourceFingerprint,
  packageSHA256: fixture.package.sha256,
  hostIdentifier: fixture.identifier,
  workerIdentifier: `${fixture.identifier}.extension.music.worker`,
  extensionPointIdentifier: `${fixture.identifier}.ExtensionUI`,
  expectedLabel: "Edith music",
  hostPID: 101,
  hostGeneration: "1000.123",
  outcome: "approved",
  publicBrowser: true,
  publicDiscovery: true,
  ownedBrowserClosed: true,
  activationPolicyRestored: true,
  managedViewReady: false,
});
test("kernel ledger rejects foreign identity, UID, executable, reused PID and changed generation", () => {
  const ledger = [];
  recordManagedHostObservation(ledger, [row], fixture, 501);
  recordManagedHostObservation(ledger, [row], fixture, 501);
  expect(ledger).toEqual([row]);
  for (const changed of [
    { uid: 502 },
    { executable: "/production/Edith" },
    { hostIdentifier: "com.pulkit.edith" },
    { generation: "1000:123" },
    { pid: 101, generation: "2000.456" },
    { pid: 102 },
  ])
    expect(() =>
      recordManagedHostObservation(
        [...ledger],
        [{ ...row, ...changed }],
        fixture,
        501,
      ),
    ).toThrow();
  expect(() =>
    recordManagedHostObservation([], [row, row], fixture, 501),
  ).toThrow();
});
test("approval alone never counts as managed ready and must match independently recorded Host birth", () => {
  const ledger = recordManagedHostObservation([], [row], fixture, 501);
  expect(
    validateManagedApprovalReceipt(approval(), fixture, ledger),
  ).toMatchObject({ publicApprovalValidated: true, managedViewReady: false });
  expect(() =>
    validateManagedApprovalReceipt(approval(), fixture, []),
  ).toThrow();
  for (const changed of [
    { hostPID: 102 },
    { hostGeneration: "1000:123" },
    { sourceCommit: "d".repeat(40) },
    { packageSHA256: "d".repeat(64) },
    { publicDiscovery: false },
    { ownedBrowserClosed: false },
    { activationPolicyRestored: false },
    { managedViewReady: true },
    { outcome: "ready" },
  ])
    expect(() =>
      validateManagedApprovalReceipt(
        { ...approval(), ...changed },
        fixture,
        ledger,
      ),
    ).toThrow();
});
