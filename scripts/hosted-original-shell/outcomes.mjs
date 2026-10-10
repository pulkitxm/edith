import assert from "node:assert/strict";

const packageDirectories = ["1.0.0", "1.1.0"].map((version) => ({
  version,
  relativePath: `Extensions/calendar/edith-host-2/arm64/${version}`,
}));

export function validateRemovedJourneyPackages(proof) {
  assert(Array.isArray(proof.snapshots) && proof.snapshots.length === 13);
  const recordsAt = (stage) => {
    const matches = proof.snapshots.filter(
      (snapshot) => snapshot.stage === stage,
    );
    assert.equal(matches.length, 1);
    const state = matches[0].state;
    assert.equal(state.protectedDataUnchanged, true);
    const records = state.packageDirectories;
    assert(Array.isArray(records) && records.length === 2);
    for (const [index, expected] of packageDirectories.entries()) {
      const record = records[index];
      assert.deepEqual(Object.keys(record).sort(), [
        "present",
        "relativePath",
        "version",
      ]);
      assert.equal(record.version, expected.version);
      assert.equal(record.relativePath, expected.relativePath);
      assert.equal(typeof record.present, "boolean");
    }
    return { state, records };
  };
  assert.equal(
    recordsAt("recommended-calendar-installed").records[0].present,
    true,
  );
  assert.equal(recordsAt("updated-calendar-version").records[1].present, true);
  return ["removed-packages", "storage-after-removal"].map((stage) => {
    const { state, records } = recordsAt(stage);
    assert.deepEqual(state.downloaded, []);
    assert(records.every((record) => record.present === false));
    return {
      stage,
      capturedVersionDirectories: records.map(
        ({ relativePath }) => relativePath,
      ),
      priorPresenceVerified: true,
      allCapturedVersionDirectoriesAbsent: true,
      protectedDataUnchanged: true,
    };
  });
}

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
