import AppKit
import Carbon.HIToolbox
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

    @Test func controlTextReturnsToTheActiveKeyboardLayout() throws {
        let event = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: .control, timestamp: 1,
                windowNumber: 0, context: nil, characters: "\u{1}",
                charactersIgnoringModifiers: "a", isARepeat: false,
                keyCode: UInt16(kVK_ANSI_A)))
        let expected = event.characters(byApplyingModifiers: [])

        #expect(GhosttyTerminalView.inputText(for: event) == expected)
        #expect(
            GhosttyTerminalView.inputText(for: event).map {
                !GhosttyTerminalView.startsWithASCIIControl($0)
            } == true)
    }

    @Test func shiftedKeysReportTheirNoModifierCodepoint() throws {
        let event = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: .shift, timestamp: 1,
                windowNumber: 0, context: nil, characters: "!",
                charactersIgnoringModifiers: "!", isARepeat: false,
                keyCode: UInt16(kVK_ANSI_1)))
        let expected = try #require(
            event.characters(byApplyingModifiers: [])?.unicodeScalars.first?.value)

        #expect(GhosttyTerminalView.unshiftedCodepoint(for: event) == expected)
        #expect(GhosttyTerminalView.unshiftedCodepoint(for: event) != 33)
    }

    @Test func optionAsAltFilteringPreservesDeviceAndInputSourceFlags() {
        let original = NSEvent.ModifierFlags(
            rawValue: NSEvent.ModifierFlags.option.rawValue
                | NSEvent.ModifierFlags.function.rawValue
                | NSEvent.ModifierFlags.numericPad.rawValue
                | UInt(NX_DEVICERALTKEYMASK))
        let translated = GhosttyTerminalView.translationFlags(
            original: original, mods: GHOSTTY_MODS_NONE)

        #expect(!translated.contains(.option))
        #expect(translated.contains(.function))
        #expect(translated.contains(.numericPad))
        #expect(translated.rawValue & UInt(NX_DEVICERALTKEYMASK) != 0)
    }

    @Test func unchangedTranslationModifiersReuseTheNativeEvent() throws {
        let event = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: .option, timestamp: 1,
                windowNumber: 0, context: nil, characters: "´",
                charactersIgnoringModifiers: "e", isARepeat: false,
                keyCode: UInt16(kVK_ANSI_E)))

        #expect(
            GhosttyTerminalView.translationEvent(for: event, mods: GHOSTTY_MODS_ALT)
                === event)
    }

    @Test func filteredTranslationModifiersRebuildTheNativeTextEvent() throws {
        let event = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: .option, timestamp: 1,
                windowNumber: 0, context: nil, characters: "´",
                charactersIgnoringModifiers: "e", isARepeat: false,
                keyCode: UInt16(kVK_ANSI_E)))
        let expected = event.characters(byApplyingModifiers: []) ?? ""
        let translated = GhosttyTerminalView.translationEvent(
            for: event, mods: GHOSTTY_MODS_NONE)

        #expect(translated !== event)
        #expect(!translated.modifierFlags.contains(.option))
        #expect(translated.characters == expected)
        #expect(translated.keyCode == event.keyCode)
    }

    @Test func keyEventsSeparatePhysicalAndConsumedModifiers() throws {
        let original = NSEvent.ModifierFlags(
            rawValue: NSEvent.ModifierFlags.shift.rawValue
                | NSEvent.ModifierFlags.control.rawValue
                | NSEvent.ModifierFlags.option.rawValue
                | NSEvent.ModifierFlags.command.rawValue
                | UInt(NX_DEVICERALTKEYMASK))
        let event = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: original, timestamp: 1,
                windowNumber: 0, context: nil, characters: "A",
                charactersIgnoringModifiers: "a", isARepeat: false,
                keyCode: UInt16(kVK_ANSI_A)))
        let key = GhosttyTerminalView.keyEvent(
            for: event, translationFlags: [.shift, .option], action: GHOSTTY_ACTION_PRESS,
            composing: true)

        #expect(key.keycode == UInt32(kVK_ANSI_A))
        #expect(key.mods.rawValue & GHOSTTY_MODS_SHIFT.rawValue != 0)
        #expect(key.mods.rawValue & GHOSTTY_MODS_CTRL.rawValue != 0)
        #expect(key.mods.rawValue & GHOSTTY_MODS_ALT.rawValue != 0)
        #expect(key.mods.rawValue & GHOSTTY_MODS_SUPER.rawValue != 0)
        #expect(key.consumed_mods.rawValue & GHOSTTY_MODS_SHIFT.rawValue != 0)
        #expect(key.consumed_mods.rawValue & GHOSTTY_MODS_ALT.rawValue != 0)
        #expect(key.consumed_mods.rawValue & GHOSTTY_MODS_CTRL.rawValue == 0)
        #expect(key.consumed_mods.rawValue & GHOSTTY_MODS_SUPER.rawValue == 0)
        #expect(key.composing)
    }

    @Test func ASCIIControlTextStaysWithTheGhosttyKeyEncoder() {
        #expect(GhosttyTerminalView.startsWithASCIIControl("\r"))
        #expect(GhosttyTerminalView.startsWithASCIIControl("\u{7F}"))
        #expect(!GhosttyTerminalView.startsWithASCIIControl("文"))
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

    @Test func agentSessionsHoldACapturedClickUntilItBecomesADrag() {
        #expect(
            GhosttyTerminalView.capturedPointerDelivery(
                shift: false, commandClick: false, clickCount: 1, dragSelects: true) == .heldClick)
        #expect(
            GhosttyTerminalView.capturedPointerDelivery(
                shift: true, commandClick: false, clickCount: 1, dragSelects: true) == .selection)
        #expect(
            GhosttyTerminalView.capturedPointerDelivery(
                shift: false, commandClick: true, clickCount: 1, dragSelects: true) == .selection)
        #expect(
            GhosttyTerminalView.capturedPointerDelivery(
                shift: false, commandClick: false, clickCount: 2, dragSelects: true) == .selection)
        #expect(
            GhosttyTerminalView.capturedPointerDelivery(
                shift: false, commandClick: false, clickCount: 1, dragSelects: false) == .program)
        #expect(
            GhosttyTerminalView.capturedPointerDelivery(
                shift: false, commandClick: false, clickCount: 2, dragSelects: false) == .program)
    }

    @Test(arguments: [false, true]) @MainActor
    func agentDragSelectsWhileAClickStillReachesTheProgram(focusClick: Bool) async throws {
        _ = TestWindowHost.application
        let board = NSPasteboard.general
        let previous = (board.types ?? []).compactMap { type in
            board.data(forType: type).map { (type, $0) }
        }
        defer {
            board.declareTypes(previous.map(\.0), owner: nil)
            for (type, data) in previous { board.setData(data, forType: type) }
        }
        var writes = Data()
        let io = GhosttyExternalIO(
            write: { writes.append($0) }, resize: { _, _, _, _ in }, failure: {})
        let view = GhosttyTerminalView(
            externalIO: io,
            theme: GhosttyTheme(
                background: "#111111", foreground: "#eeeeee", cursor: "#eeeeee", fontSize: 13))
        view.dragSelectsOverCapturedMouse = true
        view.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        let window = TestWindowHost.window(contentRect: view.frame)
        window.contentView = view
        defer {
            window.contentView = nil
            view.shutdown()
        }
        let surface = try #require(view.surface)
        let output = Data(
            "\u{1b}[2J\u{1b}[3J\u{1b}[Halpha beta gamma\u{1b}[?1002h\u{1b}[?1006h".utf8)
        #expect(view.receiveOutput(output))
        for _ in 0..<100 {
            if ghostty_surface_mouse_captured(surface) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(ghostty_surface_mouse_captured(surface))
        let size = ghostty_surface_size(surface)
        let cellWidth = CGFloat(size.cell_width_px) / window.backingScaleFactor
        let cellHeight = CGFloat(size.cell_height_px) / window.backingScaleFactor
        let start = NSPoint(x: 6 + cellWidth * 0.1, y: 600 - 4 - cellHeight * 0.5)
        let end = NSPoint(x: start.x + cellWidth * 5, y: start.y)
        func event(
            _ type: NSEvent.EventType, at point: NSPoint, number: Int
        ) throws -> NSEvent {
            try #require(
                NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [],
                    timestamp: Double(number), windowNumber: window.windowNumber, context: nil,
                    eventNumber: number, clickCount: 1, pressure: 0))
        }
        board.clearContents()
        board.setString("previous clipboard", forType: .string)
        let down = try event(.leftMouseDown, at: start, number: 1)
        if focusClick {
            view.suppressNextLeftMouseUp = true
            view.focusMouseDown = down
        } else {
            view.mouseDown(with: down)
            #expect(view.heldCapturedClick != nil)
            #expect(!view.programOwnsMouseGesture)
        }
        view.mouseDragged(with: try event(.leftMouseDragged, at: end, number: 2))
        #expect(view.heldCapturedClick == nil)
        #expect(view.selectionMouseReportingSuspended)
        #expect(!view.programOwnsMouseGesture)
        view.mouseUp(with: try event(.leftMouseUp, at: end, number: 3))
        #expect(view.selectedText() == "alpha")
        #expect(board.string(forType: .string) == "alpha")
        #expect(!view.selectionMouseReportingSuspended)
        #expect(!writes.contains(0x1B))

        view.mouseDown(with: try event(.leftMouseDown, at: end, number: 4))
        #expect(view.heldCapturedClick != nil)
        view.mouseUp(with: try event(.leftMouseUp, at: end, number: 5))
        #expect(view.heldCapturedClick == nil)
        #expect(board.string(forType: .string) == "alpha")
        var reports = ""
        for _ in 0..<200 {
            reports = String(decoding: writes, as: UTF8.self)
            if reports.contains("[<0;") && reports.contains("m") { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(reports.contains("[<0;"))
        #expect(reports.contains("M"))
        #expect(reports.contains("m"))
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

}
