import EdithExtensionSupport
import Foundation
import Testing
@testable import CalendarExtension

@MainActor
@Suite struct CalendarPresentationStateTests {
    @Test func presentationBlurHonorsTheOwnersSettingAndClearsOnDisable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let channel = ExtensionSharedState(root: root, namespace: "fixture", owner: "presenter")
        let state = CalendarPresentationState(channel: channel)
        defer { state.shutdown() }
        #expect(!state.blurEvents)
        try channel.publish(["active": "1", "blurCalendar": "1"])
        state.refresh()
        #expect(state.blurEvents)
        try channel.publish(["active": "1", "blurCalendar": "0"])
        state.refresh()
        #expect(!state.blurEvents)
        try channel.publish(["active": "1", "blurCalendar": "1"])
        state.refresh()
        try channel.clear("presenter")
        state.refresh()
        #expect(!state.blurEvents)
        state.shutdown()
        try channel.publish(["active": "1"])
        state.refresh()
        #expect(!state.blurEvents)
    }
}
