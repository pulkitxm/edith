import { expect, test } from "bun:test";
import { readFile } from "node:fs/promises";
import {
  managedContextOverlay,
  managedFactoryOverlay,
  managedFixtureOverlay,
} from "./hosted-managed-views/source-overlay.mjs";

test("current managed host overlay preserves actual manager lifecycle and requires issued marker before real engine starts", async () => {
  const source = await readFile(
    "Packages/EdithHost/Sources/EdithHost/HostRemoteFixture.swift",
    "utf8",
  );
  const result = managedFixtureOverlay(source);
  expect(result).toContain("try fixture.issue(selection");
  expect(result.indexOf("try fixture.issue(selection")).toBeLessThan(
    result.indexOf("return HostWorker("),
  );
  expect(result).toContain(
    "managedRoute?.hostIdentifier == Bundle.main.bundleIdentifier",
  );
  expect(result).toContain("location: route.location, section: route.section");
  expect(result).toContain('"functionalActionsValidated": false');
  expect(result).not.toContain('"readonlyControlVerified": true');
  for (const required of [
    "handle.isPresented",
    "handle.processIdentity",
    "!previous.isRunning",
    "manager.prepareToClose",
    "manager.endPresentation",
    "marketplace.sessions.disable",
    "uiProcesses.allSatisfy",
    "lease.close()",
  ])
    expect(result).toContain(required);
  expect(() => managedFixtureOverlay(result)).toThrow();
});

test("context overlay takes only selected authenticated configuration and never reads sandbox-external marker files", async () => {
  const source = await readFile(
    "Packages/EdithHost/Sources/EdithHost/HostRemoteApplication.swift",
    "utf8",
  );
  const result = managedContextOverlay(source, "a".repeat(40), {
    plugins: "b".repeat(64),
    studio: "c".repeat(64),
  });
  expect(result).toContain("configuration.package.sha256");
  expect(result).toContain("configuration.package.version");
  expect(result).toContain(
    'payload.appendingPathComponent(extensionID + "/app.bundle")',
  );
  expect(result).toContain(
    'hostIdentifier.hasPrefix("com.pulkit.edith.tests.worker-")',
  );
  expect(
    result
      .split('input["hostedManagedFixture"]')[1]
      .split("for runtime in runtimes")[0],
  ).not.toContain("Data(contentsOf:");
  expect(() => managedContextOverlay(source, "stale", {})).toThrow();
});

test("only two factory overlays change admission while actual model/view/control transport remains intact", async () => {
  for (const owner of ["plugins", "studio"]) {
    const source = await readFile(`Extensions/${owner}/Runtime.swift`, "utf8");
    const result = managedFactoryOverlay(source, owner);
    expect(result).toContain("HostedManagedFactoryAdmission.accepts(input");
    const ordinaryAdmission =
      owner === "plugins"
        ? "try validateOrdinaryContext(input)"
        : "guard try admitFixture(input) == nil";
    expect(result).toContain(ordinaryAdmission);
    expect(result).toContain(`extensionID: "${owner}"`);
    const managedGuard = result.slice(
      result.indexOf('if input["hostedManagedFixture"] != nil'),
      result.indexOf("HostedManagedFactoryAdmission.accepts(input"),
    );
    expect(managedGuard).toContain(
      'ProcessInfo.processInfo.environment["EDITH_FUNCTIONAL_FIXTURE"] == nil',
    );
    expect(managedGuard).toContain('input["hostedFunctionalFixture"] == nil');
    expect(result).toContain("ExtensionUIConfiguration(context:");
    expect(result).toContain("configuration.engineClient");
    expect(result).toContain('case "view":');
    const startCase = (value) => {
      const start = value.indexOf('case "start":');
      const next = value.indexOf("\n        case ", start + 1);
      return value.slice(start, next);
    };
    expect(startCase(result)).toBe(startCase(source));
    const viewCase = (value) => {
      const start = value.indexOf('case "view":');
      const next = value.indexOf("\n        case ", start + 1);
      return value.slice(start, next);
    };
    expect(viewCase(result)).toBe(viewCase(source));
    expect(() => managedFactoryOverlay(result, owner)).toThrow();
    expect(() => managedFactoryOverlay(source + source, owner)).toThrow();
    expect(() =>
      managedFactoryOverlay(source, owner === "plugins" ? "studio" : "plugins"),
    ).toThrow();
    expect(() =>
      managedFactoryOverlay(
        source.replace(ordinaryAdmission, "changedAdmission(input)"),
        owner,
      ),
    ).toThrow();
  }
  expect(() => managedFactoryOverlay("", "music")).toThrow();
});
