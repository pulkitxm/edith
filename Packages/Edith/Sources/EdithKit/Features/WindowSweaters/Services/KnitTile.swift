import CoreGraphics
import Foundation

public enum KnitChartKey: Hashable, Sendable {
    case plain
    case patch
    case chart(String)
}

struct KnitTileKey: Hashable {
    let band: Double
    let color: UInt32
    let chart: KnitChartKey
    let stitch: SweaterStitch
    let gauge: Int
}

struct KnitTile {
    let image: CGImage
    let width: Double
    let height: Double
}

enum KnitTileBuilder {
    static let layerWidths: [Float] = [1.00, 0.80, 0.60, 0.40, 0.20]
    static let layerHeights: [Float] = [0.22, 0.48, 0.70, 0.88, 1.00]

    static func make(
        band: Double, color: UInt32, chart: SweaterChart?, key: KnitChartKey,
        stitch: SweaterStitch, gauge: KnitGauge
    ) -> KnitTile? {
        let isPatch = key == .patch
        let sculpted = isPatch || (chart?.sculptedYarn ?? false)
        let material = sculpted ? gauge.sculpted : gauge
        let chart = isPatch ? nil : chart

        let rows = max(Float(material.rows), 1.5)
        var rowStep = Float(band) / rows
        var stitchWidth = rowStep * Float(material.aspect)

        var columnCount: Int
        var rowCount: Int
        if let chart {
            let density: Float = sculpted ? 1 : 2
            stitchWidth /= density
            rowStep /= density
            columnCount = Int(Float(chart.width) * density)
            rowCount = Int(Float(chart.height) * density)
            columnCount *= Int(max(1, (8 / (stitchWidth * Float(columnCount))).rounded(.up)))
            rowCount *= Int(max(1, (8 / (rowStep * Float(rowCount))).rounded(.up)))
        } else {
            columnCount = 8
            rowCount = 8
        }

        let tileWidth = max(8, Int((stitchWidth * Float(columnCount)).rounded()))
        let tileHeight = max(8, Int((rowStep * Float(rowCount)).rounded()))
        stitchWidth = Float(tileWidth) / Float(columnCount)
        rowStep = Float(tileHeight) / Float(rowCount)
        let stitchHeight = rowStep / (1 - Float(material.rowOverlap))

        var yarnWidth = max(stitchWidth * Float(material.yarn), sculpted ? 0.8 : 0.35)
        if chart == nil, !sculpted, stitch == .rib { yarnWidth = stitchWidth * 0.55 }

        let scale = rowStep < 4 ? 4 : 2
        if let chart, !sculpted {
            return fabric(
                chart: chart, color: color, stitchWidth: stitchWidth, rowStep: rowStep,
                tileWidth: tileWidth, tileHeight: tileHeight, scale: scale, material: material)
        }
        return sculptedTile(
            chart: chart, color: color, stitch: stitch, material: material,
            columnCount: columnCount, rowCount: rowCount, stitchWidth: stitchWidth,
            stitchHeight: stitchHeight, rowStep: rowStep, yarnWidth: yarnWidth,
            tileWidth: tileWidth, tileHeight: tileHeight, scale: scale, sculpted: sculpted)
    }

    private static func fabric(
        chart: SweaterChart, color: UInt32, stitchWidth: Float, rowStep: Float,
        tileWidth: Int, tileHeight: Int, scale: Int, material: KnitGauge
    ) -> KnitTile? {
        let width = tileWidth * scale
        let height = tileHeight * scale
        let pixels = UnsafeMutablePointer<UInt32>.allocate(capacity: width * height)
        defer { pixels.deallocate() }

        let stitchScale: Float = chart.definedYarn ? 2 : 1
        let relief = min(
            chart.definedYarn ? Float(0.30) : Float(0.25),
            max(0, Float(material.relief) * (chart.definedYarn ? 0.32 : 0.20)))
        let scaled = Float(scale)
        let jitter = Float(material.jitter)
        let yarnRadius = max(Float(0.10), Float(material.yarn) * 0.5)
        let ground = Float(material.ground)
        let ambient = Float(material.ambient)
        let sheen = Float(material.sheen)

        for y in 0..<height {
            let sy = (Float(y) + 0.5) / (scaled * rowStep)
            let stitchY = sy / stitchScale
            let row = Int(stitchY.rounded(.down))
            let v = stitchY - Float(row)
            for x in 0..<width {
                let sx = (Float(x) + 0.5) / (scaled * stitchWidth)
                let column = Int(sx.rounded(.down))
                let stitchX = sx / stitchScale
                let yarnColumn = Int(stitchX.rounded(.down))
                let u = stitchX - Float(yarnColumn)

                let colorWarp: Float =
                    chart.roundDots ? 0 : 0.16 * (1 - 2 * abs(2 * u - 1))
                var colorRow = Int((sy + colorWarp).rounded(.down))
                colorRow = ((colorRow % (chart.height * 2)) + chart.height * 2) % (chart.height * 2)
                var yarn = chart.cell(row: colorRow / 2, column: column / 2)

                if chart.roundDots, (yarn >> 24) >= 128 {
                    let cx = (column / 2) % chart.width
                    let cy = colorRow / 2
                    let left = chart.cell(row: cy, column: cx - 1) == yarn
                    let above = chart.cell(row: cy - 1, column: cx) == yarn
                    let dx = sx * 0.5 - (sx * 0.5).rounded(.down) + (left ? 1 : 0) - 1
                    let dy = sy * 0.5 - (sy * 0.5).rounded(.down) + (above ? 1 : 0) - 1
                    if dx * dx + dy * dy > 0.94 { yarn = color }
                }
                if (yarn >> 24) < 128 { yarn = color }

                let seed = KnitMath.mix(
                    UInt32(truncatingIfNeeded: yarnColumn) &* 73_856_093
                        ^ UInt32(truncatingIfNeeded: row) &* 19_349_663)
                let wobble = (Float(seed & 255) / 255 - 0.5) * jitter
                let leg = 0.42 * (1 - v) + 0.08 * v * (1 - v)
                let distance = abs(abs(u - 0.5 - wobble) - leg)
                let ridge = max(0, 1 - distance * distance / (yarnRadius * yarnRadius))
                let grain = KnitMath.mix(
                    UInt32(truncatingIfNeeded: x) &* 73_856_093
                        ^ UInt32(truncatingIfNeeded: y) &* 19_349_663)
                let fibre = (Float(grain & 255) / 255 - 0.5) * 0.014
                let shade = max(
                    0,
                    ground - relief * (1 - ridge) + (ambient - 0.94)
                        + sheen * 0.08 * (0.5 - u) + fibre)

                let r = UInt32(min(255, Float((yarn >> 16) & 255) * shade))
                let g = UInt32(min(255, Float((yarn >> 8) & 255) * shade))
                let b = UInt32(min(255, Float(yarn & 255) * shade))
                pixels[(height - 1 - y) * width + x] = 0xff00_0000 | (r << 16) | (g << 8) | b
            }
        }

        guard let image = bitmapImage(pixels: pixels, width: width, height: height) else {
            return nil
        }
        return KnitTile(image: image, width: Double(tileWidth), height: Double(tileHeight))
    }

    private static func sculptedTile(
        chart: SweaterChart?, color: UInt32, stitch: SweaterStitch, material: KnitGauge,
        columnCount: Int, rowCount: Int, stitchWidth: Float, stitchHeight: Float,
        rowStep: Float, yarnWidth: Float, tileWidth: Int, tileHeight: Int, scale: Int,
        sculpted: Bool
    ) -> KnitTile? {
        var colors: [UInt32] = []
        var paths: [CGMutablePath] = []

        if sculpted {
            let bow = stitchWidth * 0.5 * Float(material.bow)
            for j in -2...(rowCount + 1) {
                for i in -2...(columnCount + 1) {
                    let cell = chart?.cell(row: j, column: i) ?? 0
                    let yarn = (cell >> 24) < 128 ? color : (cell | 0xff00_0000)
                    var slot = colors.firstIndex(of: yarn)
                    if slot == nil {
                        if colors.count == 16 { continue }
                        colors.append(yarn)
                        paths.append(CGMutablePath())
                        slot = colors.count - 1
                    }
                    guard let slot else { continue }
                    let x = Float(i) * stitchWidth
                    let y = Float(j) * rowStep
                    paths[slot].move(to: point(x, y))
                    paths[slot].addQuadCurve(
                        to: point(x + stitchWidth * 0.5, y + stitchHeight),
                        control: point(x + bow, y + stitchHeight * 0.55))
                    paths[slot].addQuadCurve(
                        to: point(x + stitchWidth, y),
                        control: point(x + stitchWidth - bow, y + stitchHeight * 0.55))
                }
            }
        } else {
            colors = [color]
            let path = CGMutablePath()
            lay(
                path: path, stitch: stitch, columnCount: columnCount, rowCount: rowCount,
                stitchWidth: stitchWidth, stitchHeight: stitchHeight, rowStep: rowStep,
                material: material)
            paths = [path]
        }
        guard !paths.isEmpty else { return nil }

        let width = tileWidth * scale
        let height = tileHeight * scale
        let gray = CGColorSpaceCreateDeviceGray()

        let flat = UnsafeMutablePointer<UInt32>.allocate(capacity: width * height)
        flat.initialize(repeating: 0, count: width * height)
        defer { flat.deallocate() }
        guard
            let flatContext = CGContext(
                data: flat, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: sRGB, bitmapInfo: bitmapInfo.rawValue)
        else { return nil }
        flatContext.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        let base = KnitMath.components(color)
        flatContext.setFillColor(
            red: base.r * material.ground, green: base.g * material.ground,
            blue: base.b * material.ground, alpha: 1)
        flatContext.fill(CGRect(x: 0, y: 0, width: tileWidth, height: tileHeight))
        flatContext.setLineCap(.round)
        flatContext.setLineJoin(.round)
        flatContext.setLineWidth(CGFloat(yarnWidth))
        for (index, path) in paths.enumerated() {
            let yarn = KnitMath.components(colors[index])
            flatContext.setStrokeColor(red: yarn.r, green: yarn.g, blue: yarn.b, alpha: 1)
            flatContext.addPath(path)
            flatContext.strokePath()
        }

        let heights = UnsafeMutablePointer<UInt8>.allocate(capacity: width * height)
        heights.initialize(repeating: 0, count: width * height)
        defer { heights.deallocate() }
        guard
            let heightContext = CGContext(
                data: heights, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width, space: gray, bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        heightContext.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        heightContext.setFillColor(gray: 0, alpha: 1)
        heightContext.fill(CGRect(x: 0, y: 0, width: tileWidth, height: tileHeight))
        heightContext.setLineCap(.round)
        heightContext.setLineJoin(.round)
        for path in paths { ridge(context: heightContext, path: path, yarn: yarnWidth) }

        var field = [Float](repeating: 0, count: width * height)
        for index in 0..<(width * height) { field[index] = Float(heights[index]) / 255 }
        var scratch = [Float](repeating: 0, count: width * height)
        blur(&field, width: width, height: height, scratch: &scratch)
        blur(&field, width: width, height: height, scratch: &scratch)

        let out = UnsafeMutablePointer<UInt32>.allocate(capacity: width * height)
        defer { out.deallocate() }
        let lightX: Float = -0.45, lightY: Float = -0.55, lightZ: Float = 0.70
        let relief = Float(scale) * Float(material.relief)
        let ambient = Float(material.ambient)
        let sheen = Float(material.sheen)

        for y in 0..<height {
            let up = (y - 1 + height) % height
            let down = (y + 1) % height
            for x in 0..<width {
                let left = (x - 1 + width) % width
                let right = (x + 1) % width
                let dzdx = (field[y * width + right] - field[y * width + left]) * relief
                let dzdy = (field[down * width + x] - field[up * width + x]) * relief
                let nx = -dzdx
                let ny = -dzdy
                let inverse = 1 / (nx * nx + ny * ny + 1).squareRoot()
                let ndl = max(0, (nx * lightX + ny * lightY + lightZ) * inverse)

                let peakHeight = field[y * width + x]
                let occlusion =
                    sculpted ? 0.74 + 0.26 * peakHeight : 0.86 + 0.14 * peakHeight
                let grain = KnitMath.mix(
                    UInt32(truncatingIfNeeded: x) &* 73_856_093
                        ^ UInt32(truncatingIfNeeded: y) &* 19_349_663)
                let fibre: Float =
                    sculpted ? 1 : 0.993 + Float(grain & 255) * (0.014 / 255)
                let shade = (ambient + sheen * ndl) * occlusion * fibre

                let pixel = flat[y * width + x]
                let red = Float((pixel >> 16) & 0xff)
                let green = Float((pixel >> 8) & 0xff)
                let blue = Float(pixel & 0xff)
                let peak = max(blue, max(green, red))
                let lift: Float = sculpted ? max(0, 1 - peak / 48) * peakHeight * 10 : 0
                let b = min(255, blue * shade + lift)
                let g = min(255, green * shade + lift)
                let r = min(255, red * shade + lift)
                out[y * width + x] =
                    0xff00_0000 | (UInt32(r) << 16) | (UInt32(g) << 8) | UInt32(b)
            }
        }

        guard let image = bitmapImage(pixels: out, width: width, height: height) else { return nil }
        return KnitTile(image: image, width: Double(tileWidth), height: Double(tileHeight))
    }

    private static func point(_ x: Float, _ y: Float) -> CGPoint {
        CGPoint(x: CGFloat(x), y: CGFloat(y))
    }

    private static func lay(
        path: CGMutablePath, stitch: SweaterStitch, columnCount: Int, rowCount: Int,
        stitchWidth: Float, stitchHeight: Float, rowStep: Float, material: KnitGauge
    ) {
        let bow = stitchWidth * 0.5 * Float(material.bow)
        let jitter = stitchWidth * Float(material.jitter)

        switch stitch {
        case .rib:
            let top = Float(rowCount + 4) * rowStep
            for i in -2...(columnCount + 1) {
                let x = Float(i) * stitchWidth + stitchWidth * 0.5
                let inset: Float = i & 1 == 1 ? stitchWidth * 0.16 : 0
                path.move(to: point(x + inset, -2 * rowStep))
                path.addLine(to: point(x + inset, top))
            }
        case .garter:
            for j in -2...(rowCount + 1) {
                let y = Float(j) * rowStep
                let phase: Float = j & 1 == 1 ? stitchWidth * 0.5 : 0
                path.move(to: point(-2 * stitchWidth, y))
                for i in -2...(columnCount + 1) {
                    let x = Float(i) * stitchWidth + phase
                    path.addQuadCurve(
                        to: point(x + stitchWidth * 0.5, y),
                        control: point(x + stitchWidth * 0.25, y - stitchHeight * 0.30))
                    path.addQuadCurve(
                        to: point(x + stitchWidth, y),
                        control: point(x + stitchWidth * 0.75, y + stitchHeight * 0.30))
                }
            }
        case .stockinette:
            for j in -2...(rowCount + 1) {
                let y = Float(j) * rowStep
                let jy = (KnitMath.noise((j + rowCount) % rowCount, 3) - 0.5) * jitter * 2
                path.move(to: point(-2 * stitchWidth, y + jy))
                for i in -2...(columnCount + 1) {
                    let x = Float(i) * stitchWidth
                    let wobble = KnitMath.noise(
                        (i + columnCount) % columnCount, (j + rowCount) % rowCount)
                    let jx = (wobble - 0.5) * jitter * 2
                    path.addQuadCurve(
                        to: point(x + stitchWidth * 0.5 + jx, y + stitchHeight + jy),
                        control: point(x + bow + jx, y + stitchHeight * 0.55 + jy))
                    path.addQuadCurve(
                        to: point(x + stitchWidth + jx, y + jy),
                        control: point(x + stitchWidth - bow + jx, y + stitchHeight * 0.55 + jy))
                }
            }
        }
    }

    private static func ridge(context: CGContext, path: CGPath, yarn: Float) {
        for layer in 0..<layerWidths.count {
            context.setStrokeColor(gray: CGFloat(layerHeights[layer]), alpha: 1)
            context.setLineWidth(CGFloat(yarn * layerWidths[layer]))
            context.addPath(path)
            context.strokePath()
        }
    }

    private static func blur(
        _ field: inout [Float], width: Int, height: Int, scratch: inout [Float]
    ) {
        for y in 0..<height {
            for x in 0..<width {
                let left = (x - 1 + width) % width
                let right = (x + 1) % width
                scratch[y * width + x] =
                    (field[y * width + left] + 2 * field[y * width + x] + field[y * width + right])
                    * 0.25
            }
        }
        for y in 0..<height {
            let up = (y - 1 + height) % height
            let down = (y + 1) % height
            for x in 0..<width {
                field[y * width + x] =
                    (scratch[up * width + x] + 2 * scratch[y * width + x]
                        + scratch[down * width + x]) * 0.25
            }
        }
    }

    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    static var bitmapInfo: CGBitmapInfo {
        CGBitmapInfo(
            rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGImageByteOrderInfo.order32Host.rawValue)
    }

    private static func bitmapImage(
        pixels: UnsafeMutablePointer<UInt32>, width: Int, height: Int
    ) -> CGImage? {
        guard
            let context = CGContext(
                data: pixels, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: sRGB,
                bitmapInfo: bitmapInfo.rawValue)
        else { return nil }
        return context.makeImage()
    }
}
