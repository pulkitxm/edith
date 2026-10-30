import Foundation
import Testing

@testable import EdithHostCore

struct HostCLILaunchScopeTests {
    @Test func onlyInstalledAndDevelopmentBundlesLaunch() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(HostCLITransport.launchable(URL(fileURLWithPath: "/Applications/Edith.app")))
        #expect(
            HostCLITransport.launchable(URL(fileURLWithPath: home + "/Applications/Edith.app")))
        #expect(HostCLITransport.launchable(URL(fileURLWithPath: "/tmp/worktree/dist/Edith.app")))
        #expect(
            !HostCLITransport.launchable(
                URL(fileURLWithPath: "/tmp/worktree/local/minimal-host/Edith.app")))
        #expect(
            !HostCLITransport.launchable(
                URL(fileURLWithPath: "/tmp/worktree/local/extension-release-host/Edith.app")))
        #expect(
            !HostCLITransport.launchable(
                URL(fileURLWithPath: "/tmp/edith-host-package-abc/Edith.app")))
    }

    @Test func theClaudeStatusLineNeverLaunchesEdith() {
        #expect(!HostCommandCLI.launchesHost(for: ["usage", "statusline", "record"]))
        #expect(!HostCommandCLI.launchesHost(for: ["usage", "statusline", "record", "--json"]))
        #expect(HostCommandCLI.launchesHost(for: ["usage", "statusline", "install"]))
        #expect(HostCommandCLI.launchesHost(for: ["extensions", "ls"]))
        #expect(HostCommandCLI.launchesHost(for: []))
    }

    @Test func aMissingHostFailsAtOnceWhenLaunchingIsOff() throws {
        let identifier = "com.pulkit.edith.tests.no-launch-\(UUID().uuidString)"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(identifier)
        defer { try? FileManager.default.removeItem(at: root) }
        let identity = try HostIdentity(identifier: identifier, supportDirectory: root)
        let started = Date()
        let error = #expect(throws: HostCLIError.self) {
            try HostCLITransport.connect(identity: identity, timeout: 1, launchesHost: false)
        }
        guard case .unavailable = error else {
            Issue.record("expected the host to be unavailable")
            return
        }
        #expect(Date().timeIntervalSince(started) < 0.5)
    }
}
