import AppKit
import Foundation
import Testing

@testable import EdithKit

@Suite struct WindowKeyCommandTests {
    private func resolve(
        _ characters: String?, _ keyCode: UInt16 = 0, _ modifiers: NSEvent.ModifierFlags = .command
    ) -> WindowKeyCommand? {
        WindowKeyCommand.resolve(characters: characters, keyCode: keyCode, modifiers: modifiers)
    }

    @Test func optionDigitsSelectByIndex() {
        #expect(resolve("1", 0, .option) == .select(0))
        #expect(resolve("8", 0, .option) == .select(7))
        #expect(resolve("9", 0, .option) == .selectLast)
    }

    @Test func commandDigitsNoLongerSelectSidebarSections() {
        #expect(resolve("1") == nil)
        #expect(resolve("9") == nil)
    }

    @Test func commandZeroResetsZoomRatherThanSelecting() {
        #expect(resolve("0") == .zoomReset)
        #expect(resolve("0", 0, .option) == nil)
    }

    @Test func zoomKeysCoverShiftedPlus() {
        #expect(resolve("=") == .zoomIn)
        #expect(resolve("+", 0, [.command, .shift]) == .zoomIn)
        #expect(resolve("-") == .zoomOut)
    }

    @Test func optionTabCycles() {
        #expect(
            resolve(nil, WindowKeyCommand.tabKeyCode, .option) == .cycleForward)
        #expect(
            resolve(nil, WindowKeyCommand.tabKeyCode, [.option, .shift]) == .cycleBackward)
    }

    @Test func controlTabNoLongerCyclesSidebarSections() {
        #expect(resolve(nil, WindowKeyCommand.tabKeyCode, .control) == nil)
        #expect(resolve(nil, WindowKeyCommand.tabKeyCode, [.control, .shift]) == nil)
    }

    @Test func unmodifiedAndForeignModifierKeysAreIgnored() {
        #expect(resolve("1", 0, []) == nil)
        #expect(resolve("1", 0, [.command, .option]) == nil)
        #expect(resolve("a") == nil)
        #expect(resolve(nil, WindowKeyCommand.tabKeyCode, .command) == nil)
    }

    @Test func indexResolutionWrapsAndClampsToVisibleItems() {
        #expect(WindowKeyCommand.resolvedIndex(for: .select(2), count: 6, current: 0) == 2)
        #expect(WindowKeyCommand.resolvedIndex(for: .select(7), count: 6, current: 0) == nil)
        #expect(WindowKeyCommand.resolvedIndex(for: .selectLast, count: 6, current: 0) == 5)
        #expect(WindowKeyCommand.resolvedIndex(for: .cycleForward, count: 6, current: 5) == 0)
        #expect(WindowKeyCommand.resolvedIndex(for: .cycleBackward, count: 6, current: 0) == 5)
        #expect(WindowKeyCommand.resolvedIndex(for: .cycleForward, count: 0, current: 0) == nil)
    }

    @Test func zoomStaysWithinRange() {
        #expect(WindowZoom.adjusted(1.6, for: .zoomIn) == 1.6)
        #expect(WindowZoom.adjusted(0.8, for: .zoomOut) == 0.8)
        #expect(WindowZoom.adjusted(1.3, for: .zoomReset) == 1)
        #expect(WindowZoom.adjusted(1.0, for: .zoomIn) == 1.1)
        #expect(WindowZoom.adjusted(1.0, for: .select(0)) == nil)
    }
}
