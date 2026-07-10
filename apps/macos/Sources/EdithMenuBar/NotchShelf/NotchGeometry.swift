import CoreGraphics

enum NotchGeometry {
    static let topFlareRadius: CGFloat = 6
    static let fallbackSize = CGSize(width: 150, height: 28)
    static let expandedSize = CGSize(width: 360, height: 190)

    static func collapsedSize(
        screenWidth: CGFloat,
        leftAreaWidth: CGFloat?,
        rightAreaWidth: CGFloat?,
        safeAreaTop: CGFloat
    ) -> CGSize {
        guard safeAreaTop > 0, let left = leftAreaWidth, let right = rightAreaWidth else {
            return fallbackSize
        }
        let width = screenWidth - left - right
        guard width > 1 else { return fallbackSize }
        return CGSize(width: width + 2 * topFlareRadius, height: safeAreaTop)
    }

    static func origin(screenFrame: CGRect, panelSize: CGSize) -> CGPoint {
        CGPoint(x: screenFrame.midX - panelSize.width / 2, y: screenFrame.maxY - panelSize.height)
    }

    static let openMargin: CGFloat = 6
    static let keepOpenMargin: CGFloat = 24

    static let expandedTopRadius: CGFloat = 18
    static let expandedBottomRadius: CGFloat = 34
    static let resizingBottomRadius: CGFloat = 10

    static func proximity(
        point: CGPoint,
        collapsedFrame: CGRect,
        expandedFrame: CGRect,
        openMargin: CGFloat = openMargin,
        keepOpenMargin: CGFloat = keepOpenMargin
    ) -> NotchProximity {
        if collapsedFrame.insetBy(dx: -openMargin, dy: -openMargin).contains(point) {
            return .open
        }
        if expandedFrame.insetBy(dx: -keepOpenMargin, dy: -keepOpenMargin).contains(point) {
            return .keepOpen
        }
        return .outside
    }

    static func hardwareNotchRect(in panelSize: CGSize, collapsedSize: CGSize) -> CGRect {
        let width = min(collapsedSize.width, panelSize.width)
        let height = min(collapsedSize.height, panelSize.height)
        return CGRect(
            x: (panelSize.width - width) / 2, y: panelSize.height - height,
            width: width, height: height)
    }

    static let itemCell = CGSize(width: 78, height: 70)

    static func itemPosition(stored: CGPoint?, index: Int, in size: CGSize) -> CGPoint {
        let point = stored ?? defaultItemPosition(index: index, in: size)
        return CGPoint(
            x: min(max(point.x, itemCell.width / 2), size.width - itemCell.width / 2),
            y: min(max(point.y, itemCell.height / 2), size.height - itemCell.height / 2))
    }

    static func defaultItemPosition(index: Int, in size: CGSize) -> CGPoint {
        let columns = max(1, Int((size.width - 24) / itemCell.width))
        let column = index % columns
        let row = index / columns
        return CGPoint(
            x: 12 + itemCell.width * (CGFloat(column) + 0.5),
            y: 10 + itemCell.height * (CGFloat(row) + 0.5))
    }
}
