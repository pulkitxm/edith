@testable import HerdrUI
import Foundation
import Testing

@MainActor
struct HerdrWorkerResumeTests {
    @Test func aWorkerStartedAfterADisableResumesTheStoreItReuses() async throws {
        defer { HerdrWorkOwnership.enable() }
        let suite = "HerdrWorkerResume-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = HerdrStore(defaults: defaults, liveWatcher: { _ in }, machinesProvider: { [] })
        store.cancelPendingWork()
        await #expect(throws: CancellationError.self) { try await store.performTerminalWork {} }
        let worker = HerdrWorker(store: store, defaults: defaults, automaticActions: false)
        try await store.performTerminalWork {}
        await worker.shutdown()
    }
}
