import Darwin
import Foundation
import Testing

@testable import Edith
@testable import EdithKit

@Suite @MainActor struct FinderEntryProjectionTests {
    @Test func smallListingsKeepFolderOrderingAndUpdateOnlyWhenInputsChange() async {
        let model = FinderModel(session: MachineSession(machine: .local, local: true))
        model.entries = [
            entry("z.txt", size: 1), entry("folder", directory: true), entry("a.txt", size: 2),
        ]
        #expect(
            model.visibleEntries
                == FileSorting.sort(
                    model.entries, by: model.sortKey, ascending: model.sortAscending))
        let before = model.visibleEntries
        model.statusMessage = "Background transfer updated"
        model.selection = ["/fixture/a.txt"]
        #expect(model.visibleEntries == before)
        model.searchResults = [entry("search-result")]
        #expect(model.visibleEntries.map(\.name) == ["search-result"])
        model.searchResults = nil
        #expect(model.visibleEntries == before)
    }

    @Test func largeProjectionRunsOffMainAndCancellationCannotPublishStaleRows() async throws {
        let state = ProjectionWorkerState()
        let projection = FinderEntryProjection { _, _, _ in
            state.start(onMain: Thread.isMainThread)
            let deadline = ContinuousClock.now + .seconds(3)
            while !Task.isCancelled, ContinuousClock.now < deadline {
                Thread.sleep(forTimeInterval: 0.001)
            }
            state.finish(cancelled: Task.isCancelled)
            try Task.checkCancellation()
            return []
        }
        let rows = (0..<100_001).map { entry("item \($0)") }
        projection.update(
            entries: rows, searchResults: nil, showHidden: true, key: .name, ascending: true)
        #expect(projection.isUpdating)
        for _ in 0..<200 {
            if state.started { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(state.started)
        #expect(!state.onMain)
        projection.update(
            entries: [entry("latest")], searchResults: nil, showHidden: true, key: .name,
            ascending: true)
        for _ in 0..<200 {
            if state.cancelled { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(state.cancelled)
        #expect(projection.entries.map(\.name) == ["latest"])
        #expect(!projection.isUpdating)
    }

    @Test func largeSearchChangesPublishOnlyTheLatestQuery() async throws {
        let model = FinderModel(
            session: MachineSession(machine: .local, local: true),
            localSearch: { _, _ in [] })
        model.entries = (0..<100_001).map { entry("item \($0)") }
        model.searchQuery = "item"
        model.searchQueryChanged()
        model.searchQuery = "item 100000"
        await model.runSearch()
        #expect(model.visibleEntries.map(\.name) == ["item 100000"])
        model.stopLoading()
    }

    @Test func realDirectoryRepeatedViewReadsUseTheCachedProjection() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-finder-benchmark-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<5_000 {
            let name = String(format: "file %05d.txt", 4_999 - index)
            let file = root.appendingPathComponent(name)
            let descriptor = open(file.path, O_CREAT | O_WRONLY | O_EXCL, 0o600)
            guard descriptor >= 0 else { throw POSIXError(.EIO) }
            close(descriptor)
        }
        let listed = MachineSession.listLocalFiles(path: root.path)
        #expect(listed.count == 5_000)
        let model = FinderModel(
            session: MachineSession(machine: .local, local: true), path: root.path)
        model.entries = listed
        await model.waitForEntryProjection()
        let expected = FileSorting.sort(listed, by: model.sortKey, ascending: model.sortAscending)
        #expect(model.visibleEntries == expected)
        let reads = 20
        var baselineCount = 0
        let baselineStart = ContinuousClock.now
        for _ in 0..<reads {
            let visible = model.showHidden ? listed : listed.filter { !$0.isHidden }
            baselineCount +=
                FileSorting.sort(visible, by: model.sortKey, ascending: model.sortAscending).count
        }
        let baseline = milliseconds(baselineStart.duration(to: .now))
        var cachedCount = 0
        let cachedStart = ContinuousClock.now
        for index in 0..<reads {
            model.statusMessage = "Transfer progress \(index)"
            cachedCount += model.visibleEntries.count
        }
        let cached = milliseconds(cachedStart.duration(to: .now))
        #expect(baselineCount == cachedCount)
        #expect(cached < baseline)
        let result: [String: Double] = [
            "files": Double(listed.count), "viewReads": Double(reads),
            "baselineMilliseconds": baseline, "cachedMilliseconds": cached,
            "speedup": baseline / max(cached, 0.000_001),
        ]
        let data = try JSONSerialization.data(
            withJSONObject: result, options: [.sortedKeys, .prettyPrinted])
        try data.write(
            to: URL(fileURLWithPath: "/tmp/edith-finder-projection-benchmark.json"),
            options: .atomic)
        print(
            "Finder directory benchmark: \(listed.count) actual files, \(reads) view reads, baseline \(baseline) ms, cached \(cached) ms"
        )
        model.stopLoading()
    }

    private func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds)
            / 1_000_000_000_000_000
    }

    private func entry(_ name: String, directory: Bool = false, size: Int64 = 0) -> RemoteFileEntry
    {
        RemoteFileEntry(
            name: name, path: "/fixture/\(name)", kind: directory ? .directory : .file,
            sizeBytes: size)
    }
}

private final class ProjectionWorkerState: @unchecked Sendable {
    private let lock = NSLock()
    private var didStart = false
    private var mainThread = false
    private var didCancel = false
    var started: Bool { lock.withLock { didStart } }
    var onMain: Bool { lock.withLock { mainThread } }
    var cancelled: Bool { lock.withLock { didCancel } }
    func start(onMain: Bool) {
        lock.withLock {
            didStart = true; mainThread = onMain
        }
    }
    func finish(cancelled: Bool) { lock.withLock { didCancel = cancelled } }
}
