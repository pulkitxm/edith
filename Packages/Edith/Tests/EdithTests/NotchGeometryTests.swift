import CoreGraphics
import Testing
@testable import EdithHelper

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

    @Test func defaultItemPositionsFlowInRows() {
        let size = CGSize(width: 360, height: 190)
        let first = NotchGeometry.defaultItemPosition(index: 0, in: size)
        let second = NotchGeometry.defaultItemPosition(index: 1, in: size)
        #expect(second.x > first.x)
        #expect(second.y == first.y)
        let wrapped = NotchGeometry.defaultItemPosition(index: 4, in: size)
        #expect(wrapped.x == first.x)
        #expect(wrapped.y > first.y)
    }

    @Test func storedItemPositionIsClampedInsideBounds() {
        let size = CGSize(width: 360, height: 190)
        let clamped = NotchGeometry.itemPosition(
            stored: CGPoint(x: -50, y: 500), index: 0, in: size)
        #expect(clamped.x == NotchGeometry.itemCell.width / 2)
        #expect(clamped.y == size.height - NotchGeometry.itemCell.height / 2)
    }

    @Test func interactionFrameUsesSharedInsetForDragNearAndDropAcceptance() {
        let shape = CGRect(x: 100, y: 200, width: 160, height: 32)
        let interactionFrame = NotchGeometry.interactionFrame(around: shape)
        #expect(interactionFrame.minX == shape.minX - NotchGeometry.interactInset)
        #expect(interactionFrame.minY == shape.minY - NotchGeometry.interactInset)
        #expect(interactionFrame.maxX == shape.maxX + NotchGeometry.interactInset)
        #expect(interactionFrame.maxY == shape.maxY + NotchGeometry.interactInset)
    }
}
