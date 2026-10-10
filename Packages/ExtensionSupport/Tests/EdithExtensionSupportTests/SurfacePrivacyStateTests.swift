import Foundation
import Testing

@testable import EdithExtensionSupport

@MainActor @Suite struct SurfacePrivacyStateTests {
    @Test func presenterCategoriesKeepTheirOverridesAndNeverCoverClockOrControls() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let channel = ExtensionSharedState(
            root: root, namespace: UUID().uuidString, owner: "presenter")
        let state = SurfacePrivacyState(channel: channel)
        defer { state.shutdown() }
        #expect(!state.hides(.calendar))
        try channel.publish([
            "active": "1", "blurCalendar": "1", "blurMusic": "0", "blurMoney": "0",
        ])
        state.refresh()
        #expect(state.hides(.calendar))
        #expect(!state.hides(.music))
        #expect(!state.hides(.clocks) && !state.hides(.actions))
        #expect(!state.hides(.usage) && !state.hides(.limits))
        #expect(state.hides(.ability("machines")))
        #expect(state.hides(.ability("virtualCamera")))
        try channel.clear("presenter")
        state.refresh()
        #expect(!state.hides(.calendar) && !state.hides(.ability("machines")))
    }

    @Test func privacyObservationClearsOnDisableAndStopsAfterItsOwnerShutsDown() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let channel = ExtensionSharedState(
            root: root, namespace: UUID().uuidString, owner: "presenter")
        let state = SurfacePrivacyState(channel: channel)
        defer { state.shutdown() }
        try channel.publish(["active": "1", "blurCalendar": "1"])
        try await wait { state.hides(.calendar) }
        try channel.clear("presenter")
        try await wait { !state.hides(.calendar) }
        state.shutdown()
        try channel.publish(["active": "1", "blurCalendar": "1"])
        try await Task.sleep(for: .milliseconds(30))
        #expect(state.values.isEmpty)
    }

    private func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition() {
            guard Date() < deadline else { throw ExtensionPeerError.timedOut }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
