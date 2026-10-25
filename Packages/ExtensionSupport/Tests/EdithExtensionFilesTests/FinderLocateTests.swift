import Foundation
import Testing

@testable import EdithExtensionFiles

@MainActor
@Suite struct FinderLocateTests {
    private func remoteSession() -> DirectFinderSession {
        DirectFinderSession(id: UUID(), name: "tuf", isLocal: false)
    }

    @Test func aRemoteSearchStaysInsideTheAgentFolder() async {
        let tree: [String: [RemoteFileEntry]] = [
            "/srv": [
                RemoteFileEntry(name: "api", path: "/srv/api", kind: .directory, sizeBytes: 0),
                RemoteFileEntry(
                    name: ".cache", path: "/srv/.cache", kind: .directory, sizeBytes: 0),
            ],
            "/srv/api": [
                RemoteFileEntry(name: "src", path: "/srv/api/src", kind: .directory, sizeBytes: 0)
            ],
            "/srv/api/src": [
                RemoteFileEntry(
                    name: "main.rs", path: "/srv/api/src/main.rs", kind: .file, sizeBytes: 1)
            ],
        ]
        var listed: [String] = []
        let finder = FinderModel(
            session: remoteSession(), path: "/srv",
            directoryLoader: { path in
                listed.append(path)
                return .success(tree[path] ?? [])
            }, freeSpaceLoader: { _ in nil })

        #expect(
            await finder.locate("/srv/src/main.rs", under: "/srv")?.path == "/srv/api/src/main.rs")
        #expect(await finder.locate("/srv/src/main.rs") == nil)
        #expect(await finder.locate("/etc/src/main.rs", under: "/srv") == nil)
        #expect(!listed.contains("/srv/.cache"))
        finder.stopLoading()
    }

    @Test func aRemoteFileIsFoundThroughItsMachineListing() async throws {
        var listed: [String] = []
        let finder = FinderModel(
            session: remoteSession(), path: "/srv/repo",
            directoryLoader: { path in
                listed.append(path)
                guard path == "/srv/repo/src" else { return .success([]) }
                return .success([
                    RemoteFileEntry(
                        name: "main.rs", path: "/srv/repo/src/main.rs", kind: .file, sizeBytes: 1)
                ])
            }, freeSpaceLoader: { _ in nil })

        #expect(await finder.locate("/srv/repo/src/other.rs") == nil)
        #expect(await finder.locate("/srv/repo/src/ma\u{2026}")?.path == "/srv/repo/src/main.rs")
        #expect(await finder.locate("/srv/repo/src/zz\u{2026}") == nil)
        let entry = try #require(await finder.locate("/srv/repo/src/main.rs"))
        #expect(finder.path == "/srv/repo")
        await finder.reveal(entry: entry)

        #expect(finder.path == "/srv/repo/src")
        #expect(finder.selection == ["/srv/repo/src/main.rs"])
        #expect(finder.scrollTarget == "/srv/repo/src/main.rs")
        #expect(listed == Array(repeating: "/srv/repo/src", count: 5))
        finder.stopLoading()
    }

    @Test func aHiddenFileIsShownWhenItIsRevealed() async throws {
        let hidden = RemoteFileEntry(
            name: ".env", path: "/srv/repo/.env", kind: .file, sizeBytes: 1)
        let finder = FinderModel(
            session: remoteSession(), path: "/srv/repo",
            directoryLoader: { _ in .success([hidden]) }, freeSpaceLoader: { _ in nil })
        finder.showHidden = false

        await finder.reveal(entry: hidden)

        #expect(finder.showHidden)
        #expect(finder.visibleEntries.map(\.path) == ["/srv/repo/.env"])
        #expect(finder.selection == ["/srv/repo/.env"])
        finder.showHidden = false
        finder.stopLoading()
    }
}
