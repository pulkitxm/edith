@testable import EdithExtensionFiles
@testable import HerdrUI
import EdithExtensionSupport
import Foundation
import Testing

@MainActor
@Suite(.serialized) struct HerdrFilesBridgeTests {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-files-bridge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("docs"), withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: root.appendingPathComponent("note.txt"))
        try Data("world".utf8).write(to: root.appendingPathComponent(".hidden"))
        return root
    }

    private func bridge(_ host: HerdrFilesHost) -> HerdrFilesBridge {
        HerdrFilesBridge(
            client: HerdrUIClient { operation, payload in
                try await host.execute(operation, payload: payload)
            }, presentationID: UUID())
    }

    @Test func theFilesPaneListsAndChangesFoldersThroughTheEngine() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let host = HerdrFilesHost()
        let session = DirectFinderSession(
            id: Machine.localID, name: "This Mac", isLocal: true,
            remoteClient: bridge(host))
        let finder = FinderModel(session: session, path: root.path)

        finder.showHidden = false
        await finder.load()
        #expect(finder.entries.map(\.name).sorted() == [".hidden", "docs", "note.txt"])
        #expect(finder.visibleEntries.map(\.name).contains("note.txt"))
        #expect(!finder.visibleEntries.map(\.name).contains(".hidden"))

        finder.selection = [root.appendingPathComponent("note.txt").path]
        await finder.duplicateSelection()
        #expect(finder.entries.map(\.name).contains("note copy.txt"))

        await finder.newFolder()
        #expect(finder.entries.contains { $0.isDirectory && $0.name.hasPrefix("untitled") })

        finder.releaseRemote()
        await host.shutdown()
    }

    @Test func aTerminalPathIsLocatedAndRevealedThroughTheEngine() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let inner = root.appendingPathComponent("docs/inner.txt")
        try Data("x".utf8).write(to: inner)
        let host = HerdrFilesHost()
        let transport = bridge(host)
        let files = HerdrFilesSession { machine in
            DirectFinderSession(
                id: machine.id, name: machine.name, isLocal: true, remoteClient: transport)
        }

        let entry = try #require(
            await files.locate(
                inner.path, directory: root.path, isLocal: true, machine: nil))
        await files.reveal(entry)

        #expect(files.finder?.path == root.appendingPathComponent("docs").path)
        #expect(files.finder?.selection == [inner.path])
        files.discard()
        await host.shutdown()
    }

    @Test func aProxySessionRunsCommandsAndListsFoldersOnTheEngine() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let host = HerdrFilesHost()
        let session = DirectFinderSession(
            id: Machine.localID, name: "This Mac", isLocal: true, remoteClient: bridge(host))

        #expect(try await session.runCommand("printf hello", timeout: 10).get() == "hello")
        #expect(
            try await session.listFiles(path: root.path).get().map(\.name).sorted()
                == [".hidden", "docs", "note.txt"])
        #expect(
            try await session.homeDirectory().get()
                == FileManager.default.homeDirectoryForCurrentUser.path)
        let created = root.appendingPathComponent("made").path
        #expect(try await session.createDirectory(path: created).get().path == created)
        #expect(FileManager.default.fileExists(atPath: created))
        await host.shutdown()
    }

    @Test func theEngineRejectsMachinesItDoesNotKnow() async throws {
        let host = HerdrFilesHost(machines: { [] })
        let request = MachineFileRequest(
            viewID: UUID(), machineID: UUID(), operation: .load, path: "/")
        await #expect(throws: (any Error).self) {
            _ = try await host.execute("herdr.ui.files", payload: JSONEncoder().encode(request))
        }
        await host.shutdown()
    }

    @Test func aStoppedEngineRefusesFurtherWork() async throws {
        let host = HerdrFilesHost()
        await host.shutdown()
        let request = MachineFileRequest(
            viewID: UUID(), machineID: Machine.localID, operation: .load, path: "/")
        await #expect(throws: (any Error).self) {
            _ = try await host.execute("herdr.ui.files", payload: JSONEncoder().encode(request))
        }
    }
}
