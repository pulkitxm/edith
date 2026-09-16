import CoreGraphics
import Foundation

public enum BifrostWindowAction: String, CaseIterable, Codable, Hashable, Sendable {
    case leftHalf
    case rightHalf
    case topHalf
    case bottomHalf
    case topLeftQuarter
    case topRightQuarter
    case bottomLeftQuarter
    case bottomRightQuarter
    case firstThird
    case centerThird
    case lastThird
    case firstTwoThirds
    case lastTwoThirds
    case maximize
    case almostMaximize
    case maximizeHeight
    case maximizeWidth
    case centerWindow
    case restore
    case larger
    case smaller
    case nudgeLeft
    case nudgeRight
    case nudgeUp
    case nudgeDown
    case nextDisplay
    case previousDisplay

    public var title: String {
        switch self {
        case .leftHalf: "Left Half"
        case .rightHalf: "Right Half"
        case .topHalf: "Top Half"
        case .bottomHalf: "Bottom Half"
        case .topLeftQuarter: "Top Left Quarter"
        case .topRightQuarter: "Top Right Quarter"
        case .bottomLeftQuarter: "Bottom Left Quarter"
        case .bottomRightQuarter: "Bottom Right Quarter"
        case .firstThird: "First Third"
        case .centerThird: "Center Third"
        case .lastThird: "Last Third"
        case .firstTwoThirds: "First Two Thirds"
        case .lastTwoThirds: "Last Two Thirds"
        case .maximize: "Maximize"
        case .almostMaximize: "Almost Maximize"
        case .maximizeHeight: "Maximize Height"
        case .maximizeWidth: "Maximize Width"
        case .centerWindow: "Center"
        case .restore: "Restore"
        case .larger: "Make Larger"
        case .smaller: "Make Smaller"
        case .nudgeLeft: "Move Left"
        case .nudgeRight: "Move Right"
        case .nudgeUp: "Move Up"
        case .nudgeDown: "Move Down"
        case .nextDisplay: "Move to Next Display"
        case .previousDisplay: "Move to Previous Display"
        }
    }

    public var symbolName: String {
        switch self {
        case .leftHalf, .firstThird, .firstTwoThirds: "rectangle.lefthalf.filled"
        case .rightHalf, .lastThird, .lastTwoThirds: "rectangle.righthalf.filled"
        case .topHalf: "rectangle.tophalf.filled"
        case .bottomHalf: "rectangle.bottomhalf.filled"
        case .topLeftQuarter, .topRightQuarter, .bottomLeftQuarter, .bottomRightQuarter:
            "rectangle.split.2x2"
        case .centerThird, .centerWindow: "rectangle.center.inset.filled"
        case .maximize, .almostMaximize: "arrow.up.left.and.arrow.down.right"
        case .maximizeHeight: "arrow.up.and.down"
        case .maximizeWidth: "arrow.left.and.right"
        case .restore: "arrow.uturn.backward"
        case .larger: "plus.magnifyingglass"
        case .smaller: "minus.magnifyingglass"
        case .nudgeLeft: "arrow.left"
        case .nudgeRight: "arrow.right"
        case .nudgeUp: "arrow.up"
        case .nudgeDown: "arrow.down"
        case .nextDisplay, .previousDisplay: "display.2"
        }
    }

    public var keywords: [String] {
        switch self {
        case .maximize: ["full", "fullscreen", "fill"]
        case .centerWindow: ["middle"]
        case .nextDisplay, .previousDisplay: ["monitor", "screen", "display"]
        default: ["window", "resize"]
        }
    }

    public var movesDisplay: Bool {
        self == .nextDisplay || self == .previousDisplay
    }

    public var restoresPrevious: Bool {
        self == .restore
    }

    public func frame(
        in visible: CGRect, current: CGRect, step: CGFloat = 40
    ) -> CGRect? {
        guard visible.width > 0, visible.height > 0 else { return nil }
        switch self {
        case .leftHalf: return slice(visible, x: 0, width: 0.5)
        case .rightHalf: return slice(visible, x: 0.5, width: 0.5)
        case .topHalf: return slice(visible, y: 0, height: 0.5)
        case .bottomHalf: return slice(visible, y: 0.5, height: 0.5)
        case .topLeftQuarter: return slice(visible, x: 0, width: 0.5, y: 0, height: 0.5)
        case .topRightQuarter: return slice(visible, x: 0.5, width: 0.5, y: 0, height: 0.5)
        case .bottomLeftQuarter: return slice(visible, x: 0, width: 0.5, y: 0.5, height: 0.5)
        case .bottomRightQuarter:
            return slice(visible, x: 0.5, width: 0.5, y: 0.5, height: 0.5)
        case .firstThird: return slice(visible, x: 0, width: 1.0 / 3)
        case .centerThird: return slice(visible, x: 1.0 / 3, width: 1.0 / 3)
        case .lastThird: return slice(visible, x: 2.0 / 3, width: 1.0 / 3)
        case .firstTwoThirds: return slice(visible, x: 0, width: 2.0 / 3)
        case .lastTwoThirds: return slice(visible, x: 1.0 / 3, width: 2.0 / 3)
        case .maximize: return visible
        case .almostMaximize: return scaled(visible, factor: 0.9)
        case .maximizeHeight:
            return CGRect(
                x: current.minX, y: visible.minY, width: current.width, height: visible.height)
        case .maximizeWidth:
            return CGRect(
                x: visible.minX, y: current.minY, width: visible.width, height: current.height)
        case .centerWindow: return centered(current.size, in: visible)
        case .larger: return resized(current, in: visible, by: 1.1)
        case .smaller: return resized(current, in: visible, by: 1 / 1.1)
        case .nudgeLeft: return moved(current, in: visible, dx: -step, dy: 0)
        case .nudgeRight: return moved(current, in: visible, dx: step, dy: 0)
        case .nudgeUp: return moved(current, in: visible, dx: 0, dy: -step)
        case .nudgeDown: return moved(current, in: visible, dx: 0, dy: step)
        case .restore, .nextDisplay, .previousDisplay: return nil
        }
    }

    public static func proportional(
        _ frame: CGRect, from source: CGRect, to target: CGRect
    ) -> CGRect {
        guard source.width > 0, source.height > 0 else { return target }
        let scaleX = target.width / source.width
        let scaleY = target.height / source.height
        let size = CGSize(
            width: min(frame.width * scaleX, target.width),
            height: min(frame.height * scaleY, target.height))
        let origin = CGPoint(
            x: target.minX + (frame.minX - source.minX) * scaleX,
            y: target.minY + (frame.minY - source.minY) * scaleY)
        return clamp(CGRect(origin: origin, size: size), to: target)
    }

    private func slice(
        _ visible: CGRect, x: CGFloat = 0, width: CGFloat = 1, y: CGFloat = 0,
        height: CGFloat = 1
    ) -> CGRect {
        CGRect(
            x: visible.minX + visible.width * x, y: visible.minY + visible.height * y,
            width: visible.width * width, height: visible.height * height
        ).integral
    }

    private func scaled(_ visible: CGRect, factor: CGFloat) -> CGRect {
        let size = CGSize(width: visible.width * factor, height: visible.height * factor)
        return centered(size, in: visible)
    }

    private func centered(_ size: CGSize, in visible: CGRect) -> CGRect {
        let width = min(size.width, visible.width)
        let height = min(size.height, visible.height)
        return CGRect(
            x: visible.midX - width / 2, y: visible.midY - height / 2,
            width: width, height: height
        ).integral
    }

    private func resized(_ current: CGRect, in visible: CGRect, by factor: CGFloat) -> CGRect {
        let size = CGSize(
            width: max(240, min(current.width * factor, visible.width)),
            height: max(160, min(current.height * factor, visible.height)))
        return Self.clamp(
            CGRect(
                x: current.midX - size.width / 2, y: current.midY - size.height / 2,
                width: size.width, height: size.height), to: visible)
    }

    private func moved(
        _ current: CGRect, in visible: CGRect, dx: CGFloat, dy: CGFloat
    ) -> CGRect {
        Self.clamp(current.offsetBy(dx: dx, dy: dy), to: visible)
    }

    static func clamp(_ frame: CGRect, to visible: CGRect) -> CGRect {
        let width = min(frame.width, visible.width)
        let height = min(frame.height, visible.height)
        let x = min(max(frame.minX, visible.minX), visible.maxX - width)
        let y = min(max(frame.minY, visible.minY), visible.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height).integral
    }
}
