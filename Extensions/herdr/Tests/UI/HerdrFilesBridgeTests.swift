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

    @Test func fileWindowsUseHostAdmissionWithoutDetachingTheAgent() async throws {
        let store = HerdrStore(defaults: HerdrUIDefaults(), machinesProvider: { [] })
        let windows = HerdrSpaceSessions(store: store)
        let location = HerdrFilesWindowLocation(machine: .local, path: "/tmp/synthetic folder")
        let target = try location.encoded()
        #expect(try location.encoded() == target)
        let descriptor = try windows.present(["kind": "files", "id": target])
        #expect(descriptor.location == "herdr.files")
        #expect(descriptor.target == target)
        #expect(!descriptor.presented)
        #expect(store.sessions.isEmpty && store.detachedIDs.isEmpty)
        try windows.admit(descriptor.token)
        #expect(try windows.present(["kind": "files", "id": target]).presented)
        #expect(windows.presentations.count == 1)
        try await windows.closeAndWait(descriptor.token)
        #expect(windows.presentations.isEmpty)
    }

    @Test func fileWindowsRejectUnknownMachinesAndMalformedPaths() throws {
        let windows = HerdrSpaceSessions(
            store: HerdrStore(defaults: HerdrUIDefaults(), machinesProvider: { [] }))
        let unknown = Machine(name: "Synthetic", host: "synthetic.invalid")
        let target = try HerdrFilesWindowLocation(machine: unknown, path: "/tmp").encoded()
        #expect(throws: (any Error).self) {
            try windows.present(["kind": "files", "id": target])
        }
        for path in ["", "bad\u{0}path", String(repeating: "x", count: 4097)] {
            #expect(throws: (any Error).self) {
                try HerdrFilesWindowLocation(machine: .local, path: path).encoded()
            }
        }
        #expect(windows.presentations.isEmpty)
    }

    @Test func remoteMachineRecordsReachTheRenderingStoreThroughTheEngine() async throws {
        defer { MachineRegistry.shutdown(); HerdrWorkOwnership.enable() }
        let id = UUID()
        try await MachineRegistry.refresh { _, _, _ in
            try JSONSerialization.data(withJSONObject: [
                "machines": [
                    ["id": id.uuidString, "name": "Synthetic", "sshTarget": "synthetic.invalid"]
                ]
            ])
        }
        let machine = try #require(MachineRegistry.machines().first)
        let defaults = HerdrUIDefaults()
        let worker = HerdrWorker(
            store: HerdrStore(defaults: defaults), defaults: defaults, automaticActions: false)
        let client = HerdrUIClient { try await worker.execute($0, payload: $1) }
        let state = try #require(try client.state(await client.perform("herdr.ui.read")))
        #expect(state.machines == [machine])
        MachineRegistry.shutdown()
        let ui = HerdrStore(uiClient: client)
        ui.adoptUI(state)
        let agent = HerdrAgent.make(
            machineID: id.uuidString, machineName: machine.name, machineIsLocal: false,
            sshTarget: machine.sshTarget, session: "synthetic", pane: "one", kind: "Terminal",
            status: .working, title: "Synthetic", workspace: "Synthetic", cwd: "/srv/synthetic")
        let tab = ui.makeTab(for: agent)
        #expect(tab.machine == machine)
        tab.files.prepare(directory: agent.cwd, isLocal: false, machine: tab.machine)
        #expect(tab.files.finder?.session.id == id)
        tab.files.discard()
        await ui.shutdown()
        await worker.shutdown()
    }
}
