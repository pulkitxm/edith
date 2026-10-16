import Foundation
import Testing

import EdithExtensionSupport
@testable import AppMaintenanceExtension

@Suite struct AppMaintenanceSnapshotTests {
    @Test func snapshotRoundTripsApplicationsAndUpdates() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("snapshot.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = AppMaintenanceSnapshotStore(fileURL: url)
        let application = Self.application
        let snapshot = AppMaintenanceSnapshot(
            applications: [application], updates: [Self.storeItem],
            homebrewOutdated: Data("{\"casks\":[]}".utf8),
            homebrewCachedAt: Date(timeIntervalSince1970: 1_700_000_000))

        try await store.save(snapshot)
        let loaded = await store.load()

        #expect(loaded?.applications == [application])
        #expect(loaded?.updates == [Self.storeItem])
        #expect(loaded?.homebrewOutdated == snapshot.homebrewOutdated)
        #expect(loaded?.homebrewCachedAt == snapshot.homebrewCachedAt)
    }

    @Test func freshBrewCacheSkipsTheBrewProcess() async throws {
        let root = try Self.executables()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = DiscoveryRecorder()
        let data = Data(Self.brewJSON.utf8)

        let items = await AppUpdateDiscovery.discoverChannels(
            applications: [Self.application],
            brewPaths: [root.appendingPathComponent("brew").path],
            masPaths: [root.appendingPathComponent("mas").path],
            run: { request in
                recorder.append(request.executableURL.lastPathComponent)
                return CLICommandResult(terminationStatus: 0, output: "111 Example (1.0 -> 2.0)\n")
            },
            fetch: { _ in Data() },
            brewData: data,
            brewFresh: true)

        #expect(recorder.values == ["mas"])
        #expect(items.contains { $0.source == .homebrewCask })
    }

    @Test func eachSourcePublishesBeforeSlowerSourcesFinish() async throws {
        let root = try Self.executables()
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = DiscoveryGate()
        let seen = DiscoveryChannels()
        let brew = root.appendingPathComponent("brew").path
        let task = Task {
            await AppUpdateDiscovery.discoverChannels(
                applications: [Self.application],
                brewPaths: [brew],
                masPaths: [root.appendingPathComponent("mas").path],
                run: { request in
                    if request.executableURL.path == brew {
                        await gate.wait()
                        return CLICommandResult(
                            terminationStatus: 0, outputData: Data(Self.brewJSON.utf8))
                    }
                    return CLICommandResult(
                        terminationStatus: 0, output: "111 Example (1.0 -> 2.0)\n")
                },
                fetch: { _ in Data() },
                onBatch: { batch in
                    seen.append(batch.channel)
                })
        }
        let early = await seen.wait(count: 2, timeout: .seconds(3))

        #expect(early.contains(.appStore))
        #expect(early.contains(.feeds))
        #expect(!early.contains(.homebrew))
        gate.open()
        _ = await task.value
        #expect(seen.snapshot().contains(.homebrew))
    }

    private static func executables() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for name in ["brew", "mas"] {
            let url = root.appendingPathComponent(name)
            try Data("#!/bin/sh\n".utf8).write(to: url)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        return root
    }

    private static let application = InstalledApplication(
        id: "/Applications/Example.app", name: "Example", bundleID: "com.example.app",
        version: "1.0", url: URL(fileURLWithPath: "/Applications/Example.app"))

    private static let storeItem = AppUpdateItem(
        id: "mas:111", name: "Example", bundleID: "com.example.app",
        applicationPath: "/Applications/Example.app", source: .appStore,
        currentVersion: "1.0", availableVersion: "2.0", confidence: .high,
        checkedAt: Date(timeIntervalSince1970: 1_700_000_000), action: .install,
        executablePath: "/mas", arguments: ["upgrade", "111"])

    private static let brewJSON = """
        {"formulae":[],"casks":[{"name":"example","installed_versions":["1.0"],"current_version":"2.0"}]}
        """
}

@MainActor
@Suite struct AppMaintenanceModelSnapshotTests {
    @Test func cachedSnapshotShowsBeforeRefreshFinishes() async throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let snapshots = AppMaintenanceSnapshotStore(
            fileURL: directory.appendingPathComponent("snapshot.json"))
        let application = Self.application
        try await snapshots.save(
            AppMaintenanceSnapshot(applications: [application], updates: [Self.storeItem]))
        let gate = DiscoveryGate()
        let model = AppMaintenanceModel(
            persistence: AppUpdatePersistence(
                fileURL: directory.appendingPathComponent("state.json")),
            snapshots: snapshots,
            inventory: { _ in
                await gate.wait()
                return [application]
            },
            discover: { _, _, _, _ in [] })

        model.refresh()
        #expect(
            await Self.wait {
                model.phase == .ready && model.applications.map(\.name) == ["Example"]
            })
        #expect(model.checkingUpdates)
        #expect(model.updates.map(\.id) == [Self.storeItem.id])
        gate.open()
        #expect(await Self.wait { !model.checkingUpdates })
        #expect(model.phase == .ready)
        #expect(model.applications.map(\.name) == ["Example"])
    }

    @Test func uiSnapshotServesPersistedInventoryBeforeTheRefreshScanFinishes() async throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let snapshots = AppMaintenanceSnapshotStore(
            fileURL: directory.appendingPathComponent("snapshot.json"))
        let application = Self.application
        try await snapshots.save(
            AppMaintenanceSnapshot(applications: [application], updates: [Self.storeItem]))
        let gate = DiscoveryGate()
        let model = AppMaintenanceModel(
            persistence: AppUpdatePersistence(
                fileURL: directory.appendingPathComponent("state.json")),
            snapshots: snapshots,
            inventory: { _ in
                await gate.wait()
                return [application]
            },
            discover: { _, _, _, _ in [] })
        let decoder = JSONDecoder()

        let first = try decoder.decode(
            AppMaintenanceUISnapshot.self,
            from: try await AppMaintenanceUICommands.execute(
                "maintenance.ui.snapshot", payload: Data("{\"scope\":\"all\"}".utf8),
                model: model))
        #expect(first.phase == .ready)
        #expect(first.applications.map(\.name) == ["Example"])
        #expect(first.updates.map(\.id) == [Self.storeItem.id])

        let action = AppMaintenanceUIAction(
            operation: "refresh", value: nil, item: nil, enabled: false, integer: nil,
            number: 86_400, previewToken: model.previewToken, scope: .all)
        let refreshed = try decoder.decode(
            AppMaintenanceUISnapshot.self,
            from: try await AppMaintenanceUICommands.execute(
                "maintenance.ui.action", payload: JSONEncoder().encode(action), model: model))
        #expect(refreshed.phase == .ready)
        #expect(refreshed.checkingUpdates)
        #expect(refreshed.applications.map(\.name) == ["Example"])
        gate.open()
        #expect(await Self.wait { !model.checkingUpdates })
    }

    @Test func snapshotRequestAnswersFromMemoryWhileTheScanIsBlocked() async throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let snapshots = AppMaintenanceSnapshotStore(
            fileURL: directory.appendingPathComponent("snapshot.json"))
        let application = Self.application
        try await snapshots.save(
            AppMaintenanceSnapshot(applications: [application], updates: [Self.storeItem]))
        let gate = DiscoveryGate()
        let model = AppMaintenanceModel(
            persistence: AppUpdatePersistence(
                fileURL: directory.appendingPathComponent("state.json")),
            snapshots: snapshots,
            inventory: { _ in
                await gate.wait()
                return [application]
            },
            discover: { _, _, _, _ in [] })
        let decoder = JSONDecoder()
        await model.restoreCachedSnapshot()
        let action = AppMaintenanceUIAction(
            operation: "refresh", value: nil, item: nil, enabled: false, integer: nil,
            number: 86_400, previewToken: model.previewToken)
        let started = try decoder.decode(
            AppMaintenanceUISnapshot.self,
            from: try await AppMaintenanceUICommands.execute(
                "maintenance.ui.action", payload: JSONEncoder().encode(action), model: model))
        #expect(started.checkingUpdates && started.phase == .ready)

        let answered = AnsweredFlag()
        let request = Task { @MainActor in
            let data = try await AppMaintenanceUICommands.execute(
                "maintenance.ui.snapshot", payload: Data("{\"scope\":\"all\"}".utf8),
                model: model)
            answered.raise()
            return data
        }
        #expect(await Self.wait { answered.raised })
        let reply = try decoder.decode(AppMaintenanceUISnapshot.self, from: try await request.value)
        #expect(reply.phase == .ready && reply.checkingUpdates)
        #expect(reply.applications.map(\.name) == ["Example"])
        #expect(reply.updates.map(\.id) == [Self.storeItem.id])
        let light = try decoder.decode(
            AppMaintenanceUISnapshot.self,
            from: try await AppMaintenanceUICommands.execute(
                "maintenance.ui.snapshot", payload: Data("{}".utf8), model: model))
        #expect(light.scope == .updates)
        #expect(light.applications.isEmpty)
        #expect(light.updates.map(\.id) == [Self.storeItem.id])
        gate.open()
        #expect(await Self.wait { !model.checkingUpdates })
        await model.shutdown()
    }

    @Test func secondVisitRendersTheRememberedSnapshotOnTheFirstFrame() async throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let snapshots = AppMaintenanceSnapshotStore(
            fileURL: directory.appendingPathComponent("snapshot.json"))
        let application = Self.application
        try await snapshots.save(
            AppMaintenanceSnapshot(applications: [application], updates: [Self.storeItem]))
        let gate = DiscoveryGate()
        let engine = AppMaintenanceModel(
            persistence: AppUpdatePersistence(
                fileURL: directory.appendingPathComponent("state.json")),
            snapshots: snapshots,
            inventory: { _ in
                await gate.wait()
                return [application]
            },
            discover: { _, _, _, _ in [] })
        let bridge = SnapshotBridge(model: engine)
        let client = try #require(ExtensionEngineClient(bridge: bridge, presentationID: UUID()))
        let memory = AppMaintenanceUIMemory()

        let first = AppMaintenanceModel(engineClient: client, memory: memory)
        first.scope = .all
        #expect(first.phase == .loading && !first.loading.hasContent)
        await first.refreshRemote()
        #expect(first.phase == .ready && first.applications.map(\.name) == ["Example"])
        await first.shutdown()

        let second = AppMaintenanceModel(engineClient: client, memory: memory)
        #expect(second.phase == .ready && second.loading.state == .content)
        #expect(second.applications.map(\.name) == ["Example"])
        #expect(second.updates.map(\.id) == [Self.storeItem.id])
        gate.open()
        await second.shutdown()
        client.invalidate()
        await engine.shutdown()
    }

    @Test func secondRefreshKeepsApplicationsVisible() async throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = DiscoveryGate()
        let passes = DiscoveryCounter()
        let application = Self.application
        let model = AppMaintenanceModel(
            persistence: AppUpdatePersistence(
                fileURL: directory.appendingPathComponent("state.json")),
            snapshots: AppMaintenanceSnapshotStore(
                fileURL: directory.appendingPathComponent("snapshot.json")),
            inventory: { _ in
                if passes.next() > 1 { await gate.wait() }
                return [application]
            },
            discover: { _, _, _, _ in [] })

        model.refresh()
        #expect(await Self.wait { !model.checkingUpdates && model.phase == .ready })
        model.refresh()

        #expect(model.phase == .ready)
        #expect(model.applications.map(\.name) == ["Example"])
        try? await Task.sleep(for: .milliseconds(60))
        #expect(model.phase == .ready)
        #expect(model.checkingUpdates)
        #expect(model.applications.map(\.name) == ["Example"])
        gate.open()
        #expect(await Self.wait { !model.checkingUpdates })
    }

    @Test func eachSourceAppearsBeforeTheNextSourceFinishes() async throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = DiscoveryGate()
        let application = Self.application
        let storeItem = Self.storeItem
        let brewItem = Self.brewItem
        let model = AppMaintenanceModel(
            persistence: AppUpdatePersistence(
                fileURL: directory.appendingPathComponent("state.json")),
            snapshots: AppMaintenanceSnapshotStore(
                fileURL: directory.appendingPathComponent("snapshot.json")),
            inventory: { _ in [application] },
            discover: { _, _, _, onBatch in
                await onBatch(
                    AppUpdateDiscoveryBatch(channel: .appStore, items: [storeItem]))
                await gate.wait()
                await onBatch(
                    AppUpdateDiscoveryBatch(
                        channel: .homebrew, items: [brewItem],
                        homebrewData: Data(Self.brewJSON.utf8))
                )
                return [storeItem, brewItem]
            })

        model.refresh()
        #expect(await Self.wait { model.updates.contains { $0.id == storeItem.id } })
        #expect(!model.updates.contains { $0.source == .homebrewCask })
        gate.open()
        #expect(await Self.wait { model.updates.contains { $0.id == brewItem.id } })
        #expect(model.phase == .ready)
    }

    private static func directory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func wait(timeout: Duration = .seconds(3), _ condition: @MainActor () -> Bool)
        async -> Bool
    {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    private static let application = InstalledApplication(
        id: "/Applications/Example.app", name: "Example", bundleID: "com.example.app",
        version: "1.0", url: URL(fileURLWithPath: "/Applications/Example.app"))

    private static let storeItem = AppUpdateItem(
        id: "mas:111", name: "Example", bundleID: "com.example.app",
        applicationPath: "/Applications/Example.app", source: .appStore,
        currentVersion: "1.0", availableVersion: "2.0", confidence: .high,
        checkedAt: Date(timeIntervalSince1970: 1_700_000_000), action: .install,
        executablePath: "/mas", arguments: ["upgrade", "111"])

    private static let brewItem = AppUpdateItem(
        id: "homebrewCask:example", name: "Example", bundleID: "com.example.app",
        applicationPath: "/Applications/Example.app", source: .homebrewCask,
        currentVersion: "1.0", availableVersion: "2.0", confidence: .high,
        checkedAt: Date(timeIntervalSince1970: 1_700_000_000), action: .install,
        executablePath: "/brew", arguments: ["upgrade", "example"])

    private static let brewJSON = """
        {"formulae":[],"casks":[{"name":"example","installed_versions":["1.0"],"current_version":"2.0"}]}
        """
}

private final class AnsweredFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var raised: Bool { lock.withLock { value } }
    func raise() { lock.withLock { value = true } }
}

private final class SnapshotBridge: NSObject {
    let model: AppMaintenanceModel
    var tasks: [UUID: Task<Void, Never>] = [:]
    init(model: AppMaintenanceModel) { self.model = model }
    @objc func invoke(_ data: Data, completion: @escaping (Data) -> Void) {
        guard let request = try? ExtensionEngineWire.decode(ExtensionEngineRequest.self, from: data)
        else { completion(Data()); return }
        tasks[request.token] = Task { @MainActor in
            let payload = try? await AppMaintenanceUICommands.execute(
                request.operation, payload: request.payload, model: model)
            let reply = ExtensionEngineReply(
                token: request.token, ok: payload != nil, payload: payload ?? Data("{}".utf8))
            completion((try? ExtensionEngineWire.encode(reply)) ?? Data())
            tasks[request.token] = nil
        }
    }
    @objc func cancel(_ token: String) {
        guard let token = UUID(uuidString: token) else { return }
        tasks.removeValue(forKey: token)?.cancel()
    }
}

private final class DiscoveryCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.lock()
        value += 1
        let current = value
        lock.unlock()
        return current
    }
}

private final class DiscoveryRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ value: String) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private final class DiscoveryChannels: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [AppUpdateDiscoveryChannel] = []
    private var waiters: [(Int, CheckedContinuation<[AppUpdateDiscoveryChannel], Never>)] = []

    func append(_ channel: AppUpdateDiscoveryChannel) {
        lock.lock()
        values.append(channel)
        let current = values
        var remaining: [(Int, CheckedContinuation<[AppUpdateDiscoveryChannel], Never>)] = []
        var ready: [(Int, CheckedContinuation<[AppUpdateDiscoveryChannel], Never>)] = []
        for waiter in waiters {
            if current.count >= waiter.0 {
                ready.append(waiter)
            } else {
                remaining.append(waiter)
            }
        }
        waiters = remaining
        lock.unlock()
        for waiter in ready {
            waiter.1.resume(returning: current)
        }
    }

    func snapshot() -> [AppUpdateDiscoveryChannel] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }

    func wait(count: Int, timeout: Duration) async -> [AppUpdateDiscoveryChannel] {
        await withTaskGroup(of: [AppUpdateDiscoveryChannel]?.self) { group in
            group.addTask { await self.park(count: count) }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? self.snapshot()
        }
    }

    private func park(count: Int) async -> [AppUpdateDiscoveryChannel] {
        await withCheckedContinuation { continuation in
            lock.lock()
            if values.count >= count {
                let current = values
                lock.unlock()
                continuation.resume(returning: current)
                return
            }
            waiters.append((count, continuation))
            lock.unlock()
        }
    }
}

private final class DiscoveryGate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if opened {
                lock.unlock()
                continuation.resume()
                return
            }
            waiters.append(continuation)
            lock.unlock()
        }
    }

    func open() {
        lock.lock()
        opened = true
        let pending = waiters
        waiters = []
        lock.unlock()
        for waiter in pending { waiter.resume() }
    }
}
