import AppKit
import Carbon.HIToolbox
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

    @Test @MainActor func mouseButtonsReachAChildThatEnablesMouseReporting() async throws {
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-ghostty-buttons-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: output) }
        let command =
            "stty raw -echo; printf '\\033[?1003h\\033[?1006h'; cat > '\(output.path)'"
        let launch = GhosttyLaunch(
            executable: "/bin/sh", arguments: ["-c", command],
            environment: ProcessInfo.processInfo.environment.map { "\($0.key)=\($0.value)" })
        let view = GhosttyTerminalView(launch: launch)
        view.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        let window = NSWindow(
            contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
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

        func event(_ type: NSEvent.EventType, number: Int) throws -> NSEvent {
            try #require(
                NSEvent.mouseEvent(
                    with: type, location: NSPoint(x: 80, y: 500), modifierFlags: [],
                    timestamp: Double(number), windowNumber: window.windowNumber, context: nil,
                    eventNumber: number, clickCount: 1, pressure: 0))
        }

        view.mouseMoved(with: try event(.mouseMoved, number: 1))
        view.mouseDown(with: try event(.leftMouseDown, number: 2))
        view.mouseUp(with: try event(.leftMouseUp, number: 3))
        view.rightMouseDown(with: try event(.rightMouseDown, number: 4))
        view.rightMouseUp(with: try event(.rightMouseUp, number: 5))

        var reports: [String] = []
        for _ in 0..<100 {
            if let data = try? Data(contentsOf: output) {
                reports = String(decoding: data, as: UTF8.self)
                    .split(separator: "\u{1B}").map(String.init)
                if reports.count >= 5 { break }
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(reports.contains { $0.hasPrefix("[<35;") && $0.hasSuffix("M") })
        #expect(reports.contains { $0.hasPrefix("[<0;") && $0.hasSuffix("M") })
        #expect(reports.contains { $0.hasPrefix("[<0;") && $0.hasSuffix("m") })
        #expect(reports.contains { $0.hasPrefix("[<2;") && $0.hasSuffix("M") })
        #expect(reports.contains { $0.hasPrefix("[<2;") && $0.hasSuffix("m") })
    }

    @Test @MainActor func scrollWheelReachesAChildThatEnablesMouseReporting() async throws {
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-ghostty-scroll-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: output) }
        let command =
            "stty raw -echo; printf '\\033[?1003h\\033[?1006h'; cat > '\(output.path)'"
        let launch = GhosttyLaunch(
            executable: "/bin/sh", arguments: ["-c", command],
            environment: ProcessInfo.processInfo.environment.map { "\($0.key)=\($0.value)" })
        let view = GhosttyTerminalView(launch: launch)
        view.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        let window = NSWindow(
            contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
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
        let position = try #require(
            NSEvent.mouseEvent(
                with: .mouseMoved, location: NSPoint(x: 80, y: 500), modifierFlags: [],
                timestamp: 1, windowNumber: window.windowNumber, context: nil, eventNumber: 1,
                clickCount: 0, pressure: 0))
        view.mouseMoved(with: position)
        let cgEvent = try #require(
            CGEvent(
                scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 40,
                wheel2: 0, wheel3: 0))
        cgEvent.location = CGPoint(x: 80, y: 500)
        view.scrollWheel(with: try #require(NSEvent(cgEvent: cgEvent)))

        var reports: [String] = []
        for _ in 0..<100 {
            if let data = try? Data(contentsOf: output) {
                reports = String(decoding: data, as: UTF8.self)
                    .split(separator: "\u{1B}").map(String.init)
                if reports.contains(where: { $0.hasPrefix("[<64;") || $0.hasPrefix("[<65;") }) {
                    break
                }
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(reports.contains { $0.hasPrefix("[<64;") || $0.hasPrefix("[<65;") })
    }

    @Test @MainActor func commandHoverAndClickOwnALinkInsideAMouseReportingTUI() async throws {
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-ghostty-command-link-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: output) }
        let url = "https://example.com/agent/docs"
        let command =
            "printf '\n\n\n\n\n\(url)\r\n'; stty raw -echo; dd bs=1 count=1 2>/dev/null; printf '\\033[?1003h\\033[?1006h'; cat > '\(output.path)'"
        let launch = GhosttyLaunch(
            executable: "/bin/sh", arguments: ["-c", command],
            environment: ProcessInfo.processInfo.environment.map { "\($0.key)=\($0.value)" })
        let theme = GhosttyTheme(
            background: "#111111", foreground: "#eeeeee", cursor: "#eeeeee", fontSize: 13)
        let view = GhosttyTerminalView(launch: launch, theme: theme)
        view.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        let window = NSWindow(
            contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        defer {
            window.contentView = nil
            view.shutdown()
        }

        let surface = try #require(view.surface)

        var discoveredLinkPoint: NSPoint?
        for _ in 0..<20 where discoveredLinkPoint == nil {
            for y in stride(from: 590, through: 350, by: -6) where discoveredLinkPoint == nil {
                for x in stride(from: 6, through: 500, by: 6) {
                    let point = NSPoint(x: x, y: y)
                    let move = try #require(
                        NSEvent.mouseEvent(
                            with: .mouseMoved, location: point, modifierFlags: [], timestamp: 1,
                            windowNumber: window.windowNumber, context: nil, eventNumber: 1,
                            clickCount: 0, pressure: 0))
                    view.mouseMoved(with: move)
                    if view.terminalTargetAtPointer()?.contains(url) == true {
                        discoveredLinkPoint = point
                        break
                    }
                }
            }
            if discoveredLinkPoint == nil { try await Task.sleep(for: .milliseconds(10)) }
        }
        let linkPoint = try #require(discoveredLinkPoint)
        view.insertText("x")
        for _ in 0..<100 {
            if ghostty_surface_mouse_captured(surface) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(ghostty_surface_mouse_captured(surface))
        let commandFlags = NSEvent.ModifierFlags(
            rawValue: NSEvent.ModifierFlags.command.rawValue | UInt(NX_DEVICELCMDKEYMASK))
        let commandDown = try #require(
            NSEvent.keyEvent(
                with: .flagsChanged, location: linkPoint, modifierFlags: commandFlags,
                timestamp: 2, windowNumber: window.windowNumber, context: nil, characters: "",
                charactersIgnoringModifiers: "", isARepeat: false, keyCode: 55))

        view.applyModifierChange(commandDown, mouseOverSurface: true)

        #expect(view.hoveredLink == url)
        #expect(view.terminalCursor == .pointingHand)
        var opened: [URL] = []
        view.openResolvedURL = { opened.append($0) }
        let mouseDown = try #require(
            NSEvent.mouseEvent(
                with: .leftMouseDown, location: linkPoint, modifierFlags: commandFlags,
                timestamp: 3, windowNumber: window.windowNumber, context: nil, eventNumber: 2,
                clickCount: 1, pressure: 0))
        let mouseUp = try #require(
            NSEvent.mouseEvent(
                with: .leftMouseUp, location: linkPoint, modifierFlags: commandFlags,
                timestamp: 4, windowNumber: window.windowNumber, context: nil, eventNumber: 3,
                clickCount: 1, pressure: 0))
        view.mouseDown(with: mouseDown)
        view.mouseUp(with: mouseUp)
        try await Task.sleep(for: .milliseconds(150))

        #expect(opened.map(\.absoluteString) == [url])
        #expect((try? Data(contentsOf: output))?.isEmpty == true)
        let commandUp = try #require(
            NSEvent.keyEvent(
                with: .flagsChanged, location: linkPoint, modifierFlags: [], timestamp: 5,
                windowNumber: window.windowNumber, context: nil, characters: "",
                charactersIgnoringModifiers: "", isARepeat: false, keyCode: 55))
        view.applyModifierChange(commandUp, mouseOverSurface: true)
        #expect(view.hoveredLink == nil)
        try await Task.sleep(for: .milliseconds(150))
        #expect((try? Data(contentsOf: output))?.isEmpty == true)
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

    @Test func copyShortcutOnlyBelongsToTheTerminalWhenTextIsSelected() {
        #expect(!GhosttyTerminalView.shouldHandleCopyShortcut(hasSelection: false))
        #expect(GhosttyTerminalView.shouldHandleCopyShortcut(hasSelection: true))
    }

    @Test func shortSearchesDebounceWhileEmptyAndLongQueriesApplyImmediately() {
        #expect(!TerminalSearchBar.shouldDebounce(""))
        #expect(TerminalSearchBar.shouldDebounce("a"))
        #expect(TerminalSearchBar.shouldDebounce("ab"))
        #expect(!TerminalSearchBar.shouldDebounce("abc"))
    }

    @Test func modifierTransitionsSendPressAndRelease() throws {
        let pressed = try #require(
            NSEvent.keyEvent(
                with: .flagsChanged, location: .zero,
                modifierFlags: NSEvent.ModifierFlags(
                    rawValue: NSEvent.ModifierFlags.command.rawValue
                        | UInt(NX_DEVICELCMDKEYMASK)), timestamp: 1,
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

    @Test func releasingOneCommandKeyDoesNotRepeatItWhileTheOtherStaysHeld() throws {
        let rightDown = NSEvent.ModifierFlags(
            rawValue: NSEvent.ModifierFlags.command.rawValue | UInt(NX_DEVICERCMDKEYMASK))
        let event = try #require(
            NSEvent.keyEvent(
                with: .flagsChanged, location: .zero, modifierFlags: rightDown, timestamp: 1,
                windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                isARepeat: false, keyCode: 55))

        #expect(GhosttyTerminalView.modifierAction(for: event) == GHOSTTY_ACTION_RELEASE)
        #expect(
            GhosttyTerminalView.mods(from: rightDown).rawValue
                & GHOSTTY_MODS_SUPER_RIGHT.rawValue != 0)
    }

    @Test func commandKeyReleaseMonitorOnlyOwnsTheFocusedSurfaceWindow() {
        #expect(
            GhosttyTerminalView.shouldHandleLocalKeyUp(
                flags: .command, matchesWindow: true, focused: true))
        #expect(
            !GhosttyTerminalView.shouldHandleLocalKeyUp(
                flags: [], matchesWindow: true, focused: true))
        #expect(
            !GhosttyTerminalView.shouldHandleLocalKeyUp(
                flags: .command, matchesWindow: false, focused: true))
        #expect(
            !GhosttyTerminalView.shouldHandleLocalKeyUp(
                flags: .command, matchesWindow: true, focused: false))
    }

    @Test func visibleUnfocusedSurfaceReceivesWindowModifierChanges() {
        #expect(
            GhosttyTerminalView.shouldForwardLocalModifier(
                matchesWindow: true, focused: false))
        #expect(
            !GhosttyTerminalView.shouldForwardLocalModifier(
                matchesWindow: true, focused: true))
        #expect(
            GhosttyTerminalView.shouldForwardLocalModifier(
                matchesWindow: false, focused: false))
        #expect(
            GhosttyTerminalView.shouldForwardLocalModifier(
                matchesWindow: false, focused: true))
    }

    @Test func capturedLinkStateRefreshesWhileCommandRemainsActive() {
        #expect(
            GhosttyTerminalView.shouldRefreshCapturedLink(
                commandActive: true, mouseCaptured: true))
        #expect(
            !GhosttyTerminalView.shouldRefreshCapturedLink(
                commandActive: false, mouseCaptured: true))
        #expect(
            !GhosttyTerminalView.shouldRefreshCapturedLink(
                commandActive: true, mouseCaptured: false))
    }

    @Test func commandEscapesMouseCaptureOnlyForPointerEvents() {
        let captured = GhosttyTerminalView.pointerFlags(.command, mouseCaptured: true)
        let uncaptured = GhosttyTerminalView.pointerFlags(.command, mouseCaptured: false)
        let plainCaptured = GhosttyTerminalView.pointerFlags([], mouseCaptured: true)
        let capturedTUIInput = GhosttyTerminalView.pointerFlags(
            .command, mouseCaptured: true, escapeCapture: false)

        #expect(captured.contains(.command))
        #expect(captured.contains(.shift))
        #expect(uncaptured == .command)
        #expect(plainCaptured.isEmpty)
        #expect(capturedTUIInput == .command)
    }

    @Test func onlyASingleLeftCommandClickEscapesMouseCapture() {
        #expect(
            GhosttyTerminalView.shouldEscapeCapture(
                button: GHOSTTY_MOUSE_LEFT, clickCount: 1, flags: .command))
        #expect(
            !GhosttyTerminalView.shouldEscapeCapture(
                button: GHOSTTY_MOUSE_LEFT, clickCount: 2, flags: .command))
        #expect(
            !GhosttyTerminalView.shouldEscapeCapture(
                button: GHOSTTY_MOUSE_RIGHT, clickCount: 1, flags: .command))
        #expect(
            !GhosttyTerminalView.shouldEscapeCapture(
                button: GHOSTTY_MOUSE_LEFT, clickCount: 1, flags: []))
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

    @Test func remoteSessionsNeverResolvePathsAgainstTheLocalMac() {
        #expect(
            GhosttyTerminalView.linkTarget(
                for: "/tmp/remote.log", workingDirectory: "/tmp",
                allowsLocalFiles: false, fileExists: { _ in true }) == nil)
        #expect(
            GhosttyTerminalView.linkTarget(
                for: "file:///tmp/remote.log", workingDirectory: "/tmp",
                allowsLocalFiles: false, fileExists: { _ in true }) == nil)
        #expect(
            GhosttyTerminalView.linkTarget(
                for: "https://example.com", workingDirectory: "/tmp",
                allowsLocalFiles: false, fileExists: { _ in true })?.host == "example.com")
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

    @Test func commandClickOpensAfterAnOldSelectionAndDoesNotDuplicateCoreOpening() {
        var gesture = TerminalCommandClickGesture()
        gesture.begin(active: true, at: .zero, candidate: "https://example.com")

        #expect(
            gesture.finish(active: true, opened: false, candidate: nil)
                == "https://example.com")

        gesture.begin(active: true, at: .zero, candidate: "https://example.com")
        #expect(gesture.finish(active: true, opened: true, candidate: nil) == nil)
    }

    @Test func commandClickDragAndMissingModifierDoNotOpen() {
        var gesture = TerminalCommandClickGesture()
        gesture.begin(active: true, at: .zero, candidate: "https://example.com")
        gesture.move(to: NSPoint(x: 4, y: 0))
        #expect(gesture.finish(active: true, opened: false, candidate: nil) == nil)

        gesture.begin(active: true, at: .zero, candidate: "https://example.com")
        #expect(gesture.finish(active: false, opened: false, candidate: nil) == nil)
    }

    @Test @MainActor func unfocusedCommandLinkClickSurvivesTheFocusMonitor() throws {
        let view = GhosttyTerminalView(
            launch: GhosttyLaunch(executable: "/bin/cat", arguments: [], environment: []))
        view.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        let window = NSWindow(
            contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        view.setHoveredLink("https://example.com")
        _ = window.makeFirstResponder(nil)
        defer {
            window.contentView = nil
            view.shutdown()
        }
        let event = try #require(
            NSEvent.mouseEvent(
                with: .leftMouseDown, location: NSPoint(x: 80, y: 500),
                modifierFlags: .command, timestamp: 1, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 0))

        let forwarded = view.handleLocalLeftMouseDown(event)

        #expect(forwarded === event)
        #expect(window.firstResponder === view)
        #expect(!view.suppressNextLeftMouseUp)
    }
}
