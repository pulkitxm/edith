import SwiftUI
import Testing

@testable import EdithHelper

@Suite struct ClipboardPaletteKeymapTests {
    private func command(
        _ key: KeyEquivalent, _ modifiers: EventModifiers = [], queryIsEmpty: Bool = true
    ) -> ClipboardPaletteCommand? {
        ClipboardPaletteKeymap.command(key: key, modifiers: modifiers, queryIsEmpty: queryIsEmpty)
    }

    @Test func arrowsNavigateRowsAndCategories() {
        #expect(command(.upArrow) == .move(-1))
        #expect(command(.downArrow) == .move(1))
        #expect(command(.leftArrow) == .cycleCategory(-1))
        #expect(command(.rightArrow) == .cycleCategory(1))
        #expect(command(.rightArrow, queryIsEmpty: false) == .cycleCategory(1))
    }

    @Test func commandArrowsJumpToTheEnds() {
        #expect(command(.upArrow, .command) == .jump(top: true))
        #expect(command(.downArrow, .command) == .jump(top: false))
    }

    @Test func arrowKeysIgnoreTheFunctionAndKeypadFlagsMacOSAddsToThem() {
        #expect(command(.downArrow, [.numericPad, .function]) == .move(1))
        #expect(command(.leftArrow, [.numericPad, .function, .capsLock]) == .cycleCategory(-1))
        #expect(command(.upArrow, [.command, .numericPad]) == .jump(top: true))
    }

    @Test func modifiedHorizontalArrowsStayWithTheSearchField() {
        #expect(command(.leftArrow, .option) == nil)
        #expect(command(.rightArrow, .command) == nil)
        #expect(command(.leftArrow, .shift) == nil)
        #expect(command(.upArrow, .shift) == nil)
    }

    @Test func returnPastesAndOptionReturnPastesPlainText() {
        #expect(command(.return) == .paste(plainText: false))
        #expect(command(.return, .option) == .paste(plainText: true))
        #expect(command(.return, .command) == nil)
    }

    @Test func escapeClearsTheSearchBeforeClosing() {
        #expect(command(.escape, queryIsEmpty: false) == .clearSearch)
        #expect(command(.escape) == .dismiss)
    }

    @Test func backspaceDeletesTheClipOnlyWhenThereIsNothingToErase() {
        #expect(command(.delete) == .delete)
        #expect(command(.deleteForward) == .delete)
        #expect(command(.delete, queryIsEmpty: false) == nil)
        #expect(command(.delete, .option, queryIsEmpty: false) == nil)
        #expect(command(.delete, .command, queryIsEmpty: false) == .delete)
        #expect(command(.delete, [.command, .option]) == .clearUnpinned)
        #expect(command(.delete, [.command, .option], queryIsEmpty: false) == .clearUnpinned)
    }

    @Test(arguments: 1...9)
    func commandDigitsQuickPaste(digit: Int) {
        let key = KeyEquivalent(Character(String(digit)))

        #expect(command(key, .command) == .quickPaste(digit, plainText: false))
        #expect(command(key, [.command, .option]) == .quickPaste(digit, plainText: true))
        #expect(command(key) == nil)
        #expect(command(key, [.command, .shift]) == nil)
    }

    @Test func zeroIsNotAQuickPick() {
        #expect(command("0", .command) == nil)
    }

    @Test func commandPPinsAndCommandCommaOpensSettings() {
        #expect(command("p", .command) == .togglePin)
        #expect(command("P", .command) == .togglePin)
        #expect(command(",", .command) == .preferences)
        #expect(command("p", [.command, .option]) == nil)
        #expect(command("p", [.command, .control]) == nil)
        #expect(command("p") == nil)
    }

    @Test func plainTypingIsLeftToTheSearchField() {
        for character in ["a", "z", "1", " ", "#", "/"] {
            #expect(command(KeyEquivalent(Character(character))) == nil)
        }
        #expect(command("a", .command) == nil)
        #expect(command(.tab) == nil)
    }
}
