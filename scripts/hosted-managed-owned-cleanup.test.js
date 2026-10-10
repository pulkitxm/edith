import { expect, test } from "bun:test";
import { mkdtemp, readFile, realpath, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  cleanupManagedOwnedProcesses,
  managedProcessPaths,
  recordManagedOwnedProcesses,
} from "./hosted-managed-views/owned-cleanup.mjs";

async function fixture() {
  const directory = await realpath(
    await mkdtemp(join(tmpdir(), "edith-managed-cleanup-")),
  );
  return {
    directory,
    app: join(directory, "Fixture.app"),
    identifier:
      "com.pulkit.edith.tests.worker-00000000-0000-4000-8000-000000000001",
    extensionID: "music",
    package: {
      id: "music",
      architecture: "arm64",
      hostABI: "edith-host-2",
      version: "1.0.0",
    },
  };
}
function row(fixture, role, pid) {
  return {
    pid,
    role,
    generation: "100.1",
    uid: process.getuid(),
    executable: managedProcessPaths(fixture)[role],
    hostIdentifier: fixture.identifier,
  };
}
test("closed ownership ledger rejects foreign paths, UID, roles, PID reuse and new Host generations", async () => {
  const value = await fixture();
  try {
    const host = row(value, "host", 101);
    const ledger = recordManagedOwnedProcesses(
      [],
      [host],
      value,
      process.getuid(),
    );
    for (const forged of [
      { ...host, uid: process.getuid() + 1 },
      { ...host, executable: "/foreign/Edith" },
      { ...host, hostIdentifier: "com.pulkit.edith" },
      { ...host, role: "unknown" },
      { ...host, generation: "100.2" },
      { ...host, pid: 102 },
      row(value, "cameraCarrier", 103),
    ])
      expect(() =>
        recordManagedOwnedProcesses(
          [...ledger],
          [forged],
          value,
          process.getuid(),
        ),
      ).toThrow();
    expect(
      recordManagedOwnedProcesses(
        ledger,
        [host, row(value, "engine", 102), row(value, "ui", 103)],
        value,
        process.getuid(),
      ),
    ).toHaveLength(3);
  } finally {
    await rm(value.directory, { recursive: true, force: true });
  }
});
test("failed command cleanup requests exact Host first, drains associated generations and records failure-only receipt", async () => {
  const value = await fixture();
  const ledger = [
    row(value, "host", 101),
    row(value, "engine", 102),
    row(value, "ui", 103),
  ];
  let remaining = [...ledger],
    clock = 0;
  const operations = [];
  try {
    const receipt = await cleanupManagedOwnedProcesses({
      fixture: value,
      ledger,
      now: () => clock,
      pause: async (ms) => {
        clock += ms;
      },
      control: async (operation) => {
        operations.push(operation);
        if (operation === "--terminate-host")
          remaining = remaining.filter(({ role }) => role !== "host");
        if (operation === "--terminate-workers") remaining = [];
        return remaining;
      },
    });
    expect(operations.indexOf("--terminate-host")).toBeLessThan(
      operations.indexOf("--terminate-workers"),
    );
    expect(receipt.independentlyPinnedGenerationsExited).toBe(true);
    expect(receipt.managedViewPassed).toBe(false);
    expect(receipt.observedGenerations).toHaveLength(3);
    expect(
      JSON.parse(await readFile(join(value.directory, "cleanup-result.json"))),
    ).toEqual(receipt);
    expect(
      JSON.parse(await readFile(join(value.directory, "cleanup-ledger.json"))),
    ).toEqual(ledger);
  } finally {
    await rm(value.directory, { recursive: true, force: true });
  }
});
test("bounded escalation fails closed on surviving generations or forged control response", async () => {
  for (const kind of ["survivor", "forged"]) {
    const value = await fixture();
    const ledger = [row(value, "host", 101)];
    let clock = 0;
    try {
      await expect(
        cleanupManagedOwnedProcesses({
          fixture: value,
          ledger,
          now: () => clock,
          pause: async (ms) => {
            clock += ms;
          },
          control: async () =>
            kind === "forged"
              ? [{ ...ledger[0], generation: "200.1" }]
              : ledger,
        }),
      ).rejects.toThrow();
      if (kind === "survivor") {
        const result = JSON.parse(
          await readFile(join(value.directory, "cleanup-result.json")),
        );
        expect(result.outcome).toBe("failed");
        expect(result.actions).toEqual([
          "--terminate-host",
          "--terminate-workers",
          "--kill",
        ]);
        expect(result.remainingOwnedGenerations).toBe(1);
      }
    } finally {
      await rm(value.directory, { recursive: true, force: true });
    }
  }
});
