import Foundation
import Testing
@testable import StudioExtension

private final class StudioWatchCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

@Suite struct StudioSupportLifecycleTests {
    @Test func stoppedWatcherHasNoQueuedOrFutureCallbacks() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "studio-watch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let counter = StudioWatchCounter()
        let watcher = FileSystemWatcher(
            paths: [directory], debounce: 0.05, eventLatency: 0.05,
            handler: { counter.increment() })
        #expect(!watcher.isWatching)
        watcher.start()
        try #require(watcher.isWatching)
        defer { watcher.stop() }
        try Data("first".utf8).write(to: directory.appendingPathComponent("first.txt"))
        for _ in 0..<150 where counter.value == 0 {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(counter.value > 0)
        try Data("queued".utf8).write(to: directory.appendingPathComponent("queued.txt"))
        watcher.stop()
        #expect(!watcher.isWatching)
        let stopped = counter.value
        try Data("after stop".utf8).write(to: directory.appendingPathComponent("stopped.txt"))
        try await Task.sleep(for: .milliseconds(500))
        #expect(counter.value == stopped)
        watcher.start()
        try #require(watcher.isWatching)
        try Data("restart".utf8).write(to: directory.appendingPathComponent("restart.txt"))
        for _ in 0..<150 where counter.value == stopped {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(counter.value > stopped)
    }

    @Test func finderScriptCancellationStopsAnActiveProcess() async throws {
        let task = Task { await StudioFinderReveal.runScript("delay 30", timeout: 20) }
        try await Task.sleep(for: .milliseconds(100))
        let started = ContinuousClock.now
        task.cancel()
        #expect(await task.value == false)
        #expect(started.duration(to: .now) < .seconds(3))
    }
}
