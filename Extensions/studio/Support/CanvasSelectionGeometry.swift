import EdithExtensionUI
import Foundation

enum CanvasSelectionGeometry {
    static func anchor(_ corner: Int, in frame: CGRect) -> CGPoint {
        CGPoint(
            x: corner % 2 == 0 ? frame.minX : frame.maxX,
            y: corner < 2 ? frame.minY : frame.maxY)
    }

    static func corner(at point: CGPoint, frame: CGRect) -> Int? {
        (0..<4).first {
            let anchor = anchor($0, in: frame)
            return hypot(point.x - anchor.x, point.y - anchor.y) <= UIScale.pt(12)
        }
    }

    static func resize(
        _ frame: CGRect, corner: Int, delta: CGPoint,
        minimum: CGFloat = 0.02, preserveAspect: Bool = false
    ) -> CGRect {
        let left = corner % 2 == 0
        let top = corner < 2
        var width = max(minimum, frame.width + (left ? -delta.x : delta.x))
        var height = max(minimum, frame.height + (top ? -delta.y : delta.y))
        if preserveAspect, frame.width > 0, frame.height > 0 {
            let scale =
                abs(delta.x / frame.width) > abs(delta.y / frame.height)
                ? width / frame.width : height / frame.height
            let bounded = max(scale, minimum / min(frame.width, frame.height))
            width = frame.width * bounded
            height = frame.height * bounded
        }
        return CGRect(
            x: left ? frame.maxX - width : frame.minX,
            y: top ? frame.maxY - height : frame.minY, width: width, height: height)
    }
}
