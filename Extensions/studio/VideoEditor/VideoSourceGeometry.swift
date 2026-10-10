import CoreImage

struct VideoSourceGeometry {
    let source: CGRect
    let zoom: ZoomAnimation.State
    let transform: CGAffineTransform

    init(
        extent: CGRect, clip: VideoProject.Clip, effects: VideoVisualEffects,
        timeMs: Double, canvas: CGSize, padding: CGFloat,
        zooms: [VideoProject.Zoom], cursor: CGPoint?
    ) {
        if let crop = clip.crop {
            source = CGRect(
                x: extent.minX + extent.width * (crop["x"] ?? 0),
                y: extent.minY + extent.height * (1 - (crop["y"] ?? 0) - (crop["height"] ?? 1)),
                width: extent.width * (crop["width"] ?? 1),
                height: extent.height * (crop["height"] ?? 1)
            ).intersection(extent)
        } else {
            source = extent
        }
        zoom = ZoomAnimation.sample(at: timeMs, zooms: zooms, cursor: cursor)
        transform = effects.transform(
            source: source.size, canvas: canvas, padding: padding,
            at: clip.start + timeMs / 1000 - clip.timelineStart, zoom: zoom)
    }

    static func orientation(size: CGSize, preferred: CGAffineTransform) -> CGAffineTransform {
        let display = CGRect(origin: .zero, size: size).applying(preferred)
        return CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: size.height)
            .concatenating(preferred)
            .concatenating(
                CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: display.minY + display.maxY))
    }

    func covers(_ rect: CGRect) -> Bool {
        guard !source.isEmpty, !source.isInfinite, !rect.isEmpty,
            abs(transform.a * transform.d - transform.b * transform.c) > 1e-12
        else { return false }
        let inverse = transform.inverted()
        let epsilon = max(source.width, source.height) * 1e-8
        return [
            CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY),
        ].allSatisfy {
            let point = $0.applying(inverse)
            return point.x >= -epsilon && point.y >= -epsilon
                && point.x <= source.width + epsilon && point.y <= source.height + epsilon
        }
    }

    func intendedRegion(effects: VideoVisualEffects, canvas: CGSize, padding: CGFloat) -> CGRect {
        var baseline = effects
        baseline.keyframes = []
        return CGRect(origin: .zero, size: source.size)
            .applying(
                baseline.transform(source: source.size, canvas: canvas, padding: padding, at: 0)
            )
            .intersection(CGRect(origin: .zero, size: canvas))
    }
}
