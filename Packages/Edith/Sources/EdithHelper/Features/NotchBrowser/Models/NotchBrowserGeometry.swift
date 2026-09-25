import CoreGraphics

enum NotchBrowserResizeEdge: Equatable, Sendable {
    case bottom, bottomLeading, bottomTrailing
}

enum NotchBrowserGeometry {
    static let defaultSize = CGSize(width: 980, height: 640)
    static let minimumSize = CGSize(width: 620, height: 380)
    static let screenMargin = CGSize(width: 24, height: 12)
    static let contentInset: CGFloat = 6

    static func maximumSize(screen: CGSize) -> CGSize {
        CGSize(
            width: max(minimumSize.width, screen.width - 2 * screenMargin.width),
            height: max(minimumSize.height, screen.height - screenMargin.height))
    }

    static func clamp(_ size: CGSize, screen: CGSize?) -> CGSize {
        let upper = screen.map(maximumSize(screen:)) ?? CGSize(width: 4096, height: 4096)
        return CGSize(
            width: min(max(size.width, minimumSize.width), upper.width).rounded(),
            height: min(max(size.height, minimumSize.height), upper.height).rounded())
    }

    static func resized(
        from start: CGSize, edge: NotchBrowserResizeEdge, pointerStart: CGPoint,
        pointer: CGPoint, screen: CGSize?
    ) -> CGSize {
        let dx = pointer.x - pointerStart.x
        let dy = pointerStart.y - pointer.y
        var size = CGSize(width: start.width, height: start.height + dy)
        switch edge {
        case .bottom: break
        case .bottomLeading: size.width = start.width - 2 * dx
        case .bottomTrailing: size.width = start.width + 2 * dx
        }
        return clamp(size, screen: screen)
    }

    static func shapeSize(browser: CGSize, notchHeight: CGFloat) -> CGSize {
        CGSize(width: browser.width, height: browser.height + notchHeight)
    }
}
