import AppKit
import GhosttyKit
@testable import GhosttyTerminal
import Testing

@Suite struct GhosttyInputTests {
    @Test func appKitFunctionKeyTextIsNotSentToTheTerminal() throws {
        let event = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [.function], timestamp: 1,
                windowNumber: 0, context: nil, characters: "\u{F700}",
                charactersIgnoringModifiers: "\u{F700}", isARepeat: false, keyCode: 126))
        #expect(GhosttyTerminalView.inputText(for: event) == nil)
    }

    @Test func printableTextStillPassesThrough() throws {
        let event = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 1,
                windowNumber: 0, context: nil, characters: "x",
                charactersIgnoringModifiers: "x", isARepeat: false, keyCode: 7))
        #expect(GhosttyTerminalView.inputText(for: event) == "x")
    }

    @Test func modifierTransitionsSendPressAndRelease() throws {
        let pressed = try #require(
            NSEvent.keyEvent(
                with: .flagsChanged, location: .zero, modifierFlags: [.command], timestamp: 1,
                windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                isARepeat: false, keyCode: 55))
        let released = try #require(
            NSEvent.keyEvent(
                with: .flagsChanged, location: .zero, modifierFlags: [], timestamp: 2,
                windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                isARepeat: false, keyCode: 55))

        #expect(GhosttyTerminalView.modifierAction(for: pressed) == GHOSTTY_ACTION_PRESS)
        #expect(GhosttyTerminalView.modifierAction(for: released) == GHOSTTY_ACTION_RELEASE)
    }

    @Test func webAndLocalhostLinksResolveWithoutFilesystemAccess() {
        #expect(
            GhosttyTerminalView.linkTarget(
                for: "https://example.com/docs", workingDirectory: nil,
                fileExists: { _ in false })?.absoluteString == "https://example.com/docs")
        #expect(
            GhosttyTerminalView.linkTarget(
                for: "localhost:3000/dashboard", workingDirectory: nil,
                fileExists: { _ in false })?.absoluteString == "http://localhost:3000/dashboard")
    }

    @Test func relativePathsResolveAgainstTheReportedTerminalDirectory() {
        let target = GhosttyTerminalView.linkTarget(
            for: "Sources/App.swift:42:7", workingDirectory: "/tmp/project",
            fileExists: { $0 == "/tmp/project/Sources/App.swift" })

        #expect(target?.path == "/tmp/project/Sources/App.swift")
    }

    @Test func unsafeInlineSchemesDoNotOpen() {
        #expect(
            GhosttyTerminalView.linkTarget(
                for: "javascript:alert(1)", workingDirectory: nil,
                fileExists: { _ in false }) == nil)
        #expect(
            GhosttyTerminalView.linkTarget(
                for: "data:text/plain,secret", workingDirectory: nil,
                fileExists: { _ in false }) == nil)
    }
}
