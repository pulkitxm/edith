import EdithExtensionSupport
import Foundation
import Testing

@testable import HerdrUI

@MainActor @Suite struct HerdrPresenterOwnershipTests {
    @Test(arguments: [0, 1, 2])
    func engineAndPresentationsRetainPrivacyUntilTheirLastOwnerCloses(first: Int) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let channel = ExtensionSharedState(
            root: root, namespace: UUID().uuidString, owner: "presenter")
        let state = PresenterState(channel: { channel })
        let owners = [UUID(), UUID(), UUID()]
        defer { owners.forEach { state.release($0) } }
        try channel.publish(["active": "1", "blurAgents": "1"])
        owners.forEach { state.acquire($0) }
        #expect(state.active && state.hidesAgents)
        state.release(owners[first])
        state.release(owners[first])
        #expect(state.active && state.hidesAgents)
        try channel.publish(["active": "0"])
        try await wait { !state.active }
        try channel.publish(["active": "1", "blurAgents": "1"])
        try await wait { state.active && state.hidesAgents }
        let remaining = owners.enumerated().filter { $0.offset != first }.map(\.element)
        state.release(remaining[0])
        #expect(state.active && state.hidesAgents)
        state.release(remaining[1])
        #expect(!state.active && !state.hidesAgents)
        try channel.publish(["active": "1", "blurAgents": "1"])
        try await Task.sleep(for: .milliseconds(30))
        #expect(!state.active && !state.hidesAgents)
        state.acquire(owners[first])
        #expect(state.active && state.hidesAgents)
        state.release(owners[first])
        #expect(!state.active && !state.hidesAgents)
    }

    private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition() {
            guard ContinuousClock.now < deadline else { throw ExtensionPeerError.timedOut }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
