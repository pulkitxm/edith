import { expect, test } from "bun:test";
import { readFile } from "node:fs/promises";
import {
  validateDisabledJourneyProcesses,
  validateRemovedJourneyPackages,
} from "./hosted-original-shell/outcomes.mjs";

function proof() {
  const state = () => ({
    workers: {},
    presentationCounts: {},
    ownedProcesses: [
      { role: "engine", running: false },
      { role: "managedUI", running: false },
    ],
  });
  return {
    snapshots: [
      { stage: "disabled-drained", state: state() },
      { stage: "updated-disabled-drained", state: state() },
      ...Array.from({ length: 11 }, (_, index) => ({
        stage: `synthetic-${index}`,
      })),
    ],
  };
}

test("disable receipts require observed engine and UI generations to exit before deriving zero residency", () => {
  const receipts = validateDisabledJourneyProcesses(proof());
  expect(receipts).toHaveLength(2);
  for (const receipt of receipts) {
    expect(receipt.ownedExtensionResidentBytes).toBe(0);
    expect(receipt.residencyBasis).toBe("verifiedOwnedGenerationExit");
    expect(receipt.residentMeasurement).toBe("notApplicableAfterExit");
  }
  for (const index of [0, 1])
    for (const change of [
      (state) => {
        state.ownedProcesses[1].running = true;
      },
      (state) => {
        state.ownedProcesses[1].residentBytes = 8192;
      },
      (state) => {
        state.ownedProcesses = state.ownedProcesses.filter(
          (item) => item.role !== "managedUI",
        );
      },
      (state) => {
        state.ownedProcesses[0].running = true;
      },
      (state) => {
        state.workers.calendar = 123;
      },
      (state) => {
        state.presentationCounts.calendar = 1;
      },
    ]) {
      const input = proof();
      change(input.snapshots[index].state);
      expect(() => validateDisabledJourneyProcesses(input)).toThrow();
    }
});

test("both actual disabled XCTest predicates await managed UI as well as engine exit", async () => {
  const source = await readFile(
    "Tests/HostedOriginalShell/UITests/OriginalShellJourneyTests.swift",
    "utf8",
  );
  for (const stage of ["disabled-drained", "updated-disabled-drained"]) {
    const predicate = source
      .split(`try await waitState("${stage}") {`)[1]
      .split("\n        }")[0];
    expect(predicate).toContain('!Self.running($0, role: "engine")');
    expect(predicate).toContain('!Self.running($0, role: "managedUI")');
  }
});

function removalProof() {
  return {
    snapshots: [
      "recommended-calendar-installed",
      "updated-calendar-version",
      "removed-packages",
      "storage-after-removal",
      ...Array.from({ length: 9 }, (_, index) => `synthetic-${index}`),
    ].map((stage, index) => ({
      stage,
      state: {
        downloaded: index < 2 ? ["calendar"] : [],
        protectedDataUnchanged: true,
        packageDirectories: ["1.0.0", "1.1.0"].map((version, packageIndex) => ({
          version,
          relativePath: `Extensions/calendar/edith-host-2/arm64/${version}`,
          present: index === packageIndex,
        })),
      },
    })),
  };
}

test("physical removal proof requires exact captured paths, prior presence and both absent snapshots", () => {
  const valid = removalProof();
  const receipts = validateRemovedJourneyPackages(valid);
  expect(receipts).toHaveLength(2);
  for (const receipt of receipts) {
    expect(receipt.allCapturedVersionDirectoriesAbsent).toBe(true);
    expect(receipt.priorPresenceVerified).toBe(true);
    expect(receipt.capturedVersionDirectories).toHaveLength(2);
  }
  for (const index of [0, 1, 2, 3]) {
    for (const mutate of [
      (state) => state.packageDirectories.pop(),
      (state) => {
        state.packageDirectories[0].relativePath = "Data/calendar";
      },
      (state) => {
        state.packageDirectories[1] = { ...state.packageDirectories[0] };
      },
      (state) => {
        state.packageDirectories[0].present = "false";
      },
      (state) => {
        state.protectedDataUnchanged = false;
      },
    ]) {
      const input = removalProof();
      mutate(input.snapshots[index].state);
      expect(() => validateRemovedJourneyPackages(input)).toThrow();
    }
  }
  for (const [index, packageIndex] of [
    [0, 0],
    [1, 1],
    [2, 0],
    [2, 1],
    [3, 0],
    [3, 1],
  ]) {
    const input = removalProof();
    input.snapshots[index].state.packageDirectories[packageIndex].present =
      index >= 2;
    expect(() => validateRemovedJourneyPackages(input)).toThrow();
  }
  const metadataOnly = removalProof();
  for (const snapshot of metadataOnly.snapshots)
    for (const record of snapshot.state.packageDirectories)
      record.present = false;
  expect(() => validateRemovedJourneyPackages(metadataOnly)).toThrow();
  const incomplete = removalProof();
  incomplete.snapshots.pop();
  expect(() => validateRemovedJourneyPackages(incomplete)).toThrow();
});

test("the actual journey observes both captured directories after metadata removal", async () => {
  const source = await readFile(
    "Tests/HostedOriginalShell/UITests/OriginalShellJourneyTests.swift",
    "utf8",
  );
  const predicate = source
    .split('try await waitState("removed-packages") {')[1]
    .split("\n        }")[0];
  expect(predicate).toContain('($0["downloaded"] as? [String]) == []');
  for (const version of ["1.0.0", "1.1.0"])
    expect(predicate).toContain(
      `Self.packageDirectoryPresence($0, version: "${version}") == false`,
    );
});
