import AppKit
import Testing

@testable import Edith
@testable import EdithKit

@MainActor
@Suite struct FinderKeyOwnershipTests {
    init() {
        _ = TestWindowHost.application
    }

    @Test func theFinderOwnsItsKeysLikeATerminal() {
        let view = FinderKeyView()
        #expect(InputFocus.takesKeysDirectly(view))
        #expect(!InputFocus.shouldStartTypeAhead(characters: "r", modifiers: [], responder: view))
    }

    @Test func musicLeavesSpaceAndArrowsToAFocusedFinder() {
        var plays = 0
        let handlers = MusicKeyCommand.Handlers(
            playPause: { plays += 1 }, seekBy: { _ in plays += 1 }, volumeBy: { _ in plays += 1 })
        let finder = FinderKeyView()
        for code: UInt16 in [49, 123, 124, 125, 126] {
            #expect(
                !MusicKeyCommand.handle(
                    keyCode: code, modifiers: [], active: true, responder: finder, handlers))
        }
        #expect(plays == 0)
    }

    @Test func musicLeavesArrowsToListsButStillPlaysOnSpace() {
        var plays = 0
        let handlers = MusicKeyCommand.Handlers(
            playPause: { plays += 1 }, seekBy: { _ in }, volumeBy: { _ in })
        for list in [NSTableView(), NSOutlineView(), NSCollectionView(), NSBrowser()] as [NSView] {
            for code: UInt16 in [123, 124, 125, 126] {
                #expect(
                    !MusicKeyCommand.handle(
                        keyCode: code, modifiers: [], active: true, responder: list, handlers))
            }
            #expect(
                MusicKeyCommand.handle(
                    keyCode: 49, modifiers: [], active: true, responder: list, handlers))
        }
        #expect(plays == 4)
    }

    @Test func musicLeavesEveryKeyToAFocusedControl() {
        let handlers = MusicKeyCommand.Handlers(
            playPause: {}, seekBy: { _ in }, volumeBy: { _ in })
        for control in [NSButton(), NSSlider(), NSSegmentedControl()] as [NSView] {
            for code: UInt16 in [49, 123, 124, 125, 126] {
                #expect(
                    !MusicKeyCommand.handle(
                        keyCode: code, modifiers: [], active: true, responder: control, handlers))
            }
        }
    }

    @Test func musicStillPlaysWhenNothingIsFocused() {
        var plays = 0
        let handlers = MusicKeyCommand.Handlers(
            playPause: { plays += 1 }, seekBy: { _ in }, volumeBy: { _ in })
        #expect(
            MusicKeyCommand.handle(
                keyCode: 49, modifiers: [], active: true, responder: nil, handlers))
        #expect(
            MusicKeyCommand.handle(
                keyCode: 49, modifiers: [], active: true, responder: NSView(), handlers))
        #expect(plays == 2)
    }

    @Test func theFinderTakesFocusOnlyWhenAskedOrWhenNothingElseHasIt() {
        #expect(
            FinderKeyCatcher.claimsFocus(
                requested: true, autoFocus: false, editing: false, focused: false,
                textEditing: false, windowIdle: false))
        #expect(
            !FinderKeyCatcher.claimsFocus(
                requested: false, autoFocus: true, editing: false, focused: false,
                textEditing: false, windowIdle: false))
        #expect(
            FinderKeyCatcher.claimsFocus(
                requested: false, autoFocus: true, editing: false, focused: false,
                textEditing: false, windowIdle: true))
        #expect(
            !FinderKeyCatcher.claimsFocus(
                requested: false, autoFocus: false, editing: false, focused: false,
                textEditing: false, windowIdle: true))
        #expect(
            !FinderKeyCatcher.claimsFocus(
                requested: true, autoFocus: true, editing: true, focused: false,
                textEditing: false, windowIdle: true))
        #expect(
            !FinderKeyCatcher.claimsFocus(
                requested: true, autoFocus: true, editing: false, focused: false,
                textEditing: true, windowIdle: true))
        #expect(
            !FinderKeyCatcher.claimsFocus(
                requested: true, autoFocus: true, editing: false, focused: true,
                textEditing: false, windowIdle: true))
    }

    @Test func commandShortcutsReachTheFinderOnlyWhileItIsFocused() throws {
        let window = TestWindowHost.window(contentRect: NSRect(x: 0, y: 0, width: 200, height: 120))
        let finder = FinderKeyView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        finder.autoFocus = false
        let other = NSTextView(frame: NSRect(x: 20, y: 0, width: 100, height: 40))
        window.contentView?.addSubview(finder)
        window.contentView?.addSubview(other)
        var keys: [FinderKey] = []
        finder.onKey = {
            keys.append($0); return true
        }
        let copy = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "c",
                charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8))

        window.makeFirstResponder(other)
        #expect(!finder.performKeyEquivalent(with: copy))
        #expect(keys.isEmpty)

        window.makeFirstResponder(finder)
        #expect(finder.performKeyEquivalent(with: copy))
        #expect(keys == [.copy])
    }

    @Test func focusingTheFinderTellsItsHost() {
        let window = TestWindowHost.window(contentRect: NSRect(x: 0, y: 0, width: 200, height: 120))
        let finder = FinderKeyView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        finder.autoFocus = false
        window.contentView?.addSubview(finder)
        var focused = 0
        finder.onFocus = { focused += 1 }
        window.makeFirstResponder(finder)
        #expect(focused == 1)
    }

    @Test func historyKeysGoToTheFinderBeforeTheWindow() {
        let finder = FinderKeyView()
        var moves: [NavigationDirection] = []
        var canMove = true
        finder.onHistory = { direction in
            guard canMove else { return false }
            moves.append(direction)
            return true
        }
        let owner = NavigationShortcutGate.historyView(from: finder)
        #expect(owner === finder)
        #expect(owner?.navigateHistory(.back) == true)
        #expect(moves == [.back])
        canMove = false
        #expect(owner?.navigateHistory(.forward) == false)
        #expect(NavigationShortcutGate.historyView(from: NSView()) == nil)
        finder.isEditing = { true }
        canMove = true
        #expect(finder.navigateHistory(.back) == false)
    }
}
