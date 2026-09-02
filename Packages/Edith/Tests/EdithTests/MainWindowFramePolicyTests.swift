import AppKit
import Testing
@testable import Edith

@Suite struct MainWindowFramePolicyTests {
    private let display = NSRect(x: 0, y: 40, width: 1440, height: 860)

    @Test func defaultWindowUsesTheAvailableDisplay() {
        let size = MainWindowFramePolicy.defaultSize(visibleFrame: display)
        #expect(size.width == 1180.8)
        #expect(abs(size.height - 670.8) < 0.001)
    }

    @Test func undersizedRestoredWindowUsesTheDefaultAndCenters() {
        let frame = NSRect(x: 12, y: 50, width: 720, height: 500)
        let normalized = MainWindowFramePolicy.normalizedFrame(frame, visibleFrame: display)

        #expect(normalized.size == MainWindowFramePolicy.defaultSize(visibleFrame: display))
        #expect(normalized.midX == display.midX)
        #expect(normalized.midY == display.midY)
    }

    @Test func validWindowKeepsItsSizeAndMovesFullyOnScreen() {
        let frame = NSRect(x: 1200, y: 700, width: 1000, height: 700)
        let normalized = MainWindowFramePolicy.normalizedFrame(frame, visibleFrame: display)

        #expect(normalized.size == frame.size)
        #expect(display.contains(normalized))
    }

    @Test func compactDisplaysBoundTheMinimumToTheVisibleArea() {
        let compactDisplay = NSRect(x: 0, y: 0, width: 800, height: 560)
        let minimum = MainWindowFramePolicy.minimumSize(visibleFrame: compactDisplay)

        #expect(minimum.width == 800)
        #expect(minimum.height == 560)
    }

    @Test func tiledAutosaveIsDiscardedBeforeRestoration() {
        let value =
            "0 0 1728 1084 0 0 1728 1084 {\"tilingState\":{\"tilingPosition\":9}}"

        #expect(MainWindowFramePolicy.shouldDiscardAutosave(value))
    }

    @Test func ordinaryAutosaveKeepsUserPositionAndSize() {
        let value = "251 159 1180 700 0 0 1728 1084"

        #expect(!MainWindowFramePolicy.shouldDiscardAutosave(value))
        #expect(
            MainWindowFramePolicy.autosaveKey(name: "EdithMainWindow")
                == "NSWindow Frame EdithMainWindow")
    }

    @Test @MainActor func explicitFrameAutosaveOwnsMainWindowRestoration() {
        let window = TestWindowHost.window(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
            styleMask: [.titled, .resizable])

        MainWindowFramePolicy.disableApplicationStateRestoration(window)

        #expect(!window.isRestorable)
    }
}
