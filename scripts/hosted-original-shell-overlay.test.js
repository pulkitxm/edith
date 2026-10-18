import { expect, test } from "bun:test";
import { readFile } from "node:fs/promises";
import { originalShellFixtureOverlay } from "./hosted-original-shell/source-overlay.mjs";

test("the hosted shell keeps original views and navigation while omitting unrelated live core starts", async () => {
  const source = await readFile(
    "Packages/EdithHost/Sources/EdithHost/HostRuntime.swift",
    "utf8",
  );
  const result = originalShellFixtureOverlay(source);
  expect(result).toContain("HostRemoteContentPresenter(manager: manager)");
  expect(result).toContain("loaded.sessions.didRequestNavigation");
  expect(result).toContain("await loaded.restoreEnabledExtensions()");
  expect(result).toContain("await services.start()");
  expect(result).not.toContain("HostCoreCLIAdapter.make(");
  expect(result).not.toContain("try control.start()");
  expect(result).not.toContain("let services = try HostCoreServices(");
  expect(source).toContain("let services = try HostCoreServices(");
});

test("ambiguous or changed service qualification fails rather than silently building a live fixture", async () => {
  const source = await readFile(
    "Packages/EdithHost/Sources/EdithHost/HostRuntime.swift",
    "utf8",
  );
  for (const value of [
    source + source,
    source.replace("coreCLI = core", "different"),
    source.replace(
      "private(set) var coreServices: HostCoreServices?",
      "different",
    ),
  ])
    expect(() => originalShellFixtureOverlay(value)).toThrow();
});

test("hosted permission dependencies never probe or request real account services", async () => {
  const { fixturePermissionOverlay } = await import(
    "./hosted-original-shell/source-overlay.mjs"
  );
  const source = await readFile(
    "Packages/EdithHost/Sources/EdithHost/HostPermissions.swift",
    "utf8",
  );
  const result = fixturePermissionOverlay(source);
  expect(result).toContain("HostGUIFixture.permissionRequestDeclined()");
  for (const value of [
    "authorizationStatus",
    "requestFullAccessToEvents",
    "AXIsProcessTrusted",
    "IOHIDCheckAccess",
    "CGPreflightScreenCaptureAccess",
    "NSWorkspace.shared.open",
  ])
    expect(result).not.toContain(value);
  expect(() =>
    fixturePermissionOverlay(
      source.replace("requestFullAccessToEvents()", "different"),
    ),
  ).toThrow();
});

test("only authenticated connected scenes contribute managed process receipts", async () => {
  const { fixturePresenterOverlay } = await import(
    "./hosted-original-shell/source-overlay.mjs"
  );
  const source = await readFile(
    "Packages/EdithHost/Sources/EdithHost/HostRemoteContentPresenter.swift",
    "utf8",
  );
  const result = fixturePresenterOverlay(source);
  expect(result.indexOf("try HostGUIFixture.recordUI(handle)")).toBeGreaterThan(
    result.indexOf("let presented = try await manager.presentScene("),
  );
  expect(() => fixturePresenterOverlay(source + source)).toThrow();
  expect(source).not.toContain("HostGUIFixture.recordUI(handle)");
});

test("navigation identifiers qualify the existing original buttons without changing their actions", async () => {
  const { fixtureNavigationOverlay } = await import(
    "./hosted-original-shell/source-overlay.mjs"
  );
  const source = await readFile(
    "Packages/EdithHost/Sources/EdithHost/HostWorkspace.swift",
    "utf8",
  );
  const result = fixtureNavigationOverlay(source);
  expect(result).toContain(
    '.accessibilityIdentifier("journey.navigation." + page.id)',
  );
  expect(result).toContain(
    '.accessibilityIdentifier("journey.section." + parent.id + "." + section.id)',
  );
  expect(result).toContain("select(page.id)");
  expect(result).toContain("settings = section.id");
  expect(() => fixtureNavigationOverlay(source + source)).toThrow();
});
