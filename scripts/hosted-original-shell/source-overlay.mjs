import assert from "node:assert/strict";

function replaceExact(source, before, after) {
  assert.equal(
    source.split(before).length,
    2,
    "Ambiguous fixture overlay anchor",
  );
  return source.replace(before, after);
}

export function originalShellFixtureOverlay(source) {
  let result = replaceExact(
    source,
    "@State private var coreServices: HostCoreServices?",
    "@State private var coreServices: HostGUIJourneyServices?",
  );
  const start = result.indexOf(
    "            let gateway = HostCLIGateway(marketplace: loaded)",
  );
  const end = result.indexOf(
    "            let manager = HostRemoteSessionManager(marketplace: loaded)",
  );
  assert(
    start >= 0 && end > start,
    "Missing fixture-only service qualification anchors",
  );
  const removed = result.slice(start, end);
  assert(removed.includes("HostCoreCLIAdapter.make("));
  assert(removed.includes("try control.start()"));
  assert(removed.includes("coreCLI = core"));
  result = result.slice(0, start) + result.slice(end);
  result = replaceExact(
    result,
    "let services = try HostCoreServices(",
    "let services = try HostGUIJourneyServices(",
  );
  result = replaceExact(
    result,
    "await services.shutdown(); core.shutdown(); control.shutdown()",
    "await services.shutdown()",
  );
  result = replaceExact(
    result,
    "let manager = HostRemoteSessionManager(marketplace: loaded)",
    "let manager = HostRemoteSessionManager(marketplace: loaded)\n            HostGUIFixture.bind(manager)",
  );
  return result;
}

export function fixturePermissionOverlay(source) {
  const start = source.indexOf("    static var live: Self {");
  const end = source.indexOf(
    "\n}\n\n@MainActor @Observable final class HostPermissions",
  );
  assert(
    start >= 0 && end > start,
    "Missing fixture permission dependency anchors",
  );
  const removed = source.slice(start, end);
  assert(removed.includes("UNUserNotificationCenter.current()"));
  assert(removed.includes("requestFullAccessToEvents()"));
  assert(removed.includes("NSWorkspace.shared.open"));
  return (
    source.slice(0, start) +
    `    static var live: Self {
        Self(
            read: { Dictionary(uniqueKeysWithValues: HostPermission.allCases.map { ($0, false) }) },
            request: { _ in HostGUIFixture.permissionRequestDeclined() },
            openSettings: { _ in false })
    }
` +
    source.slice(end)
  );
}

export function fixturePresenterOverlay(source) {
  return replaceExact(
    source,
    "width: state.width, receive: receive)",
    "width: state.width, receive: receive)\n                try HostGUIFixture.recordUI(handle)",
  );
}
