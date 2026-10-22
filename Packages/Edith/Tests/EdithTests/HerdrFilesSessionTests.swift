import EdithKit
import Foundation
import Testing

@testable import Edith

@MainActor
@Suite struct HerdrFilesSessionTests {
    @Test func aLocalAgentBrowsesThisMacFromItsWorkingDirectory() {
        let files = Self.session()
        files.prepare(directory: " /Users/me/project \n", isLocal: true, machine: nil)
        #expect(files.errorMessage == nil)
        #expect(files.finder?.session.id == Machine.localID)
        #expect(files.finder?.session.isLocal == true)
        #expect(files.finder?.path == "/Users/me/project")
    }

    @Test func aRemoteAgentBrowsesItsOwnMachine() {
        let machine = Machine(name: "tuf", host: "tuf.example")
        let files = Self.session()
        files.prepare(directory: "/home/me/repo", isLocal: false, machine: machine)
        #expect(files.finder?.session.id == machine.id)
        #expect(files.finder?.session.isLocal == false)
        #expect(files.finder?.path == "/home/me/repo")
    }

    @Test func anAgentWithoutADirectoryStartsAtHome() {
        let remote = Self.session()
        remote.prepare(
            directory: "  ", isLocal: false, machine: Machine(name: "tuf", host: "tuf.example"))
        #expect(remote.finder?.path == "~")
        let local = Self.session()
        local.prepare(directory: "", isLocal: true, machine: nil)
        #expect(local.finder?.path == FileManager.default.homeDirectoryForCurrentUser.path)
    }

    @Test func aRemoteAgentWhoseMachineIsGoneExplainsWhy() {
        let files = Self.session()
        files.prepare(directory: "/srv", isLocal: false, machine: nil)
        #expect(files.finder == nil)
        #expect(files.errorMessage == HerdrQuinjetError.machineUnavailable.localizedDescription)
    }

    @Test func preparingAgainKeepsTheBrowserAndFollowsANewWorkingDirectory() {
        let machine = Machine(name: "tuf", host: "tuf.example")
        let files = Self.session()
        files.prepare(directory: "/srv/a", isLocal: false, machine: machine)
        let first = files.finder
        files.finder?.navigate(to: "/srv/a/sub")
        files.prepare(directory: "/srv/a", isLocal: false, machine: machine)
        #expect(files.finder === first)
        #expect(files.finder?.path == "/srv/a/sub")
        files.prepare(directory: "/srv/b", isLocal: false, machine: machine)
        #expect(files.finder === first)
        #expect(files.finder?.path == "/srv/b")
        #expect(files.finder?.canGoBack == true)
    }

    @Test func movingToAnotherMachineStartsAFreshBrowser() {
        let files = Self.session()
        files.prepare(directory: "/srv", isLocal: false, machine: Machine(name: "a", host: "a"))
        let first = files.finder
        let other = Machine(name: "b", host: "b")
        files.prepare(directory: "/srv", isLocal: false, machine: other)
        #expect(files.finder !== first)
        #expect(files.finder?.session.id == other.id)
    }

    @Test func aLocalAgentRevealsAFileInsideItsFolder() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-reveal-\(UUID().uuidString)")
        let sources = root.appendingPathComponent("Sources")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: sources.appendingPathComponent("App.swift"))
        let files = Self.session()

        let entry = try #require(
            await files.locate(
                sources.appendingPathComponent("App.swift").path, directory: root.path,
                isLocal: true, machine: nil))
        #expect(files.finder?.path == root.path)
        await files.reveal(entry)

        #expect(files.finder?.path == sources.path)
        #expect(files.finder?.selection == [entry.path])
        #expect(files.finder?.scrollTarget == entry.path)
        #expect(
            await files.locate(
                sources.appendingPathComponent("Missing.swift").path, directory: root.path,
                isLocal: true, machine: nil) == nil)
        files.stop()
    }

    @Test func aRemoteFileIsFoundThroughItsMachineListing() async throws {
        let machine = Machine(name: "tuf", host: "tuf.example")
        var listed: [String] = []
        let finder = FinderModel(
            session: MachineSession(machine: machine, local: false, observesWakeRequests: false),
            path: "/srv/repo",
            directoryLoader: { path in
                listed.append(path)
                guard path == "/srv/repo/src" else { return .success([]) }
                return .success([
                    RemoteFileEntry(
                        name: "main.rs", path: "/srv/repo/src/main.rs", kind: .file, sizeBytes: 1)
                ])
            }, freeSpaceLoader: { _ in nil })

        #expect(await finder.locate("/srv/repo/src/other.rs") == nil)
        let entry = try #require(await finder.locate("/srv/repo/src/main.rs"))
        #expect(finder.path == "/srv/repo")
        await finder.reveal(entry: entry)

        #expect(finder.path == "/srv/repo/src")
        #expect(finder.selection == ["/srv/repo/src/main.rs"])
        #expect(finder.scrollTarget == "/srv/repo/src/main.rs")
        #expect(listed == ["/srv/repo/src", "/srv/repo/src", "/srv/repo/src"])
        finder.stopLoading()
    }

    private static func session() -> HerdrFilesSession {
        HerdrFilesSession { id in
            MachineSession(
                machine: id == Machine.localID ? .local : Machine.missing(id: id),
                local: id == Machine.localID, observesWakeRequests: false)
        }
    }
}
