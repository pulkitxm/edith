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

    @Test func commandDigitsSelectByIndex() {
        #expect(resolve("1") == .select(0))
        #expect(resolve("8") == .select(7))
        #expect(resolve("9") == .selectLast)
    }

    @Test func commandZeroResetsZoomRatherThanSelecting() {
        #expect(resolve("0") == .zoomReset)
    }

    @Test func zoomKeysCoverShiftedPlus() {
        #expect(resolve("=") == .zoomIn)
        #expect(resolve("+", 0, [.command, .shift]) == .zoomIn)
        #expect(resolve("-") == .zoomOut)
    }

    @Test func controlTabCycles() {
        #expect(
            resolve(nil, WindowKeyCommand.tabKeyCode, .control) == .cycleForward)
        #expect(
            resolve(nil, WindowKeyCommand.tabKeyCode, [.control, .shift]) == .cycleBackward)
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
