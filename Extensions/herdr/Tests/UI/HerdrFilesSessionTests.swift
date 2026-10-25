@testable import HerdrUI
import EdithExtensionSupport
import Foundation
import Testing

@MainActor
@Suite struct HerdrFilesSessionTests {
    @Test func aLocalAgentBrowsesThisMacFromItsWorkingDirectory() {
        let files = Self.session()
        files.prepare(directory: " /Users/me/project \n", isLocal: true, machine: nil)
        #expect(files.errorMessage == nil)
        #expect(files.finder?.session.id == Machine.localID)
        #expect(files.finder?.session.isLocal == true)
        #expect(files.finder?.path == "/Users/me/project")
        files.discard()
    }

    @Test func aRemoteAgentBrowsesItsOwnMachine() {
        let machine = Machine(name: "tuf", host: "tuf.example")
        let files = Self.session()
        files.prepare(directory: "/home/me/repo", isLocal: false, machine: machine)
        #expect(files.finder?.session.id == machine.id)
        #expect(files.finder?.session.isLocal == false)
        #expect(files.finder?.path == "/home/me/repo")
        files.discard()
    }

    @Test func anAgentWithoutADirectoryStartsAtHome() {
        let remote = Self.session()
        remote.prepare(
            directory: "  ", isLocal: false, machine: Machine(name: "tuf", host: "tuf.example"))
        #expect(remote.finder?.path == "~")
        let local = Self.session()
        local.prepare(directory: "", isLocal: true, machine: nil)
        #expect(local.finder?.path == FileManager.default.homeDirectoryForCurrentUser.path)
        remote.discard()
        local.discard()
    }

    @Test func aRemoteAgentWhoseMachineIsGoneExplainsWhy() {
        let files = Self.session()
        files.prepare(directory: "/srv", isLocal: false, machine: nil)
        #expect(files.finder == nil)
        #expect(files.errorMessage == HerdrQuinjetError.machineUnavailable.localizedDescription)
    }

    @Test func preparingAgainKeepsTheFinderAndFollowsANewWorkingDirectory() {
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
        files.discard()
    }

    @Test func movingToAnotherMachineStartsAFreshFinder() {
        let files = Self.session()
        files.prepare(directory: "/srv", isLocal: false, machine: Machine(name: "a", host: "a"))
        let first = files.finder
        let other = Machine(name: "b", host: "b")
        files.prepare(directory: "/srv", isLocal: false, machine: other)
        #expect(files.finder !== first)
        #expect(files.finder?.session.id == other.id)
        files.discard()
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
        files.discard()
    }

    @Test func aPathPrintedFromARepoInsideTheAgentFolderIsFoundThere() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-search-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let relative = "Packages/Kit/Services/Collector.swift"
        for (repo, age) in [("old-tree", 3_600.0), ("new-tree", 0), ("node_modules/x", -60)] {
            let file = root.appendingPathComponent("\(repo)/\(relative)")
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: file)
            try FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: file.path)
        }
        let files = Self.session()

        let entry = try #require(
            await files.locate(
                root.appendingPathComponent(relative).path, directory: root.path + "/",
                isLocal: true, machine: nil))
        #expect(entry.path == root.appendingPathComponent("new-tree/\(relative)").path)
        #expect(
            await files.locate(
                root.appendingPathComponent("Packages/Kit/Missing.swift").path,
                directory: root.path, isLocal: true, machine: nil) == nil)
        files.discard()
    }

    private static func session() -> HerdrFilesSession {
        HerdrFilesSession { HerdrStore.directFilesSession(for: $0) }
    }
}
