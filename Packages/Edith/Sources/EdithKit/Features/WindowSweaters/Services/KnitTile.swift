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
    static let layerWidths: [Double] = [1.00, 0.80, 0.60, 0.40, 0.20]
    static let layerHeights: [Double] = [0.22, 0.48, 0.70, 0.88, 1.00]

    static func make(
        band: Double, color: UInt32, chart: SweaterChart?, key: KnitChartKey,
        stitch: SweaterStitch, gauge: KnitGauge
    ) -> KnitTile? {
        let isPatch = key == .patch
        let sculpted = isPatch || (chart?.sculptedYarn ?? false)
        let material = sculpted ? gauge.sculpted : gauge
        let chart = isPatch ? nil : chart

        let rows = max(material.rows, 1.5)
        var rowStep = band / rows
        var stitchWidth = rowStep * material.aspect

        var columnCount: Int
        var rowCount: Int
        if let chart {
            let density = sculpted ? 1.0 : 2.0
            stitchWidth /= density
            rowStep /= density
            columnCount = Int(Double(chart.width) * density)
            rowCount = Int(Double(chart.height) * density)
            columnCount *= Int(max(1, ceil(8 / (stitchWidth * Double(columnCount)))))
            rowCount *= Int(max(1, ceil(8 / (rowStep * Double(rowCount)))))
        } else {
            columnCount = 8
            rowCount = 8
        }

        let tileWidth = max(8, Int((stitchWidth * Double(columnCount)).rounded()))
        let tileHeight = max(8, Int((rowStep * Double(rowCount)).rounded()))
        stitchWidth = Double(tileWidth) / Double(columnCount)
        rowStep = Double(tileHeight) / Double(rowCount)
        let stitchHeight = rowStep / (1 - material.rowOverlap)

        var yarnWidth = max(stitchWidth * material.yarn, sculpted ? 0.8 : 0.35)
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
        chart: SweaterChart, color: UInt32, stitchWidth: Double, rowStep: Double,
        tileWidth: Int, tileHeight: Int, scale: Int, material: KnitGauge
    ) -> KnitTile? {
        let width = tileWidth * scale
        let height = tileHeight * scale
        let pixels = UnsafeMutablePointer<UInt32>.allocate(capacity: width * height)
        defer { pixels.deallocate() }

        let stitchScale = chart.definedYarn ? 2.0 : 1.0
        let relief = min(
            chart.definedYarn ? 0.30 : 0.25,
            max(0, material.relief * (chart.definedYarn ? 0.32 : 0.20)))
        let scaled = Double(scale)

        for y in 0..<height {
            let sy = (Double(y) + 0.5) / (scaled * rowStep)
            let stitchY = sy / stitchScale
            let row = Int(floor(stitchY))
            let v = stitchY - Double(row)
            for x in 0..<width {
                let sx = (Double(x) + 0.5) / (scaled * stitchWidth)
                let column = Int(floor(sx))
                let stitchX = sx / stitchScale
                let yarnColumn = Int(floor(stitchX))
                let u = stitchX - Double(yarnColumn)

                let colorWarp =
                    chart.roundDots ? 0 : 0.16 * (1 - 2 * abs(2 * u - 1))
                var colorRow = Int(floor(sy + colorWarp))
                colorRow = ((colorRow % (chart.height * 2)) + chart.height * 2) % (chart.height * 2)
                var yarn = chart.cell(row: colorRow / 2, column: column / 2)

                if chart.roundDots, (yarn >> 24) >= 128 {
                    let cx = (column / 2) % chart.width
                    let cy = colorRow / 2
                    let left = chart.cell(row: cy, column: cx - 1) == yarn
                    let above = chart.cell(row: cy - 1, column: cx) == yarn
                    let dx = sx * 0.5 - floor(sx * 0.5) + (left ? 1 : 0) - 1
                    let dy = sy * 0.5 - floor(sy * 0.5) + (above ? 1 : 0) - 1
                    if dx * dx + dy * dy > 0.94 { yarn = color }
                }
                if (yarn >> 24) < 128 { yarn = color }

                let seed = KnitMath.mix(
                    UInt32(truncatingIfNeeded: yarnColumn) &* 73_856_093
                        ^ UInt32(truncatingIfNeeded: row) &* 19_349_663)
                let wobble = (Double(seed & 255) / 255 - 0.5) * material.jitter
                let leg = 0.42 * (1 - v) + 0.08 * v * (1 - v)
                let distance = abs(abs(u - 0.5 - wobble) - leg)
                let radius = max(0.10, material.yarn * 0.5)
                let ridge = max(0, 1 - distance * distance / (radius * radius))
                let grain = KnitMath.mix(
                    UInt32(truncatingIfNeeded: x) &* 73_856_093
                        ^ UInt32(truncatingIfNeeded: y) &* 19_349_663)
                let fibre = (Double(grain & 255) / 255 - 0.5) * 0.014
                let shade = max(
                    0,
                    material.ground - relief * (1 - ridge) + (material.ambient - 0.94)
                        + material.sheen * 0.08 * (0.5 - u) + fibre)

                let r = UInt32(min(255, Double((yarn >> 16) & 255) * shade))
                let g = UInt32(min(255, Double((yarn >> 8) & 255) * shade))
                let b = UInt32(min(255, Double(yarn & 255) * shade))
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
        columnCount: Int, rowCount: Int, stitchWidth: Double, stitchHeight: Double,
        rowStep: Double, yarnWidth: Double, tileWidth: Int, tileHeight: Int, scale: Int,
        sculpted: Bool
    ) -> KnitTile? {
        var colors: [UInt32] = []
        var paths: [CGMutablePath] = []

        if sculpted {
            let bow = stitchWidth * 0.5 * material.bow
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
                    let x = Double(i) * stitchWidth
                    let y = Double(j) * rowStep
                    paths[slot].move(to: CGPoint(x: x, y: y))
                    paths[slot].addQuadCurve(
                        to: CGPoint(x: x + stitchWidth * 0.5, y: y + stitchHeight),
                        control: CGPoint(x: x + bow, y: y + stitchHeight * 0.55))
                    paths[slot].addQuadCurve(
                        to: CGPoint(x: x + stitchWidth, y: y),
                        control: CGPoint(x: x + stitchWidth - bow, y: y + stitchHeight * 0.55))
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
                bytesPerRow: width * 4, space: Self.sRGB,
                bitmapInfo: bitmapInfo.rawValue)
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
                bytesPerRow: width, space: gray,
                bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        heightContext.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        heightContext.setFillColor(gray: 0, alpha: 1)
        heightContext.fill(CGRect(x: 0, y: 0, width: tileWidth, height: tileHeight))
        heightContext.setLineCap(.round)
        heightContext.setLineJoin(.round)
        for path in paths { ridge(context: heightContext, path: path, yarn: yarnWidth) }

        var field = [Double](repeating: 0, count: width * height)
        for index in 0..<(width * height) { field[index] = Double(heights[index]) / 255 }
        var scratch = [Double](repeating: 0, count: width * height)
        blur(&field, width: width, height: height, scratch: &scratch)
        blur(&field, width: width, height: height, scratch: &scratch)

        let out = UnsafeMutablePointer<UInt32>.allocate(capacity: width * height)
        defer { out.deallocate() }
        let lightX = -0.45, lightY = -0.55, lightZ = 0.70
        let relief = Double(scale) * material.relief

        for y in 0..<height {
            let up = (y - 1 + height) % height
            let down = (y + 1) % height
            for x in 0..<width {
                let left = (x - 1 + width) % width
                let right = (x + 1) % width
                let dzdx = (field[y * width + right] - field[y * width + left]) * relief
                let dzdy = (field[down * width + x] - field[up * width + x]) * relief
                let nx = -dzdx, ny = -dzdy
                let inverse = 1 / (nx * nx + ny * ny + 1).squareRoot()
                let ndl = max(0, (nx * lightX + ny * lightY + lightZ) * inverse)

                let occlusion =
                    sculpted
                    ? 0.74 + 0.26 * field[y * width + x] : 0.86 + 0.14 * field[y * width + x]
                let grain = KnitMath.mix(
                    UInt32(truncatingIfNeeded: x) &* 73_856_093
                        ^ UInt32(truncatingIfNeeded: y) &* 19_349_663)
                let fibre = sculpted ? 1 : 0.993 + Double(grain & 255) * (0.014 / 255)
                let shade = (material.ambient + material.sheen * ndl) * occlusion * fibre

                let pixel = flat[y * width + x]
                let peak = Double(max(pixel & 255, max((pixel >> 8) & 255, (pixel >> 16) & 255)))
                let lift = sculpted ? max(0, 1 - peak / 48) * field[y * width + x] * 10 : 0
                let b = min(255, Double(pixel & 0xff) * shade + lift)
                let g = min(255, Double((pixel >> 8) & 0xff) * shade + lift)
                let r = min(255, Double((pixel >> 16) & 0xff) * shade + lift)
                out[y * width + x] =
                    0xff00_0000 | (UInt32(r) << 16) | (UInt32(g) << 8) | UInt32(b)
            }
        }

        guard let image = bitmapImage(pixels: out, width: width, height: height) else { return nil }
        return KnitTile(image: image, width: Double(tileWidth), height: Double(tileHeight))
    }

    private static func lay(
        path: CGMutablePath, stitch: SweaterStitch, columnCount: Int, rowCount: Int,
        stitchWidth: Double, stitchHeight: Double, rowStep: Double, material: KnitGauge
    ) {
        let bow = stitchWidth * 0.5 * material.bow
        let jitter = stitchWidth * material.jitter

        switch stitch {
        case .rib:
            let top = Double(rowCount + 4) * rowStep
            for i in -2...(columnCount + 1) {
                let x = Double(i) * stitchWidth + stitchWidth * 0.5
                let inset = i & 1 == 1 ? stitchWidth * 0.16 : 0
                path.move(to: CGPoint(x: x + inset, y: -2 * rowStep))
                path.addLine(to: CGPoint(x: x + inset, y: top))
            }
        case .garter:
            for j in -2...(rowCount + 1) {
                let y = Double(j) * rowStep
                let phase = j & 1 == 1 ? stitchWidth * 0.5 : 0
                path.move(to: CGPoint(x: -2 * stitchWidth, y: y))
                for i in -2...(columnCount + 1) {
                    let x = Double(i) * stitchWidth + phase
                    path.addQuadCurve(
                        to: CGPoint(x: x + stitchWidth * 0.5, y: y),
                        control: CGPoint(x: x + stitchWidth * 0.25, y: y - stitchHeight * 0.30))
                    path.addQuadCurve(
                        to: CGPoint(x: x + stitchWidth, y: y),
                        control: CGPoint(x: x + stitchWidth * 0.75, y: y + stitchHeight * 0.30))
                }
            }
        case .stockinette:
            for j in -2...(rowCount + 1) {
                let y = Double(j) * rowStep
                let jy =
                    (KnitMath.noise(((j + rowCount) % rowCount), 3) - 0.5) * jitter * 2
                path.move(to: CGPoint(x: -2 * stitchWidth, y: y + jy))
                for i in -2...(columnCount + 1) {
                    let x = Double(i) * stitchWidth
                    let jx =
                        (KnitMath.noise(
                            ((i + columnCount) % columnCount), ((j + rowCount) % rowCount)) - 0.5)
                        * jitter * 2
                    path.addQuadCurve(
                        to: CGPoint(x: x + stitchWidth * 0.5 + jx, y: y + stitchHeight + jy),
                        control: CGPoint(x: x + bow + jx, y: y + stitchHeight * 0.55 + jy))
                    path.addQuadCurve(
                        to: CGPoint(x: x + stitchWidth + jx, y: y + jy),
                        control: CGPoint(
                            x: x + stitchWidth - bow + jx, y: y + stitchHeight * 0.55 + jy))
                }
            }
        }
    }

    private static func ridge(context: CGContext, path: CGPath, yarn: Double) {
        for layer in 0..<layerWidths.count {
            context.setStrokeColor(gray: CGFloat(layerHeights[layer]), alpha: 1)
            context.setLineWidth(CGFloat(yarn * layerWidths[layer]))
            context.addPath(path)
            context.strokePath()
        }
    }

    private static func blur(
        _ field: inout [Double], width: Int, height: Int, scratch: inout [Double]
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
