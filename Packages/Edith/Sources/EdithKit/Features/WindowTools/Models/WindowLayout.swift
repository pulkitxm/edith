import EdithCore
import Foundation

public enum WindowLayoutAction: String, CaseIterable, Codable, Identifiable, Sendable {
    case leftHalf = "left-half"
    case rightHalf = "right-half"
    case topHalf = "top-half"
    case bottomHalf = "bottom-half"
    case topLeft = "top-left"
    case topRight = "top-right"
    case bottomLeft = "bottom-left"
    case bottomRight = "bottom-right"
    case center
    case maximize
    case nextDisplay = "next-display"
    case restore

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .leftHalf: "Left half"
        case .rightHalf: "Right half"
        case .topHalf: "Top half"
        case .bottomHalf: "Bottom half"
        case .topLeft: "Top left"
        case .topRight: "Top right"
        case .bottomLeft: "Bottom left"
        case .bottomRight: "Bottom right"
        case .center: "Center"
        case .maximize: "Maximize"
        case .nextDisplay: "Next display"
        case .restore: "Restore"
        }
    }

    public var symbolName: String {
        switch self {
        case .leftHalf: "rectangle.lefthalf.inset.filled"
        case .rightHalf: "rectangle.righthalf.inset.filled"
        case .topHalf: "rectangle.tophalf.inset.filled"
        case .bottomHalf: "rectangle.bottomhalf.inset.filled"
        case .topLeft: "arrow.up.left"
        case .topRight: "arrow.up.right"
        case .bottomLeft: "arrow.down.left"
        case .bottomRight: "arrow.down.right"
        case .center: "scope"
        case .maximize: "arrow.up.left.and.arrow.down.right"
        case .nextDisplay: "arrow.right.to.line"
        case .restore: "arrow.uturn.backward"
        }
    }

    public var descriptor: UserOperationDescriptor {
        UserOperationDescriptor(
            id: UserOperationID(rawValue: "window.\(rawValue)"),
            summary: "\(title) for the active window.", cli: ["window", rawValue],
            effect: .write)
    }
}

public enum WindowLayoutGeometry {
    public static func frame(
        for action: WindowLayoutAction, current: CGRect, visibleFrame: CGRect
    ) -> CGRect? {
        let halfWidth = visibleFrame.width / 2
        let halfHeight = visibleFrame.height / 2
        return switch action {
        case .leftHalf:
            CGRect(
                x: visibleFrame.minX, y: visibleFrame.minY, width: halfWidth,
                height: visibleFrame.height
            ).alignedToPixels
        case .rightHalf:
            CGRect(
                x: visibleFrame.midX, y: visibleFrame.minY, width: halfWidth,
                height: visibleFrame.height
            ).alignedToPixels
        case .topHalf:
            CGRect(
                x: visibleFrame.minX, y: visibleFrame.midY, width: visibleFrame.width,
                height: halfHeight
            ).alignedToPixels
        case .bottomHalf:
            CGRect(
                x: visibleFrame.minX, y: visibleFrame.minY, width: visibleFrame.width,
                height: halfHeight
            ).alignedToPixels
        case .topLeft:
            CGRect(
                x: visibleFrame.minX, y: visibleFrame.midY, width: halfWidth, height: halfHeight
            ).alignedToPixels
        case .topRight:
            CGRect(
                x: visibleFrame.midX, y: visibleFrame.midY, width: halfWidth, height: halfHeight
            ).alignedToPixels
        case .bottomLeft:
            CGRect(
                x: visibleFrame.minX, y: visibleFrame.minY, width: halfWidth, height: halfHeight
            ).alignedToPixels
        case .bottomRight:
            CGRect(
                x: visibleFrame.midX, y: visibleFrame.minY, width: halfWidth, height: halfHeight
            ).alignedToPixels
        case .center:
            CGRect(
                x: visibleFrame.midX - min(current.width, visibleFrame.width) / 2,
                y: visibleFrame.midY - min(current.height, visibleFrame.height) / 2,
                width: min(current.width, visibleFrame.width),
                height: min(current.height, visibleFrame.height)
            ).alignedToPixels
        case .maximize:
            visibleFrame.alignedToPixels
        case .nextDisplay, .restore:
            nil
        }
    }

    public static func movedFrame(
        current: CGRect, from source: CGRect, to destination: CGRect
    ) -> CGRect {
        let xProgress =
            source.width > current.width
            ? (current.minX - source.minX) / (source.width - current.width) : 0.5
        let yProgress =
            source.height > current.height
            ? (current.minY - source.minY) / (source.height - current.height) : 0.5
        let width = min(current.width, destination.width)
        let height = min(current.height, destination.height)
        return CGRect(
            x: destination.minX + max(0, min(1, xProgress)) * (destination.width - width),
            y: destination.minY + max(0, min(1, yProgress)) * (destination.height - height),
            width: width, height: height
        ).alignedToPixels
    }
}

public enum WindowCoordinateGeometry {
    public static func appKitFrame(
        fromAccessibility frame: CGRect, menuBarScreenTopY: CGFloat
    ) -> CGRect {
        CGRect(
            x: frame.minX, y: menuBarScreenTopY - frame.maxY, width: frame.width,
            height: frame.height)
    }

    public static func accessibilityFrame(
        fromAppKit frame: CGRect, menuBarScreenTopY: CGFloat
    ) -> CGRect {
        CGRect(
            x: frame.minX, y: menuBarScreenTopY - frame.maxY, width: frame.width,
            height: frame.height)
    }
}

private extension CGRect {
    var alignedToPixels: CGRect {
        let x = minX.rounded()
        let y = minY.rounded()
        return CGRect(
            x: x, y: y, width: maxX.rounded() - x, height: maxY.rounded() - y)
    }
}

public enum WindowLayoutRequest {
    public static let actionKey = "action"

    @discardableResult
    public static func send(
        _ action: WindowLayoutAction,
        post: (Notification.Name, [String: Any]?) -> Void = { IPC.post($0, userInfo: $1) }
    ) -> UserOperationDescriptor {
        post(IPC.Name.requestWindowLayout, [actionKey: action.rawValue])
        return action.descriptor
    }
}
