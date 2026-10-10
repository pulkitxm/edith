import { expect, test } from "bun:test";
import { execFileSync } from "node:child_process";
import {
  chmod,
  link,
  mkdtemp,
  readFile,
  realpath,
  rm,
  stat,
  symlink,
  utimes,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { managedProcessPaths } from "./hosted-managed-views/owned-cleanup.mjs";
import {
  managedToolEnvironment,
  readOwnedManagedDocument,
  runManagedOwner,
} from "./hosted-managed-views/run-owner.mjs";

const source = "a".repeat(40);
const environment = {
  GITHUB_ACTIONS: "true",
  RUNNER_OS: "macOS",
  RUNNER_ENVIRONMENT: "github-hosted",
  GITHUB_REPOSITORY: "pulkitxm/edith",
  GITHUB_ACTOR_ID: "65671483",
  GITHUB_EVENT_NAME: "workflow_dispatch",
  GITHUB_REF: "refs/heads/feat/hosted-managed-view-execution",
  GITHUB_SHA: source,
  EXPECTED_SOURCE_SHA: source,
  EDITH_HOSTED_MANAGED_VIEWS: "1",
  PUBLISH: "false",
  REBUILD: "",
  HOME: "/owned-runner",
  GITHUB_TOKEN: "never-copy",
  SSH_AUTH_SOCK: "never-copy",
};
const owner = {
  id: "music",
  location: "main",
  section: "music",
  factoryOverlay: false,
};
const proof = {
  schema: 1,
  outcome: "passed",
  extensionID: "music",
  selectedVersion: "1.0.0",
  hostABI: "edith-host-2",
  location: "main",
  section: "music",
  factoryOverlay: false,
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
  featurePayloadUnchanged: true,
};
async function setup() {
  const directory = await realpath(
    await mkdtemp(join(tmpdir(), "edith-managed-owner-")),
  );
  const fixture = {
    directory,
    app: join(directory, "Fixture.app"),
    identifier:
      "com.pulkit.edith.tests.worker-00000000-0000-4000-8000-000000000001",
    sourceCommit: source,
    originalSourceCommit: "b".repeat(40),
    extensionID: "music",
    package: {
      version: "1.0.0",
      architecture: "arm64",
      hostABI: "edith-host-2",
      sha256: "c".repeat(64),
    },
    originalZipSHA256: "d".repeat(64),
  };
  return fixture;
}
test("producer observes actual execution concurrently and requires drain and managed result independently of approval", async () => {
  const fixture = await setup();
  let running = false;
  let reads = 0;
  try {
    const row = {
      pid: 101,
      generation: "1234.99",
      uid: process.getuid(),
      executable: join(fixture.app, "Contents/MacOS/Edith"),
      hostIdentifier: fixture.identifier,
    };
    const result = await runManagedOwner({
      fixture,
      owner,
      plan: "synthetic-plan",
      resultBundle: "synthetic-result",
      environment,
      configure: () => {},
      cleanupControl: async () => [],
      pause: () => new Promise((resolve) => setTimeout(resolve, 1)),
      audit: async () => {
        reads++;
        return running ? [row] : [];
      },
      runCommand: async (_command, args, options) => {
        expect(args).toContain("test-without-building");
        expect(options.env).not.toHaveProperty("GITHUB_TOKEN");
        expect(options.env).not.toHaveProperty("SSH_AUTH_SOCK");
        running = true;
        await new Promise((resolve) => setTimeout(resolve, 20));
        await writeFile(
          join(fixture.directory, "result-managed-shipping.json"),
          JSON.stringify(proof),
          { mode: 0o600 },
        );
        running = false;
      },
    });
    expect(reads).toBeGreaterThan(3);
    expect(result.hostObservations).toHaveLength(1);
    expect(result.approval.approvalNotRequested).toBe(true);
    expect(result.proof.functionalActionsValidated).toBe(false);
  } finally {
    await rm(fixture.directory, { recursive: true, force: true });
  }
});
test("metadata-only fake completion, remaining Host and failed commands cannot become managed success", async () => {
  for (const type of ["unobserved", "remained", "failed"]) {
    const fixture = await setup();
    let done = false;
    try {
      await expect(
        runManagedOwner({
          fixture,
          owner,
          plan: "plan",
          resultBundle: "result",
          environment,
          configure: () => {},
          cleanupControl: async () => [],
          pause: () => new Promise((resolve) => setTimeout(resolve, 1)),
          audit: async () =>
            type === "remained" && done
              ? [
                  {
                    pid: 101,
                    generation: "100.1",
                    uid: process.getuid(),
                    executable: join(fixture.app, "Contents/MacOS/Edith"),
                    hostIdentifier: fixture.identifier,
                  },
                ]
              : [],
          runCommand: async () => {
            done = true;
            await writeFile(
              join(fixture.directory, "result-managed-shipping.json"),
              JSON.stringify(proof),
              { mode: 0o600 },
            );
            if (type === "failed") throw Error("actual command failed");
          },
        }),
      ).rejects.toThrow();
    } finally {
      await rm(fixture.directory, { recursive: true, force: true });
    }
  }
});
test("producer refuses unsafe postlaunch reads, unknown names and tool credential leakage", async () => {
  const fixture = await setup();
  try {
    await writeFile(join(fixture.directory, "target"), "{}", { mode: 0o600 });
    await symlink(
      join(fixture.directory, "target"),
      join(fixture.directory, "approval-result.json"),
    );
    await expect(
      readOwnedManagedDocument(fixture.directory, "approval-result.json"),
    ).rejects.toThrow();
    await expect(
      readOwnedManagedDocument(fixture.directory, "other.json"),
    ).rejects.toThrow();
    expect(managedToolEnvironment(environment)).toEqual({
      HOME: "/owned-runner",
    });
  } finally {
    await rm(fixture.directory, { recursive: true, force: true });
  }
});

test("owned receipt reader rejects FIFO, hardlink, public modes and real same-size mutations", async () => {
  const fixture = await setup();
  const path = join(fixture.directory, "result-managed-shipping.json");
  try {
    execFileSync("mkfifo", [path]);
    await expect(
      readOwnedManagedDocument(
        fixture.directory,
        "result-managed-shipping.json",
      ),
    ).rejects.toThrow();
    await rm(path);
    await writeFile(path, '{"value":1}', { mode: 0o644 });
    expect(
      await readOwnedManagedDocument(
        fixture.directory,
        "result-managed-shipping.json",
      ),
    ).toEqual({ value: 1 });
    await link(path, join(fixture.directory, "hardlink"));
    await expect(
      readOwnedManagedDocument(
        fixture.directory,
        "result-managed-shipping.json",
      ),
    ).rejects.toThrow();
    await rm(join(fixture.directory, "hardlink"));
    await chmod(path, 0o666);
    await expect(
      readOwnedManagedDocument(
        fixture.directory,
        "result-managed-shipping.json",
      ),
    ).rejects.toThrow();
    await chmod(path, 0o644);
    const before = await stat(path);
    await expect(
      readOwnedManagedDocument(
        fixture.directory,
        "result-managed-shipping.json",
        65536,
        async () => {
          await writeFile(path, '{"value":2}');
          await utimes(path, before.atime, before.mtime);
        },
      ),
    ).rejects.toThrow();
    await writeFile(join(fixture.directory, "approval-result.json"), "{}", {
      mode: 0o644,
    });
    await expect(
      readOwnedManagedDocument(fixture.directory, "approval-result.json"),
    ).rejects.toThrow();
    await chmod(fixture.directory, 0o740);
    await expect(
      readOwnedManagedDocument(
        fixture.directory,
        "result-managed-shipping.json",
      ),
    ).rejects.toThrow();
  } finally {
    await chmod(fixture.directory, 0o700);
    await rm(fixture.directory, { recursive: true, force: true });
  }
});

test("failed XCTest with a surviving LaunchServices Host performs pinned cleanup and remains failed", async () => {
  const fixture = await setup();
  const host = {
    pid: 101,
    generation: "100.1",
    uid: process.getuid(),
    executable: join(fixture.app, "Contents/MacOS/Edith"),
    hostIdentifier: fixture.identifier,
  };
  let running = false;
  const operations = [];
  try {
    let caught;
    try {
      await runManagedOwner({
        fixture,
        owner,
        plan: "plan",
        resultBundle: "result",
        environment,
        configure: () => {},
        pause: async () => {
          await new Promise((resolve) => setTimeout(resolve, 1));
        },
        audit: async () => (running ? [host] : []),
        inspectOwned: async () => (running ? [{ ...host, role: "host" }] : []),
        cleanupControl: async (operation) => {
          operations.push(operation);
          if (operation === "--terminate-host") running = false;
          return running ? [{ ...host, role: "host" }] : [];
        },
        runCommand: async () => {
          running = true;
          await new Promise((resolve) => setTimeout(resolve, 20));
          throw Error("owned XCTest timed out");
        },
      });
    } catch (error) {
      caught = error;
    }
    expect(caught.message).toBe("owned XCTest timed out");
    expect(caught.cleanup.outcome).toBe("drained");
    expect(caught.cleanup.managedViewPassed).toBe(false);
    expect(caught.cleanup.initialOwnedGenerations).toBe(1);
    expect(operations).toContain("--terminate-host");
    expect(running).toBe(false);
    expect(
      JSON.parse(
        await readFile(join(fixture.directory, "cleanup-result.json")),
      ),
    ).toEqual(caught.cleanup);
    await expect(
      readFile(join(fixture.directory, "execution-result.json")),
    ).rejects.toThrow();
  } finally {
    await rm(fixture.directory, { recursive: true, force: true });
  }
});

test("independent peer observation acknowledges exact source and owned generation before managed fixture can close", async () => {
  const fixture = await setup();
  const host = {
    pid: 101,
    generation: "100.1",
    uid: process.getuid(),
    executable: join(fixture.app, "Contents/MacOS/Edith"),
    hostIdentifier: fixture.identifier,
  };
  const paths = managedProcessPaths(fixture);
  const peers = [
    { ...host, role: "host" },
    { ...host, pid: 102, role: "engine" },
    { ...host, pid: 103, role: "ui", executable: paths.ui },
  ];
  let running = false;
  try {
    const result = await runManagedOwner({
      fixture,
      owner,
      plan: "plan",
      resultBundle: "result",
      environment,
      configure: () => {},
      pause: async () => new Promise((resolve) => setTimeout(resolve, 1)),
      audit: async () => (running ? [host] : []),
      inspectOwned: async () => (running ? peers : []),
      cleanupControl: async () => [],
      runCommand: async () => {
        running = true;
        const deadline = Date.now() + 1000;
        let acknowledgement;
        while (Date.now() < deadline) {
          try {
            acknowledgement = JSON.parse(
              await readFile(join(fixture.directory, "managed-peer-ack.json")),
            );
            break;
          } catch (error) {
            if (error.code !== "ENOENT") throw error;
            await new Promise((resolve) => setTimeout(resolve, 1));
          }
        }
        expect(acknowledgement.sourceCommit).toBe(source);
        expect(acknowledgement.extensionID).toBe("music");
        expect(acknowledgement.processes).toEqual(
          peers.map(({ pid, generation, role }) => ({ pid, generation, role })),
        );
        await writeFile(
          join(fixture.directory, "result-managed-shipping.json"),
          JSON.stringify(proof),
          { mode: 0o600 },
        );
        running = false;
      },
    });
    expect(result.observedOwnedProcesses).toHaveLength(3);
    expect(result.cleanup.independentlyPinnedGenerationsExited).toBe(true);
    expect(result.cleanup.actions).toEqual([]);
  } finally {
    await rm(fixture.directory, { recursive: true, force: true });
  }
});
