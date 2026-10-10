import assert from "node:assert/strict";

export function validateDisabledJourneyProcesses(proof) {
  assert(Array.isArray(proof.snapshots) && proof.snapshots.length === 13);
  return ["disabled-drained", "updated-disabled-drained"].map((stage) => {
    const matches = proof.snapshots.filter(
      (snapshot) => snapshot.stage === stage,
    );
    assert.equal(matches.length, 1);
    const state = matches[0].state;
    assert.deepEqual(state.workers, {});
    assert.deepEqual(state.presentationCounts, {});
    const processes = state.ownedProcesses;
    assert(Array.isArray(processes) && processes.length <= 64);
    for (const role of ["engine", "managedUI"]) {
      const owned = processes.filter((item) => item.role === role);
      assert(owned.length > 0, `No known ${role} generation at ${stage}`);
      assert(
        owned.every(
          (item) => item.running === false && item.residentBytes == null,
        ),
        `Owned ${role} generation remained at ${stage}`,
      );
    }
    return {
      stage,
      runningEngineProcesses: 0,
      runningManagedUIProcesses: 0,
      ownedExtensionResidentBytes: 0,
      residencyBasis: "verifiedOwnedGenerationExit",
      residentMeasurement: "notApplicableAfterExit",
    };
  });
}
