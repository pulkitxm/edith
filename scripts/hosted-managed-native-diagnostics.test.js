import { expect, test } from "bun:test";
import {
  mkdir,
  mkdtemp,
  realpath,
  rm,
  symlink,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { collectProbeDiagnostics } from "./hosted-managed-native/probe-diagnostics.mjs";

const uuid = "00000000-0000-4000-8000-000000000001";
const identifier = `com.pulkit.edith.tests.remote-${uuid}`;
async function fixture(work) {
  const temporary = await mkdtemp(join(tmpdir(), "hosted-probe-diagnostics-"));
  const home = await realpath(temporary);
  const directory = join(
    home,
    "Applications",
    `Edith Remote Fixture Hosted ${uuid}`,
  );
  await mkdir(directory, { recursive: true });
  try {
    await work({ home, directory, identifier });
  } finally {
    await rm(home, { recursive: true, force: true });
  }
}

test("failure diagnostics retain bounded synthetic stage receipts even when ready is missing", async () =>
  fixture(async (options) => {
    await writeFile(
      join(options.directory, "probe-startup.json"),
      JSON.stringify({
        hostIdentifier: identifier,
        outcome: "started",
        stage: "carrier-requested",
        argumentCount: 2,
      }),
    );
    await writeFile(
      join(options.directory, "approval-failure.json"),
      JSON.stringify({
        hostIdentifier: identifier,
        outcome: "failed",
        stage: "carrier-check-in",
        applicationReturned: false,
        errorDomain: "NSCocoaErrorDomain",
        errorCode: 1,
      }),
    );
    const result = await collectProbeDiagnostics(options);
    expect(result.records.map((record) => record.status)).toEqual([
      "observed",
      "observed",
      "missing",
      "missing",
      "missing",
    ]);
    expect(result.records[1].value.stage).toBe("carrier-check-in");
  }));

test("diagnostics reject foreign identity, unknown data, oversize and symlink receipts without sharing raw content", async () =>
  fixture(async (options) => {
    const path = join(options.directory, "approval-failure.json");
    for (const value of [
      { hostIdentifier: "com.pulkit.edith", stage: "carrier-check-in" },
      { hostIdentifier: identifier, stage: "unknown" },
      {
        hostIdentifier: identifier,
        stage: "carrier-check-in",
        credential: "sensitive",
      },
      {
        hostIdentifier: identifier,
        stage: "carrier-check-in",
        argumentCount: 129,
      },
    ]) {
      await writeFile(path, JSON.stringify(value));
      const result = await collectProbeDiagnostics(options);
      expect(result.records[1]).toEqual({
        name: "approval-failure.json",
        status: "invalid",
      });
      expect(JSON.stringify(result)).not.toContain("sensitive");
    }
    await writeFile(path, Buffer.alloc(16_385));
    expect((await collectProbeDiagnostics(options)).records[1].status).toBe(
      "invalid",
    );
    await rm(path);
    await symlink(join(options.home, "foreign"), path);
    expect((await collectProbeDiagnostics(options)).records[1].status).toBe(
      "invalid",
    );
  }));

test("diagnostics accept only the exact owned UUID root, never a production or alias directory", async () =>
  fixture(async (options) => {
    for (const change of [
      { identifier: "com.pulkit.edith" },
      { directory: options.home },
      { directory: `${options.directory}/../foreign` },
    ])
      await expect(
        collectProbeDiagnostics({ ...options, ...change }),
      ).rejects.toThrow();
    const alias = join(
      options.home,
      "Applications",
      `Edith Remote Fixture Hosted 00000000-0000-4000-8000-000000000002`,
    );
    await symlink(options.directory, alias);
    await expect(
      collectProbeDiagnostics({
        ...options,
        directory: alias,
        identifier: identifier.replace(
          uuid,
          "00000000-0000-4000-8000-000000000002",
        ),
      }),
    ).rejects.toThrow();
  }));

test("UI failure receipts expose only bounded state and argument categories", async () =>
  fixture(async (options) => {
    const path = join(options.directory, "ui-test-outcome.json");
    const value = {
      hostIdentifier: identifier,
      outcome: "failed",
      stage: "approval-window-wait",
      applicationState: 1,
      windowCount: 0,
      launchArgumentCount: 2,
      expectedWindowMatched: false,
      argumentKinds: ["approval-mode", "fixture-directory", "other"],
    };
    await writeFile(path, JSON.stringify(value));
    expect((await collectProbeDiagnostics(options)).records[4]).toEqual({
      name: "ui-test-outcome.json",
      status: "observed",
      value,
    });
    for (const change of [
      { applicationState: 5 },
      { windowCount: -1 },
      { launchArgumentCount: 129 },
      { expectedWindowMatched: "false" },
      { argumentKinds: ["private-value"] },
      { argumentKinds: Array(129).fill("other") },
    ]) {
      await writeFile(path, JSON.stringify({ ...value, ...change }));
      expect((await collectProbeDiagnostics(options)).records[4]).toEqual({
        name: "ui-test-outcome.json",
        status: "invalid",
      });
    }
  }));

test("the generated fixture entry compiles and handles probe arguments before ordinary CLI dispatch", async () => {
  const { hostedProbeEntry } = await import(
    "./hosted-managed-native/entry-overlay.mjs"
  );
  const { execFileSync } = await import("node:child_process");
  const entry = `import Foundation
import Darwin
struct ProbeLaunch { static func requested(_ value: [String]) -> Bool { false } }
struct HostedManagedApprovalProbe { static func dispatch(arguments: [String]) throws {} }
func runHost(arguments: [String]) {
        if ProcessInfo.processInfo.environment["EDITH_CLI"] == "1" { return }
}
`;
  const result = hostedProbeEntry(entry);
  expect(result.indexOf("ProbeLaunch.requested")).toBeLessThan(
    result.indexOf('environment["EDITH_CLI"]'),
  );
  expect(result).toContain("#if EDITH_CLI_FIXTURE");
  expect(() => hostedProbeEntry("missing anchor")).toThrow("Ambiguous");
  expect(() => hostedProbeEntry(entry + entry)).toThrow("Ambiguous");
  const directory = await mkdtemp(join(tmpdir(), "hosted-entry-compile-"));
  try {
    const file = join(directory, "Entry.swift");
    await writeFile(file, result);
    for (const arguments_ of [[], ["-D", "EDITH_CLI_FIXTURE"]])
      execFileSync(
        "xcrun",
        ["swiftc", "-typecheck", "-parse-as-library", ...arguments_, file],
        { stdio: "pipe", timeout: 30000 },
      );
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});
