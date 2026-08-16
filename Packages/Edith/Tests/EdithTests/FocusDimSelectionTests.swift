import CoreGraphics
import Testing

@testable import EdithKit

@Suite struct FocusDimSelectionTests {
    private let screenA = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    private let screenB = CGRect(x: 1920, y: 0, width: 1920, height: 1080)

    private let floatingPalette = FocusDimWindowInfo(
        windowNumber: 1, ownerPID: 100, frame: CGRect(x: 100, y: 100, width: 800, height: 600))
    private let mainWindow = FocusDimWindowInfo(
        windowNumber: 2, ownerPID: 100, frame: CGRect(x: 50, y: 50, width: 1000, height: 800))
    private let otherAppWindow = FocusDimWindowInfo(
        windowNumber: 3, ownerPID: 200, frame: CGRect(x: 2000, y: 100, width: 800, height: 600))

    private var windows: [FocusDimWindowInfo] {
        [floatingPalette, mainWindow, otherAppWindow]
    }

    @Test func dimUnfocusedPicksFrontmostAppsBottomWindowOnItsOwnScreen() {
        let result = FocusDimSelection.referenceWindow(
            forScreen: screenA, frontmostPID: 100, windowsFrontToBack: windows, mode: .dimUnfocused)
        #expect(result == mainWindow)
    }

    @Test func dimUnfocusedReturnsNilForScreensWithoutTheFrontmostApp() {
        let result = FocusDimSelection.referenceWindow(
            forScreen: screenB, frontmostPID: 100, windowsFrontToBack: windows, mode: .dimUnfocused)
        #expect(result == nil)
    }

    @Test func perScreenFrontPicksBottomWindowOfWhicheverAppIsTopOnThatScreen() {
        let onScreenA = FocusDimSelection.referenceWindow(
            forScreen: screenA, frontmostPID: 999, windowsFrontToBack: windows,
            mode: .perScreenFront)
        #expect(onScreenA == mainWindow)

        let onScreenB = FocusDimSelection.referenceWindow(
            forScreen: screenB, frontmostPID: 999, windowsFrontToBack: windows,
            mode: .perScreenFront)
        #expect(onScreenB == otherAppWindow)
    }

    @Test func returnsNilWhenNoWindowsAreOnScreen() {
        let empty = CGRect(x: 4000, y: 0, width: 1920, height: 1080)
        #expect(
            FocusDimSelection.referenceWindow(
                forScreen: empty, frontmostPID: 100, windowsFrontToBack: windows,
                mode: .perScreenFront) == nil)
        #expect(
            FocusDimSelection.referenceWindow(
                forScreen: screenA, frontmostPID: 100, windowsFrontToBack: [], mode: .dimUnfocused)
                == nil)
    }
}
