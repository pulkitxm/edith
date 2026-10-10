import Darwin
import Foundation
import Testing

@testable import EdithHostCore

@Suite struct HostAppDiagnosticsCLITests {
    @Test func originalOpenPathPreparationUsesOnlyIsolatedOwnedDirectoriesAndRefreshLogFallback()
        throws
    {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "app-paths-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let identity = try HostIdentity(
            identifier: "com.pulkit.edith.tests.app-paths-\(UUID().uuidString)",
            supportDirectory: root)
        let suite = identity.applicationDefaultsSuite
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let music = try HostAppPathsCLI.prepareOpen(
            "music", identity: identity, defaults: defaults, homeDirectory: root)
        #expect(FileManager.default.fileExists(atPath: music.url.path) && !music.reveal)
        let cloud = try HostAppPathsCLI.prepareOpen(
            "icloud", identity: identity, defaults: defaults, homeDirectory: root)
        #expect(
            cloud.url.path.hasPrefix(identity.root.path + "/")
                && FileManager.default.fileExists(atPath: cloud.url.path))
        let fallback = try HostAppPathsCLI.prepareOpen(
            "refresh-log", identity: identity, defaults: defaults, homeDirectory: root)
        #expect(
            fallback.url
                == identity.effectiveExtensionDirectory("usage").appendingPathComponent("data")
                && !fallback.reveal)
        try FileManager.default.createDirectory(at: fallback.url, withIntermediateDirectories: true)
        try Data("synthetic refresh\n".utf8).write(
            to: fallback.url.appendingPathComponent("refresh.log"))
        #expect(
            try HostAppPathsCLI.prepareOpen(
                "refresh-log", identity: identity, defaults: defaults, homeDirectory: root
            ).reveal)
        #expect(throws: HostCLIError.self) {
            try HostAppPathsCLI.prepareOpen(
                "foreign", identity: identity, defaults: defaults, homeDirectory: root)
        }
    }
    @Test func diagnosticsReadTheActualOwnedProcessAndReportUnavailableCoreHonestly() throws {
        let agent = HostAppDiagnosticsCLI.core(
            snapshot: nil, online: false, state: "offline", build: "fixture")
        let value = try HostAppDiagnosticsCLI.process(
            info: .object([:]), startedAt: Date(), agent: agent, extensionIDs: [])
        #expect(value.object?["pid"] == .integer(Int64(getpid())))
        #expect(try #require(value.object?["idleWakeups"]?.integer) >= 0)
        #expect(value.object?["uptime"] == .string("0m"))
        #expect(agent.object?["running"] == .bool(false) && agent.object?["residentBytes"] == nil)
        #expect(HostAppDiagnosticsCLI.uptime(3660) == "1h 1m")
    }
}
