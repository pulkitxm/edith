import Foundation
@testable import GhosttyTerminal
import Testing

@Suite struct GhosttyURLSecurityTests {
    @Test func trustedWebAndMailLinksOpenWithoutPrompting() {
        #expect(
            TerminalUntrustedURL(value: "https://example.com/docs").decision
                == .allow(URL(string: "https://example.com/docs")!))
        #expect(
            TerminalUntrustedURL(value: "mailto:team@example.com").decision
                == .allow(URL(string: "mailto:team@example.com")!))
    }

    @Test func customSchemesRequireConfirmation() {
        #expect(
            TerminalUntrustedURL(value: "editor://open/project").decision
                == .confirm(URL(string: "editor://open/project")!))
    }

    @Test func deceptiveAndIncompleteTargetsAreBlocked() {
        #expect(
            TerminalUntrustedURL(value: "https:relative").decision == .deny(.invalidWebURL))
        #expect(
            TerminalUntrustedURL(value: "https://example.com\u{202E}safe").decision
                == .deny(.unsafeCharacters))
        #expect(TerminalUntrustedURL(value: "relative/path").decision == .deny(.malformed))
    }

    @Test func safeLocalFilesOpenAndExecutableTargetsAreBlocked() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-terminal-url-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let text = directory.appendingPathComponent("notes.txt")
        let script = directory.appendingPathComponent("launch.command")
        try Data("notes".utf8).write(to: text)
        try Data("echo unsafe".utf8).write(to: script)

        #expect(TerminalUntrustedURL(value: text.absoluteString).decision == .allow(text))
        #expect(TerminalUntrustedURL(value: script.absoluteString).decision == .deny(.unsafeFile))
        #expect(
            TerminalUntrustedURL(value: "file://remote.example/tmp/notes.txt").decision
                == .deny(.malformed))
    }

    @Test func blockedTargetDisplayMakesInvisibleCharactersVisible() {
        let target = TerminalUntrustedURL(value: "https://example.com/a\u{200B}b")
        #expect(target.displayValue == "https://example.com/a\\u{200B}b")
    }

    @Test func remoteSessionsBlockFileURLsBeforeInspectingTheLocalFileSystem() {
        let target = TerminalUntrustedURL(
            value: "file:///tmp/remote.log", allowsLocalFiles: false)

        #expect(target.decision == .deny(.remoteSessionFile))
    }
}
