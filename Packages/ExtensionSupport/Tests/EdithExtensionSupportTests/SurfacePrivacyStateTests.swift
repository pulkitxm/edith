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
        #expect(!state.hides(.agents))
        try channel.publish([
            "active": "1", "blurAgents": "1", "blurCalendar": "1", "blurMusic": "0",
            "blurMoney": "0",
        ])
        state.refresh()
        #expect(state.hides(.agents))
        #expect(!state.hides(.calendar))
        #expect(!state.hides(.music))
        #expect(!state.hides(.clocks) && !state.hides(.actions))
        #expect(!state.hides(.usage) && !state.hides(.limits))
        #expect(!state.hides(.activity))
        #expect(state.hides(.ability("machines")))
        #expect(state.hides(.ability("virtualCamera")))
        try channel.clear("presenter")
        state.refresh()
        #expect(!state.hides(.agents) && !state.hides(.ability("machines")))
    }

    @Test func aConsumerCreatedBeforeAnEnabledPresenterRepublishesStartsHidden() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let channel = ExtensionSharedState(
            root: root, namespace: UUID().uuidString, owner: "presenter")
        try channel.publish(["enabled": "1", "active": "0", "blurMusic": "0", "blurAgents": "1"])
        try orphan(root.appendingPathComponent("presenter.json"))
        let state = SurfacePrivacyState(channel: channel)
        defer { state.shutdown() }
        #expect(state.hides(.agents) && state.hides(.machines) && state.hides(.ability("studio")))
        #expect(!state.hides(.music) && !state.hides(.clocks) && !state.hides(.actions))
        try channel.publish(["enabled": "1", "active": "0"])
        state.refresh()
        #expect(!state.hides(.agents))
    }

    @Test func aConsumerCreatedAfterPresenterWasDisabledStartsVisible() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let channel = ExtensionSharedState(
            root: root, namespace: UUID().uuidString, owner: "presenter")
        try channel.publish(["enabled": "0", "active": "0"])
        try orphan(root.appendingPathComponent("presenter.json"))
        let state = SurfacePrivacyState(channel: channel)
        defer { state.shutdown() }
        #expect(!state.hides(.agents) && !state.hides(.machines))
    }

    private func orphan(_ file: URL) throws {
        var snapshot =
            try #require(
                try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        snapshot["pid"] = Int32.max
        try JSONSerialization.data(withJSONObject: snapshot).write(to: file)
    }

    @Test func privacyObservationClearsOnDisableAndStopsAfterItsOwnerShutsDown() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let channel = ExtensionSharedState(
            root: root, namespace: UUID().uuidString, owner: "presenter")
        let state = SurfacePrivacyState(channel: channel)
        defer { state.shutdown() }
        try channel.publish(["active": "1", "blurAgents": "1"])
        try await wait { state.hides(.agents) }
        try channel.clear("presenter")
        try await wait { !state.hides(.agents) }
        state.shutdown()
        try channel.publish(["active": "1", "blurAgents": "1"])
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
