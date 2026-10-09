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
