import { expect, test } from "bun:test";
import { readFile } from "node:fs/promises";
import {
  sparkleEntryOverlay,
  sparkleUpdaterOverlay,
} from "./hosted-sparkle-update/source-overlay.mjs";

const pins = {
  sourceCommit: "a".repeat(40),
  issuerPublicKey: Buffer.alloc(32, 1).toString("base64"),
  signingRequirement:
    'identifier "com.pulkit.edith.tests.remote-fixture" and anchor trusted',
};

test("only the copied empty-argument host branch authenticates before constructing original application state", async () => {
  const source = await readFile(
    "Packages/EdithHost/Sources/EdithHost/HostEntry.swift",
    "utf8",
  );
  const result = sparkleEntryOverlay(source, pins);
  const start = result.indexOf("try HostSparkleBootstrap.restore(");
  expect(start).toBeGreaterThan(
    result.indexOf('arguments == ["--extension-worker"]'),
  );
  expect(start).toBeGreaterThan(
    result.indexOf("guard arguments.isEmpty else { exit(1) }"),
  );
  expect(start).toBeLessThan(result.indexOf("HostApplication.main()"));
  expect(result).toContain("catch { exit(1) }");
  expect(result.indexOf('guard getenv("EDITH_CLI") == nil')).toBeLessThan(
    result.indexOf(
      'if ProcessInfo.processInfo.environment["EDITH_CLI"] == "1"',
    ),
  );
  expect(result).not.toContain(
    "guard arguments.isEmpty else { HostCommandCLI.main(arguments: arguments) }",
  );
  expect(result).toContain(pins.sourceCommit);
  expect(result).toContain(pins.issuerPublicKey);
  expect(source).not.toContain("HostSparkleBootstrap");
  for (const value of [
    source + source,
    source.replace("HostApplication.main()", "different"),
  ])
    expect(() => sparkleEntryOverlay(value, pins)).toThrow();
  for (const value of [
    { ...pins, sourceCommit: "wrong" },
    { ...pins, sourceCommit: `${pins.sourceCommit}\n` },
    { ...pins, issuerPublicKey: "wrong" },
    { ...pins, signingRequirement: 'identifier "fixture"\nforeign' },
    { ...pins, signingRequirement: `${pins.signingRequirement}\n` },
  ])
    expect(() => sparkleEntryOverlay(source, value)).toThrow();
});

test("the actual standard updater retains production guards and delegate events only qualify authenticated copied fixtures", async () => {
  const source = await readFile(
    "Packages/EdithHost/Sources/EdithHost/HostUpdater.swift",
    "utf8",
  );
  const result = sparkleUpdaterOverlay(source);
  expect(result).toContain(
    'Bundle.main.bundleIdentifier == "com.pulkit.edith"',
  );
  expect(result).toContain(
    'Bundle.main.bundleURL.path == "/Applications/Edith.app"',
  );
  expect(result).toContain("|| HostSparkleBootstrap.admitted");
  expect(result).toContain("SPUStandardUpdaterController(");
  expect(result).toContain("updaterController?.checkForUpdates(nil)");
  for (const stage of ["downloaded", "extracted", "installing", "relaunching"])
    expect(result).toContain(`HostSparkleBootstrap.record("${stage}")`);
  expect(source).not.toContain("HostSparkleBootstrap");
  for (const value of [
    source + source,
    source.replace('"/Applications/Edith.app"', '"/foreign"'),
  ])
    expect(() => sparkleUpdaterOverlay(value)).toThrow();
});
