import { expect, test } from "bun:test";
import { readFile } from "node:fs/promises";
import { validateDisabledJourneyProcesses } from "./hosted-original-shell/outcomes.mjs";

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
