import { expect, test } from "bun:test";
import { readFile } from "node:fs/promises";
import {
  aggregateManagedChunks,
  managedChunkOwners,
  selectManagedArtifactRows,
  validateManagedChunkResults,
} from "./hosted-managed-views/chunks.mjs";

const review = JSON.parse(
  await readFile("Tests/HostedManagedViews/routes.json", "utf8"),
);
const bindings = {
  fixtureSourceCommit: "a".repeat(40),
  originalSourceCommit: "b".repeat(40),
  originalCIRun: 123,
  managedWorkflowRun: 456,
  reviewSHA256: "c".repeat(64),
  fingerprintMapSHA256: "d".repeat(64),
  frozenHostArtifactSHA256: "e".repeat(64),
  frozenHostExecutableSHA256: "f".repeat(64),
};
function rows(chunk) {
  const owners = managedChunkOwners(review.owners, chunk);
  const fixtures = owners.map(({ id }) => ({
    extensionID: id,
    package: {
      version: "1.0.0",
      hostABI: "edith-host-2",
      sha256: "1".repeat(64),
    },
    sourceCommit: bindings.fixtureSourceCommit,
    originalSourceCommit: bindings.originalSourceCommit,
    originalZipSHA256: "2".repeat(64),
  }));
  const results = owners.map((owner) => ({
    extensionID: owner.id,
    fixtureSourceCommit: bindings.fixtureSourceCommit,
    originalSourceCommit: bindings.originalSourceCommit,
    fixtureZipSHA256: "1".repeat(64),
    originalZipSHA256: "2".repeat(64),
    nativePayloadScope:
      "Payload/<id>/<role>.bundle only, excluding signatures and all Host executable carriers",
    hostCarrierTransformationVerified: true,
    proof: {
      schema: 1,
      outcome: "passed",
      extensionID: owner.id,
      selectedVersion: "1.0.0",
      hostABI: "edith-host-2",
      location: owner.location,
      section: owner.section,
      factoryOverlay: owner.factoryOverlay,
      functionalActionsValidated: false,
      visible: false,
      productionExecutableUnchangedProof: false,
      managedNativeViewValidated: true,
      publicCarrierCheckIn: true,
      freshSceneGeneration: true,
      lastCloseExited: true,
      disableExitedBothRoles: true,
      packageLeaseReleased: true,
      noVisibleWindows: true,
      disabledProcesses: 0,
      presentations: 2,
      featurePayloadUnchanged: !owner.factoryOverlay,
    },
  }));
  return { results, fixtures, review, chunk, bindings };
}
function complete() {
  return [0, 1, 2].map((chunk) => validateManagedChunkResults(rows(chunk)));
}

test("fixed three chunks form an exact deterministic disjoint39 partition", () => {
  const selected = [0, 1, 2].map((chunk) =>
    managedChunkOwners(review.owners, chunk),
  );
  expect(selected.map((x) => x.length)).toEqual([13, 13, 13]);
  expect(new Set(selected.flat().map(({ id }) => id)).size).toBe(39);
  expect(managedChunkOwners([...review.owners].reverse(), 0)).toEqual(
    selected[0],
  );
  for (const chunk of [-1, 3, 0.5, "0", undefined])
    expect(() => managedChunkOwners(review.owners, chunk)).toThrow();
  expect(() => managedChunkOwners(review.owners.slice(1), 0)).toThrow();
});

test("selected artifact download requires complete39 metadata even for unselected owners", () => {
  const intake = {
    originals: review.owners.map(({ id }) => ({ extensionID: id })),
  };
  expect(selectManagedArtifactRows(intake, review.owners, 0)).toHaveLength(13);
  const missing = structuredClone(intake);
  missing.originals.pop();
  expect(() => selectManagedArtifactRows(missing, review.owners, 0)).toThrow();
  const duplicate = structuredClone(intake);
  duplicate.originals[0] = duplicate.originals[1];
  expect(() =>
    selectManagedArtifactRows(duplicate, review.owners, 0),
  ).toThrow();
});

test("only the aggregate may claim all39 and every owner retains native ready and drain proof", () => {
  const chunks = complete();
  for (const chunk of chunks) {
    expect(chunk.all39Validated).toBe(false);
    expect(chunk.owners).toBe(13);
  }
  const result = aggregateManagedChunks(chunks, review, bindings);
  expect(result.all39Validated).toBe(true);
  expect(result.owners).toBe(39);
  expect(result.results).toHaveLength(39);
  expect(result.functionalActionsValidated).toBe(false);
  for (const change of [
    (x) => x.pop(),
    (x) => x.push(x[0]),
    (x) => {
      x[1] = x[0];
    },
    (x) => {
      x[0].outcome = "skipped";
    },
    (x) => {
      x[0].outcome = "failed";
    },
    (x) => {
      x[0].all39Validated = true;
    },
    (x) => {
      x[0].results[0].proof.disabledProcesses = 1;
    },
    (x) => {
      x[0].results[0].proof.lastCloseExited = false;
    },
    (x) => {
      x[0].results[0].proof.managedNativeViewValidated = false;
    },
    (x) => {
      x[0].results[0].proof.selectedVersion = "2.0.0";
    },
    (x) => {
      x[0].bindings.originalCIRun++;
    },
    (x) => {
      x[0].bindings.managedWorkflowRun++;
    },
    (x) => {
      x[0].bindings.fixtureSourceCommit = "c".repeat(40);
    },
    (x) => {
      x[0].bindings.fingerprintMapSHA256 = "0".repeat(64);
    },
    (x) => {
      x[0].fixtures[0].originalSourceCommit = "d".repeat(40);
    },
  ]) {
    const changed = structuredClone(chunks);
    change(changed);
    expect(() => aggregateManagedChunks(changed, review, bindings)).toThrow();
  }
});
