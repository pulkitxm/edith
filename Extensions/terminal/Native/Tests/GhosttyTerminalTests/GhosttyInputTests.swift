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
