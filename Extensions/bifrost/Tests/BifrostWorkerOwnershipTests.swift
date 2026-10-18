import EdithExtensionSupport
import Foundation
import Testing

@testable import BifrostExtension

@Suite(.serialized) @MainActor struct BifrostWorkerOwnershipTests {
    private final class Panel: BifrostWorkerPanel {
        var store: BifrostStore?
        var toggles = 0
        var stops = 0
        func toggle(query: String) { toggles += 1 }
        func shutdown() { stops += 1; store = nil }
    }

    private func withStore(
        _ body: (BifrostStore, UserDefaults, BifrostIndexStore) async throws -> Void
    ) async throws {
        let name = "com.pulkit.edith.tests.bifrost-worker-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: root)
        }
        let index = BifrostIndexStore(location: root.appendingPathComponent("index.json"))
        index.save(.init(generatedAt: Date(), applications: BifrostFixture.applications))
        let store = BifrostStore(
            store: defaults, indexStore: index,
            rateStore: BifrostRateStore(location: root.appendingPathComponent("rates.json")),
            startServices: false,
            fetchRates: {
                Issue.record("Idle fixture must not fetch rates"); return nil
            },
            scan: {
                Issue.record("Idle fixture must not scan applications"); return []
            },
            open: { _ in
                Issue.record("Idle fixture must not open applications"); return false
            },
            copy: { _ in Issue.record("Idle fixture must not write the clipboard") },
            post: { _ in Issue.record("Idle fixture must not post notifications") })
        try await body(store, defaults, index)
        await store.drain()
    }

    @Test func fixtureStartupAndDrainNeverAllocatePanelOrGlobalOwners() async throws {
        try await withStore { store, defaults, _ in
            var allocations = 0
            var seeded = 0
            var idleStoreRequests: [Bool] = []
            let panel = Panel()
            let ownership = BifrostWorkerPanelOwnership {
                allocations += 1
                return panel
            }
            let worker = BifrostWorker(
                fixture: true, recoveryOnly: false, panel: ownership,
                seedFixture: {
                    seeded += 1
                    defaults.set(true, forKey: AppStorageKeys.Bifrost.enabled)
                },
                makeStore: { idle in
                    idleStoreRequests.append(idle); return store
                })
            #expect(worker.store === store)
            #expect(seeded == 1)
            #expect(idleStoreRequests == [true])
            #expect(store.applications == BifrostFixture.applications)
            worker.configureHotKey()
            ownership.toggle()
            try await worker.prepareDisable()
            worker.shutdown()
            worker.shutdown()
            await worker.drain()
            #expect(allocations == 0)
            #expect(panel.store == nil)
            #expect(panel.toggles == 0)
            #expect(panel.stops == 0)
        }
    }

    @Test func recoveryWithoutFixtureDoesNotAllocatePanelOrSeedData() async throws {
        try await withStore { store, _, _ in
            let worker = BifrostWorker(
                fixture: false, recoveryOnly: true,
                panel: BifrostWorkerPanelOwnership {
                    Issue.record("Recovery must not allocate a panel"); return Panel()
                },
                seedFixture: { Issue.record("Recovery must not seed fixture data") },
                makeStore: { idle in
                    #expect(idle); return store
                })
            worker.configureHotKey()
            try await worker.prepareDisable()
            await worker.drain()
        }
    }

    @Test func ownedProductionPanelAttachesOnceAndStopsOnlyExistingInstance() async throws {
        try await withStore { store, _, _ in
            let panel = Panel()
            var allocations = 0
            let ownership = BifrostWorkerPanelOwnership {
                allocations += 1
                return panel
            }
            ownership.shutdown()
            #expect(allocations == 0)
            ownership.attach(store: store)
            ownership.attach(store: store)
            #expect(allocations == 1)
            #expect(panel.store === store)
            ownership.toggle()
            #expect(panel.toggles == 1)
            ownership.shutdown()
            ownership.shutdown()
            ownership.toggle()
            #expect(allocations == 1)
            #expect(panel.stops == 1)
            #expect(panel.toggles == 1)
            #expect(panel.store == nil)
        }
    }
}
