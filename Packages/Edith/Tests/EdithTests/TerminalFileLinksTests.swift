import AppKit
import Foundation
@testable import GhosttyTerminal
import Testing

@Suite struct TerminalFileLinksTests {
    @Test func aLocalAgentResolvesExistingFilesAgainstItsFolder() {
        let file = "/Users/me/repo/Sources/App.swift"
        let links = TerminalFileLinks(
            directory: "/Users/me/repo", fileExists: { $0 == file }, reveal: { _ in })

        #expect(links.path(for: "Sources/App.swift:42:7") == file)
        #expect(links.path(for: "./Sources/App.swift") == file)
        #expect(links.path(for: "'Sources/App.swift',") == file)
        #expect(links.path(for: "(`Sources/App.swift:12`).") == file)
        #expect(links.path(for: file) == file)
        #expect(links.path(for: "file://\(file)") == file)
        #expect(links.path(for: "Sources/Missing.swift") == nil)
    }

    @Test func aLocalAgentExpandsHomeOnThisMac() {
        let notes = NSString(string: "~/notes.md").expandingTildeInPath
        let links = TerminalFileLinks(
            directory: "/tmp", fileExists: { $0 == notes }, reveal: { _ in })

        #expect(links.path(for: "~/notes.md") == notes)
    }

    @Test func aRemoteAgentAcceptsPathShapedTextWithoutTouchingThisMac() {
        let links = TerminalFileLinks(directory: "/home/me/repo", fileExists: nil, reveal: { _ in })

        #expect(links.path(for: "Sources/App.swift:42") == "/home/me/repo/Sources/App.swift")
        #expect(links.path(for: "README.md") == "/home/me/repo/README.md")
        #expect(links.path(for: "../other/main.c") == "/home/me/other/main.c")
        #expect(links.path(for: "/etc/hosts") == "/etc/hosts")
        #expect(links.path(for: "~/notes.txt") == "~/notes.txt")
    }

    @Test(arguments: [
        "hello", "https://example.com/a.txt", "localhost:3000", "...", "/", "~", "two words.txt",
        "v1.",
    ])
    func aRemoteAgentIgnoresTextThatIsNotAPath(_ text: String) {
        let links = TerminalFileLinks(directory: "/home/me/repo", fileExists: nil, reveal: { _ in })

        #expect(links.path(for: text) == nil)
    }

    @Test func relativePathsNeedAnAbsoluteAgentFolder() {
        let links = TerminalFileLinks(directory: "", fileExists: nil, reveal: { _ in })

        #expect(links.path(for: "Sources/App.swift") == nil)
        #expect(links.path(for: "/srv/App.swift") == "/srv/App.swift")
    }

    @Test @MainActor func commandClickedPathsRevealWhileWebLinksStillOpen() async throws {
        let view = GhosttyTerminalView(
            launch: GhosttyLaunch(executable: "/bin/cat", arguments: [], environment: []))
        var revealed: [String] = []
        var opened: [URL] = []
        view.openResolvedURL = { opened.append($0) }
        view.fileLinks = TerminalFileLinks(
            directory: "/srv/repo", fileExists: nil, reveal: { revealed.append($0) })

        #expect(view.resolvedTarget(for: "src/main.rs:10")?.openTitle == "Show in Files")
        #expect(view.openTerminalTarget("src/main.rs:10"))
        #expect(view.openTerminalTarget("https://example.com"))
        #expect(!view.openTerminalTarget("plain"))
        try await Task.sleep(for: .milliseconds(100))

        #expect(revealed == ["/srv/repo/src/main.rs"])
        #expect(opened.map(\.absoluteString) == ["https://example.com"])
    }

    @Test @MainActor func terminalsWithoutFileLinksKeepOpeningLocalFiles() async throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-link-\(UUID().uuidString).txt")
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let view = GhosttyTerminalView(
            launch: GhosttyLaunch(executable: "/bin/cat", arguments: [], environment: []))
        var opened: [URL] = []
        view.openResolvedURL = { opened.append($0) }

        #expect(view.resolvedTarget(for: file.path)?.openTitle == "Open Link")
        #expect(view.openTerminalTarget(file.path))
        try await Task.sleep(for: .milliseconds(100))

        #expect(opened.map(\.path) == [file.standardizedFileURL.path])
    }
}
