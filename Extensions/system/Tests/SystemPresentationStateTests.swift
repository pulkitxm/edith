import EdithExtensionSupport
import Foundation
import Testing
@testable import SystemExtension

@MainActor
@Suite struct SystemPresentationStateTests {
    @Test func presentationBlurHonorsTheOwnersSettingAndClearsOnDisable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let channel = ExtensionSharedState(root: root, namespace: "fixture", owner: "presenter")
        let state = SystemPresentationState(channel: channel)
        defer { state.shutdown() }
        #expect(!state.hideApps)
        try channel.publish(["active": "1", "blurRunningApps": "1"])
        state.refresh()
        #expect(state.hideApps)
        try channel.publish(["active": "1", "blurRunningApps": "0"])
        state.refresh()
        #expect(!state.hideApps)
        try channel.publish(["active": "1", "blurRunningApps": "1"])
        state.refresh()
        try channel.clear("presenter")
        state.refresh()
        #expect(!state.hideApps)
        state.shutdown()
        try channel.publish(["active": "1"])
        state.refresh()
        #expect(!state.hideApps)
    }
}
