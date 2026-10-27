import Foundation
import Testing

@testable import EdithExtensionFiles

@MainActor
@Suite struct LocalFileListingTests {
    @Test func listingRunsOffTheMainThreadSoAStalledDirectoryCannotFreezeTheApp() async {
        let entry = RemoteFileEntry(name: "a", path: "/tmp/a", kind: .file, sizeBytes: 1)
        let onMain = LockedFlag()
        let result = await LocalFileListing.entriesOffMain(path: "/tmp") { _ in
            onMain.set(Thread.isMainThread)
            return [entry]
        }
        #expect(result == [entry])
        #expect(onMain.value == false)
    }

    @Test func aLocalFinderSessionNeverListsFoldersOnTheMainThread() async throws {
        let onMain = LockedFlag()
        let session = DirectFinderSession(
            id: UUID(), name: "local", isLocal: true,
            localListing: { _ in
                onMain.set(Thread.isMainThread)
                return []
            })
        _ = try await session.listFiles(path: "/tmp").get()
        #expect(onMain.value == false)
    }

    @Test func aLocalSessionListsRealFoldersThroughTheOffMainPath() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("x".utf8).write(to: root.appendingPathComponent("note.txt"))
        let session = DirectFinderSession(id: UUID(), name: "local", isLocal: true)
        let listing = try await session.listFiles(path: root.path).get()
        #expect(listing.map(\.name) == ["note.txt"])
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag: Bool?
    var value: Bool? { lock.withLock { flag } }
    func set(_ newValue: Bool) { lock.withLock { flag = newValue } }
}
