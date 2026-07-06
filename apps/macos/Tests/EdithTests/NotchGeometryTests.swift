import CoreGraphics
import Testing
@testable import EdithMenuBar

@Suite struct NotchGeometryTests {
    @Test func usesRealNotchMathWhenAreasArePresent() {
        let size = NotchGeometry.collapsedSize(
            screenWidth: 1512, leftAreaWidth: 676, rightAreaWidth: 676, safeAreaTop: 32)
        #expect(size.width == 160)
        #expect(size.height == 32)
    }

    @Test func fallsBackWhenSafeAreaIsZero() {
        let size = NotchGeometry.collapsedSize(
            screenWidth: 1920, leftAreaWidth: nil, rightAreaWidth: nil, safeAreaTop: 0)
        #expect(size == NotchGeometry.fallbackSize)
    }

    @Test func fallsBackWhenAreasAreMissingEvenWithSafeArea() {
        let size = NotchGeometry.collapsedSize(
            screenWidth: 1920, leftAreaWidth: nil, rightAreaWidth: 800, safeAreaTop: 24)
        #expect(size == NotchGeometry.fallbackSize)
    }

    @Test func fallsBackWhenComputedWidthIsNonPositive() {
        let size = NotchGeometry.collapsedSize(
            screenWidth: 1000, leftAreaWidth: 500, rightAreaWidth: 500, safeAreaTop: 30)
        #expect(size == NotchGeometry.fallbackSize)
    }

    @Test func originCentersPanelAtTopOfScreen() {
        let screenFrame = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let origin = NotchGeometry.origin(
            screenFrame: screenFrame, panelSize: CGSize(width: 160, height: 32))
        #expect(origin == CGPoint(x: 676, y: 950))
    }
}
