import CoreGraphics
import Foundation

public final class KnitRenderer: @unchecked Sendable {
    public static let shared = KnitRenderer()

    private let lock = NSLock()
    private var cache: [(key: KnitTileKey, tile: KnitTile)] = []
    private let cacheLimit = 64

    public init() {}

    public func flushCache() {
        lock.lock()
        cache.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    public func draw(
        in context: CGContext, windowRect: CGRect, radius: Double, band: Double,
        color: UInt32, chart: SweaterChart?, dim: Double, tuck: Double,
        stitch: SweaterStitch, anchor: SweaterAnchor, gauge: KnitGauge
    ) {
        guard band.isFinite, radius.isFinite, tuck.isFinite,
            windowRect.origin.x.isFinite, windowRect.origin.y.isFinite,
            windowRect.width > 0, windowRect.height > 0
        else { return }

        let band = max(band, 2)
        let radius = max(0, min(radius, Double(min(windowRect.width, windowRect.height)) * 0.5))
        var tuck = max(tuck, 1)
        let half = Double(min(windowRect.width, windowRect.height)) * 0.5 - 2
        if tuck > half { tuck = half > 1 ? half : 1 }

        let outer = windowRect.insetBy(dx: -band, dy: -band)
        let inner = windowRect.insetBy(dx: tuck, dy: tuck)
        let outerRadius = radius + band
        let innerRadius = radius > tuck ? radius - tuck : 0

        context.saveGState()
        defer { context.restoreGState() }

        let ring = CGMutablePath()
        ring.addRoundedRect(in: outer, cornerWidth: outerRadius, cornerHeight: outerRadius)
        ring.addRoundedRect(in: inner, cornerWidth: innerRadius, cornerHeight: innerRadius)
        context.addPath(ring)
        context.clip(using: .evenOdd)

        let solidCorners = chart?.solidCorners ?? false
        let declaredCorner = chart?.cornerColor ?? 0
        let cornerColor = solidCorners && declaredCorner != 0 ? declaredCorner : color

        let chartKey: KnitChartKey = chart.map { .chart($0.name) } ?? .plain
        guard
            let baseTile = tile(
                band: band, color: color, chart: chart, key: chartKey, stitch: stitch,
                gauge: gauge)
        else { return }

        var cuffTile: KnitTile?
        var cuffRing: CGMutablePath?
        if let chart, chart.cuffColor != 0 {
            cuffTile = tile(
                band: band, color: chart.cuffColor, chart: nil, key: .patch, stitch: stitch,
                gauge: gauge)
            if cuffTile != nil {
                let width = band / 3
                let path = CGMutablePath()
                path.addRoundedRect(
                    in: outer, cornerWidth: outerRadius, cornerHeight: outerRadius)
                path.addRoundedRect(
                    in: outer.insetBy(dx: width, dy: width),
                    cornerWidth: outerRadius - width, cornerHeight: outerRadius - width)
                cuffRing = path
            }
        }

        var patch: KnitTile?
        if solidCorners {
            patch = tile(
                band: band, color: cornerColor, chart: nil, key: .patch, stitch: stitch,
                gauge: gauge)
        }

        context.setAlpha(1)
        context.interpolationQuality = .high

        var reach = band + tuck + innerRadius * (1 - 0.5.squareRoot()) + 1
        let outerWidth = Double(outer.width)
        let outerHeight = Double(outer.height)
        reach = min(reach, outerWidth * 0.5)
        reach = min(reach, outerHeight * 0.5)

        let sides: [(origin: CGPoint, angle: Double, length: Double)] = [
            (CGPoint(x: outer.minX, y: outer.minY), 0, outerWidth),
            (CGPoint(x: outer.maxX, y: outer.minY), .pi / 2, outerHeight),
            (CGPoint(x: outer.maxX, y: outer.maxY), .pi, outerWidth),
            (CGPoint(x: outer.minX, y: outer.maxY), 3 * .pi / 2, outerHeight),
        ]

        let cuffPhase = chart?.name.hasPrefix("atelier-") ?? false
        let backing = KnitMath.components(cornerColor)

        for side in sides where side.length > 0 {
            let length = side.length
            context.saveGState()
            context.translateBy(x: side.origin.x, y: side.origin.y)
            context.rotate(by: CGFloat(side.angle))

            let mitre = CGMutablePath()
            mitre.move(to: CGPoint(x: 0, y: 0))
            mitre.addLine(to: CGPoint(x: length, y: 0))
            mitre.addLine(to: CGPoint(x: length - reach, y: reach))
            mitre.addLine(to: CGPoint(x: reach, y: reach))
            mitre.closeSubpath()
            context.setShouldAntialias(false)
            context.addPath(mitre)
            context.clip()
            context.setShouldAntialias(true)

            let phaseX = anchor == .centre ? length * 0.5 - baseTile.width * 0.5 : 0
            let phaseY = cuffPhase ? 0 : band * 0.5 - baseTile.height * 0.5

            context.setFillColor(
                red: backing.r * 0.96, green: backing.g * 0.96, blue: backing.b * 0.96, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: length, height: reach))

            if let patch {
                let cap = min(outerRadius, length * 0.5)
                for end in 0..<2 {
                    context.saveGState()
                    context.clip(
                        to: CGRect(
                            x: end == 1 ? length - cap : 0, y: 0, width: cap, height: reach))
                    context.draw(
                        patch.image,
                        in: CGRect(x: 0, y: phaseY, width: patch.width, height: patch.height),
                        byTiling: true)
                    context.restoreGState()
                }
            }

            if solidCorners {
                context.saveGState()
                let cap = min(outerRadius, length * 0.5)
                let available = max(0, length - 2 * cap)
                if available > 0 {
                    let repeats = max(1, (available / baseTile.width).rounded())
                    let repeatWidth = available / repeats
                    context.clip(to: CGRect(x: cap, y: 0, width: available, height: reach))
                    context.draw(
                        baseTile.image,
                        in: CGRect(x: cap, y: phaseY, width: repeatWidth, height: baseTile.height),
                        byTiling: true)
                }
                context.restoreGState()
            } else {
                let fitted = chart?.fittedRepeat ?? false
                let repeatWidth =
                    fitted ? length / max(1, (length / baseTile.width).rounded()) : baseTile.width
                context.draw(
                    baseTile.image,
                    in: CGRect(
                        x: fitted ? 0 : phaseX, y: phaseY, width: repeatWidth,
                        height: baseTile.height),
                    byTiling: true)
            }

            if let cuffRing, let cuffTile {
                context.saveGState()
                context.rotate(by: CGFloat(-side.angle))
                context.translateBy(x: -side.origin.x, y: -side.origin.y)
                context.addPath(cuffRing)
                context.clip(using: .evenOdd)
                context.translateBy(x: side.origin.x, y: side.origin.y)
                context.rotate(by: CGFloat(side.angle))
                context.draw(
                    cuffTile.image,
                    in: CGRect(x: 0, y: 0, width: cuffTile.width, height: cuffTile.height),
                    byTiling: true)
                context.restoreGState()
            }

            if dim > 0.001 {
                context.setFillColor(red: 0, green: 0, blue: 0, alpha: CGFloat(dim))
                context.fill(
                    CGRect(
                        x: -reach, y: -reach, width: length + 2 * reach, height: reach + 2 * reach))
            }
            context.restoreGState()
        }
    }

    private func tile(
        band: Double, color: UInt32, chart: SweaterChart?, key: KnitChartKey,
        stitch: SweaterStitch, gauge: KnitGauge
    ) -> KnitTile? {
        let band = (band * 2).rounded() / 2
        let cacheKey = KnitTileKey(
            band: band, color: color, chart: key, stitch: stitch,
            gauge: Int((gauge.rows * 100).rounded()))
        lock.lock()
        defer { lock.unlock() }
        if let hit = cache.first(where: { $0.key == cacheKey }) { return hit.tile }
        guard
            let tile = KnitTileBuilder.make(
                band: band, color: color, chart: chart, key: key, stitch: stitch, gauge: gauge)
        else { return nil }
        if cache.count == cacheLimit { cache.removeFirst() }
        cache.append((cacheKey, tile))
        return tile
    }
}
