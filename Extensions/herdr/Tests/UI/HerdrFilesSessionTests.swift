@testable import HerdrUI
import EdithExtensionSupport
import Foundation
import Testing

@MainActor
private final class ListingLog {
    var paths: [String] = []
}

@MainActor
@Suite struct HerdrFilesSessionTests {
    @Test func aLocalAgentBrowsesThisMacFromItsWorkingDirectory() {
        let files = Self.session()
        files.prepare(directory: " /Users/me/project \n", isLocal: true, machine: nil)
        #expect(files.errorMessage == nil)
        #expect(files.browser?.machine.id == Machine.localID)
        #expect(files.browser?.isLocal == true)
        #expect(files.browser?.path == "/Users/me/project")
        files.stop()
    }

    @Test func aRemoteAgentBrowsesItsOwnMachine() {
        let machine = Machine(name: "tuf", host: "tuf.example")
        let files = Self.session()
        files.prepare(directory: "/home/me/repo", isLocal: false, machine: machine)
        #expect(files.browser?.machine.id == machine.id)
        #expect(files.browser?.isLocal == false)
        #expect(files.browser?.path == "/home/me/repo")
        files.stop()
    }

    @Test func anAgentWithoutADirectoryStartsAtHome() {
        let remote = Self.session()
        remote.prepare(
            directory: "  ", isLocal: false, machine: Machine(name: "tuf", host: "tuf.example"))
        #expect(remote.browser?.path == "~")
        let local = Self.session()
        local.prepare(directory: "", isLocal: true, machine: nil)
        #expect(local.browser?.path == FileManager.default.homeDirectoryForCurrentUser.path)
    }

    @Test func aRemoteAgentWhoseMachineIsGoneExplainsWhy() {
        let files = Self.session()
        files.prepare(directory: "/srv", isLocal: false, machine: nil)
        #expect(files.browser == nil)
        #expect(files.errorMessage == HerdrQuinjetError.machineUnavailable.localizedDescription)
    }

    @Test func preparingAgainKeepsTheBrowserAndFollowsANewWorkingDirectory() {
        let machine = Machine(name: "tuf", host: "tuf.example")
        let files = Self.session()
        files.prepare(directory: "/srv/a", isLocal: false, machine: machine)
        let first = files.browser
        files.browser?.navigate(to: "/srv/a/sub")
        files.prepare(directory: "/srv/a", isLocal: false, machine: machine)
        #expect(files.browser === first)
        #expect(files.browser?.path == "/srv/a/sub")
        files.prepare(directory: "/srv/b", isLocal: false, machine: machine)
        #expect(files.browser === first)
        #expect(files.browser?.path == "/srv/b")
        #expect(files.browser?.canGoBack == true)
        files.stop()
    }

    @Test func movingToAnotherMachineStartsAFreshBrowser() {
        let files = Self.session()
        files.prepare(directory: "/srv", isLocal: false, machine: Machine(name: "a", host: "a"))
        let first = files.browser
        let other = Machine(name: "b", host: "b")
        files.prepare(directory: "/srv", isLocal: false, machine: other)
        #expect(files.browser !== first)
        #expect(files.browser?.machine.id == other.id)
        files.stop()
    }

    @Test func aLocalAgentRevealsAFileInsideItsFolder() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-reveal-\(UUID().uuidString)")
        let sources = root.appendingPathComponent("Sources")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: sources.appendingPathComponent("App.swift"))
        let files = HerdrFilesSession { .direct(on: $0) }

        let entry = try #require(
            await files.locate(
                sources.appendingPathComponent("App.swift").path, directory: root.path,
                isLocal: true, machine: nil))
        #expect(files.browser?.path == root.path)
        await files.reveal(entry)

        #expect(files.browser?.path == sources.path)
        #expect(files.browser?.selection == [entry.path])
        #expect(files.browser?.scrollTarget == entry.path)
        #expect(
            await files.locate(
                sources.appendingPathComponent("Missing.swift").path, directory: root.path,
                isLocal: true, machine: nil) == nil)
        files.stop()
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
        let files = HerdrFilesSession { .direct(on: $0) }

        let entry = try #require(
            await files.locate(
                root.appendingPathComponent(relative).path, directory: root.path + "/",
                isLocal: true, machine: nil))
        #expect(entry.path == root.appendingPathComponent("new-tree/\(relative)").path)
        #expect(
            await files.locate(
                root.appendingPathComponent("Packages/Kit/Missing.swift").path,
                directory: root.path, isLocal: true, machine: nil) == nil)
        files.stop()
    }

    @Test func aRemoteSearchStaysInsideTheAgentFolder() async {
        let machine = Machine(name: "tuf", host: "tuf.example")
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
        let log = ListingLog()
        let files = Self.session(tree: tree, log: log)
        files.prepare(directory: "/srv", isLocal: false, machine: machine)
        let browser = files.browser

        #expect(
            await browser?.locate("/srv/src/main.rs", under: "/srv")?.path
                == "/srv/api/src/main.rs")
        #expect(await browser?.locate("/srv/src/main.rs") == nil)
        #expect(await browser?.locate("/etc/src/main.rs", under: "/srv") == nil)
        #expect(!log.paths.contains("/srv/.cache"))
        files.stop()
    }

    @Test func aRemoteFileIsFoundThroughItsMachineListing() async throws {
        let machine = Machine(name: "tuf", host: "tuf.example")
        let tree: [String: [RemoteFileEntry]] = [
            "/srv/repo/src": [
                RemoteFileEntry(
                    name: "main.rs", path: "/srv/repo/src/main.rs", kind: .file, sizeBytes: 1)
            ]
        ]
        let files = Self.session(tree: tree)
        files.prepare(directory: "/srv/repo", isLocal: false, machine: machine)
        let browser = try #require(files.browser)

        #expect(await browser.locate("/srv/repo/src/other.rs") == nil)
        #expect(await browser.locate("/srv/repo/src/ma…")?.path == "/srv/repo/src/main.rs")
        #expect(await browser.locate("/srv/repo/src/zz…") == nil)
        let entry = try #require(await browser.locate("/srv/repo/src/main.rs"))
        #expect(browser.path == "/srv/repo")
        await browser.reveal(entry: entry)

        #expect(browser.path == "/srv/repo/src")
        #expect(browser.selection == ["/srv/repo/src/main.rs"])
        #expect(browser.scrollTarget == "/srv/repo/src/main.rs")
        files.stop()
    }

    @Test func aHiddenFileIsShownWhenItIsRevealed() async throws {
        let machine = Machine(name: "tuf", host: "tuf.example")
        let hidden = RemoteFileEntry(
            name: ".env", path: "/srv/repo/.env", kind: .file, sizeBytes: 1)
        let files = Self.session(tree: ["/srv/repo": [hidden]])
        files.prepare(directory: "/srv/repo", isLocal: false, machine: machine)
        let browser = try #require(files.browser)

        #expect(!browser.showHidden)
        await browser.reveal(entry: hidden)

        #expect(browser.showHidden)
        #expect(browser.visibleEntries.map(\.path) == ["/srv/repo/.env"])
        #expect(browser.selection == ["/srv/repo/.env"])
        files.stop()
    }

    private static func session(
        tree: [String: [RemoteFileEntry]] = [:], log: ListingLog? = nil
    ) -> HerdrFilesSession {
        HerdrFilesSession { _ in
            HerdrFilesSource(
                home: { "/home/me" },
                list: { path in
                    log?.paths.append(path)
                    return tree[path] ?? []
                })
        }
    }
}
