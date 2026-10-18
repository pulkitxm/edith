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
}
