import EdithExtensionSupport
import Foundation
import Testing
@testable import UsageExtension

@MainActor
@Suite struct UsagePresenterMenuBarTests {
    @Test func menuBarNumbersFollowThePublishedPresenterState() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "usage-presenter-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let channel = ExtensionSharedState(
            root: root, namespace: "usage.presenter.\(UUID().uuidString)", owner: "presenter")
        let state = UsagePresenterState(channel: channel)
        defer { state.shutdown() }
        #expect(!state.hidesMenuBarNumbers)

        try channel.publish(["active": "1", "hideMenuBarNumbers": "1"])
        state.refresh()
        #expect(state.hidesMenuBarNumbers)

        try channel.publish(["active": "0", "hideMenuBarNumbers": "1"])
        state.refresh()
        #expect(!state.hidesMenuBarNumbers)

        try channel.publish(["active": "1", "hideMenuBarNumbers": "0"])
        state.refresh()
        #expect(!state.hidesMenuBarNumbers)
    }
}
