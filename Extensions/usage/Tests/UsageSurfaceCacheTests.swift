import EdithExtensionSupport
import Foundation
import Testing
@testable import UsageExtension

@Suite struct UsageSurfaceCacheTests {
    @Test func sameTimestampReplacementIsReadByItsNewFileIdentity() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("usage.json")
        let date = Date(timeIntervalSince1970: 123_456)
        try Data(#"{"daily":[],"sourceMeta":{"one":{"label":"First"}}}"#.utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        let store = SurfaceUsageStore(url: url)
        #expect(try await store.sources().map(\.title) == ["First"])
        try Data(#"{"daily":[],"sourceMeta":{"two":{"label":"Other"}}}"#.utf8).write(
            to: url, options: .atomic)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        #expect(try await store.sources().map(\.title) == ["Other"])
    }

    @Test func nonRegularFilesAndOversizedCachesAreRejectedBeforeReading() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("target.json")
        try Data(#"{"daily":[]}"#.utf8).write(to: target)
        let link = root.appendingPathComponent("symlink.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        await #expect(throws: CocoaError.self) {
            _ = try await SurfaceUsageStore(url: link).snapshot(tile: .init(.usage))
        }
        await #expect(throws: CocoaError.self) {
            _ = try await SurfaceUsageStore(url: root).snapshot(tile: .init(.usage))
        }
        let handle = try FileHandle(forWritingTo: target)
        try handle.truncate(atOffset: 67_108_865); try handle.close()
        await #expect(throws: CocoaError.self) {
            _ = try await SurfaceUsageStore(url: target).snapshot(tile: .init(.usage))
        }
    }

    @Test func sourceLabelsRespectWireBytesAndChoicesStayBounded() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("usage.json")
        let sources = Dictionary(
            uniqueKeysWithValues: (0..<120).map {
                (String($0), ["label": String(repeating: "🌍", count: 300)])
            })
        let data = try JSONSerialization.data(withJSONObject: ["daily": [], "sourceMeta": sources])
        try data.write(to: url)
        let choices = try await SurfaceUsageStore(url: url).sources()
        #expect(choices.count == 100)
        #expect(choices.allSatisfy { $0.title.utf8.count <= 1024 })
        _ = try SurfaceSnapshot(providerID: "usage", sources: choices).encoded()
    }

    @Test func cancellationNeverStartsAnUnneededRead() async throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await SurfaceUsageStore(url: missing).sources()
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }
}
