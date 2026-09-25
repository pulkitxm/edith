import CoreGraphics
import Foundation

public struct VirtualCameraCrop: Equatable, Sendable {
    public var center: CGPoint
    public var size: CGSize
    public var angle: Double

    public init(center: CGPoint, size: CGSize, angle: Double) {
        self.center = center
        self.size = size
        self.angle = angle
    }

    public var rect: CGRect {
        CGRect(
            x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width,
            height: size.height)
    }

    public var boundingSize: CGSize {
        let radians = abs(angle) * .pi / 180
        return CGSize(
            width: size.width * cos(radians) + size.height * sin(radians),
            height: size.width * sin(radians) + size.height * cos(radians))
    }
}

public enum VirtualCameraGeometry {
    public static func orientedSize(_ size: CGSize, quarterTurns: Int) -> CGSize {
        quarterTurns % 2 == 0 ? size : CGSize(width: size.height, height: size.width)
    }

    public static func baseCropSize(source: CGSize, output: CGSize, tilt: Double) -> CGSize {
        guard source.width > 0, source.height > 0, output.width > 0, output.height > 0 else {
            return .zero
        }
        let aspect = output.width / output.height
        var width = source.width
        var height = width / aspect
        if height > source.height {
            height = source.height
            width = height * aspect
        }
        let radians = abs(tilt) * .pi / 180
        guard radians > 0 else { return CGSize(width: width, height: height) }
        let boundingWidth = width * cos(radians) + height * sin(radians)
        let boundingHeight = width * sin(radians) + height * cos(radians)
        let scale = min(source.width / boundingWidth, source.height / boundingHeight, 1)
        return CGSize(width: width * scale, height: height * scale)
    }

    public static func crop(
        source: CGSize, output: CGSize, framing: VirtualCameraFraming
    ) -> VirtualCameraCrop {
        let framing = framing.sanitized()
        let base = baseCropSize(source: source, output: output, tilt: framing.tilt)
        let size = CGSize(width: base.width / framing.zoom, height: base.height / framing.zoom)
        var crop = VirtualCameraCrop(
            center: CGPoint(x: framing.centerX * source.width, y: framing.centerY * source.height),
            size: size, angle: framing.tilt)
        let bounds = crop.boundingSize
        crop.center.x = clampCenter(crop.center.x, half: bounds.width / 2, length: source.width)
        crop.center.y = clampCenter(crop.center.y, half: bounds.height / 2, length: source.height)
        return crop
    }

    public static func clampCenter(_ value: CGFloat, half: CGFloat, length: CGFloat) -> CGFloat {
        guard half * 2 < length else { return length / 2 }
        return min(max(value, half), length - half)
    }

    public static func normalizedCenter(
        of crop: VirtualCameraCrop, source: CGSize
    ) -> (x: Double, y: Double) {
        guard source.width > 0, source.height > 0 else { return (0.5, 0.5) }
        return (Double(crop.center.x / source.width), Double(crop.center.y / source.height))
    }

    public static func clamped(
        _ framing: VirtualCameraFraming, source: CGSize, output: CGSize
    ) -> VirtualCameraFraming {
        var result = framing.sanitized()
        let crop = crop(source: source, output: output, framing: result)
        let center = normalizedCenter(of: crop, source: source)
        result.centerX = center.x
        result.centerY = center.y
        return result
    }

    public static func panned(
        _ framing: VirtualCameraFraming, by translation: CGSize, viewSize: CGSize,
        source: CGSize, output: CGSize
    ) -> VirtualCameraFraming {
        guard viewSize.width > 0, viewSize.height > 0, source.width > 0, source.height > 0 else {
            return framing
        }
        let current = clamped(framing, source: source, output: output)
        let crop = crop(source: source, output: output, framing: current)
        let scale = crop.size.width / viewSize.width
        let radians = current.tilt * .pi / 180
        let dx = translation.width * scale
        let dy = translation.height * scale
        let rotatedX = dx * cos(radians) - dy * sin(radians)
        let rotatedY = dx * sin(radians) + dy * cos(radians)
        var next = current
        next.centerX = current.centerX - Double(rotatedX / source.width)
        next.centerY = current.centerY - Double(rotatedY / source.height)
        return clamped(next, source: source, output: output)
    }

    public static func zoomed(
        _ framing: VirtualCameraFraming, by factor: Double, anchor: CGPoint, source: CGSize,
        output: CGSize
    ) -> VirtualCameraFraming {
        guard factor.isFinite, factor > 0, source.width > 0, source.height > 0 else {
            return framing
        }
        let current = clamped(framing, source: source, output: output)
        let before = crop(source: source, output: output, framing: current)
        var next = current
        next.zoom = VirtualCameraMath.clamp(
            current.zoom * factor, VirtualCameraFraming.zoomRange, fallback: current.zoom)
        let after = crop(source: source, output: output, framing: next)
        let anchorX = min(max(anchor.x, 0), 1) - 0.5
        let anchorY = min(max(anchor.y, 0), 1) - 0.5
        let pointX = before.center.x + anchorX * before.size.width
        let pointY = before.center.y + anchorY * before.size.height
        next.centerX = Double((pointX - anchorX * after.size.width) / source.width)
        next.centerY = Double((pointY - anchorY * after.size.height) / source.height)
        return clamped(next, source: source, output: output)
    }

    public static func interpolate(
        _ from: VirtualCameraFraming, _ to: VirtualCameraFraming, progress: Double
    ) -> VirtualCameraFraming {
        let t = VirtualCameraMath.easeInOut(progress)
        guard t < 1 else { return to }
        guard t > 0 else { return from }
        var result = t < 0.5 ? from : to
        let fromZoom = max(from.zoom, 0.0001)
        let toZoom = max(to.zoom, 0.0001)
        result.zoom = exp(VirtualCameraMath.mix(log(fromZoom), log(toZoom), t))
        result.centerX = VirtualCameraMath.mix(from.centerX, to.centerX, t)
        result.centerY = VirtualCameraMath.mix(from.centerY, to.centerY, t)
        result.tilt = VirtualCameraMath.mix(from.tilt, to.tilt, t)
        return result
    }

    public static func requiredSourceWidth(
        output: CGSize, zoom: Double, sourceAspect: Double
    ) -> Int {
        guard output.width > 0, output.height > 0, sourceAspect > 0 else { return 0 }
        let outputAspect = output.width / output.height
        let widthFactor = outputAspect > sourceAspect ? 1 : sourceAspect / outputAspect
        return Int((Double(output.width) * max(zoom, 1) * widthFactor).rounded(.up))
    }
}
