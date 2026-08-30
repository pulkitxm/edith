import AppKit
import GhosttyKit
@testable import GhosttyTerminal
import Testing

@Suite struct GhosttyInputTests {
    @Test @MainActor func mouseMotionReachesAChildThatEnablesAnyEventReporting() async throws {
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-ghostty-mouse-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: output) }
        let command =
            "stty raw -echo; printf '\\033[?1003h\\033[?1006h'; dd bs=1 count=1 of='\(output.path)' 2>/dev/null"
        let launch = GhosttyLaunch(
            executable: "/bin/sh", arguments: ["-c", command],
            environment: ProcessInfo.processInfo.environment.map { "\($0.key)=\($0.value)" })
        let view = GhosttyTerminalView(launch: launch)
        view.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        let window = NSWindow(
            contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        #expect(window.acceptsMouseMovedEvents)
        defer {
            window.contentView = nil
            view.shutdown()
        }

        for _ in 0..<100 {
            if let surface = view.surface, ghostty_surface_mouse_captured(surface) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let surface = try #require(view.surface)
        #expect(ghostty_surface_mouse_captured(surface))
        let event = try #require(
            NSEvent.mouseEvent(
                with: .mouseMoved, location: NSPoint(x: 40, y: 500), modifierFlags: [],
                timestamp: 1, windowNumber: window.windowNumber, context: nil, eventNumber: 1,
                clickCount: 0, pressure: 0))

        view.mouseMoved(with: event)

        for _ in 0..<100 {
            if let data = try? Data(contentsOf: output), data.count == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let bytes = try Data(contentsOf: output)
        #expect(bytes == Data([0x1B]))
    }

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

    @Test func inputMethodCompositionSuppressesControlEventsOnly() {
        #expect(GhosttyTerminalView.suppresses("\r", whileComposing: true))
        #expect(GhosttyTerminalView.suppresses("\u{1B}", whileComposing: true))
        #expect(!GhosttyTerminalView.suppresses("文", whileComposing: true))
        #expect(!GhosttyTerminalView.suppresses("\r", whileComposing: false))
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
