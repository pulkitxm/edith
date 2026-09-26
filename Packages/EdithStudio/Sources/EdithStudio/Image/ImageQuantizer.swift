import CoreGraphics
import Foundation

public struct QuantizedImage: Sendable {
    public let width: Int
    public let height: Int
    public let palette: [UInt32]
    public let indices: [UInt8]

    public var hasTransparency: Bool {
        palette.contains { $0 & 0xFF != 0xFF }
    }

    public func pngData() throws -> Data {
        try IndexedPNGEncoder.encode(self)
    }
}

public enum ImageQuantizer {
    struct Pixels {
        var values: [UInt8]
        let width: Int
        let height: Int
    }

    struct Box {
        var entries: ArraySlice<Entry>
        var weight: Int
        var ranges: (Int, Int, Int, Int)

        var score: Int {
            let spread = max(ranges.0, ranges.1, ranges.2, ranges.3)
            return spread * Int(Double(weight).squareRoot())
        }
    }

    struct Entry {
        var r: Int
        var g: Int
        var b: Int
        var a: Int
        var count: Int
    }

    public static func quantize(_ image: CGImage, colors: Int = 256, dither: Bool = true) throws
        -> QuantizedImage
    {
        let target = min(max(colors, 2), 256)
        let pixels = try rgba(image)
        if let exact = exactColors(pixels, limit: target) {
            let indices = mapExact(pixels, palette: exact)
            return QuantizedImage(
                width: pixels.width, height: pixels.height,
                palette: exact.map { pack($0.r, $0.g, $0.b, $0.a) }, indices: indices)
        }
        let palette = paletteColors(histogram(pixels), count: target)
        let indices = map(pixels, palette: palette, dither: dither)
        return QuantizedImage(
            width: pixels.width, height: pixels.height,
            palette: palette.map { pack($0.r, $0.g, $0.b, $0.a) }, indices: indices)
    }

    static func pack(_ r: Int, _ g: Int, _ b: Int, _ a: Int) -> UInt32 {
        UInt32(r) << 24 | UInt32(g) << 16 | UInt32(b) << 8 | UInt32(a)
    }

    static func rgba(_ image: CGImage) throws -> Pixels {
        let width = image.width
        let height = image.height
        var values = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = values.withUnsafeMutableBytes { raw -> Bool in
            guard
                let context = CGContext(
                    data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.clear(CGRect(x: 0, y: 0, width: width, height: height))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw StudioError.failed("Not enough memory to read the image.") }
        for index in stride(from: 0, to: values.count, by: 4) {
            let alpha = Int(values[index + 3])
            guard alpha > 0, alpha < 255 else {
                if alpha == 0 {
                    values[index] = 0
                    values[index + 1] = 0
                    values[index + 2] = 0
                }
                continue
            }
            for channel in 0..<3 {
                values[index + channel] = UInt8(
                    min(255, (Int(values[index + channel]) * 255 + alpha / 2) / alpha))
            }
        }
        return Pixels(values: values, width: width, height: height)
    }

    static func key(_ r: Int, _ g: Int, _ b: Int, _ a: Int) -> Int {
        (r >> 3) << 15 | (g >> 3) << 10 | (b >> 3) << 5 | (a >> 3)
    }

    static func exactColors(_ pixels: Pixels, limit: Int) -> [Entry]? {
        var seen: [UInt32: Int] = [:]
        let values = pixels.values
        for index in stride(from: 0, to: values.count, by: 4) {
            let color = pack(
                Int(values[index]), Int(values[index + 1]), Int(values[index + 2]),
                Int(values[index + 3]))
            seen[color, default: 0] += 1
            if seen.count > limit { return nil }
        }
        return seen.map { color, count in
            Entry(
                r: Int(color >> 24), g: Int((color >> 16) & 0xFF), b: Int((color >> 8) & 0xFF),
                a: Int(color & 0xFF), count: count)
        }
    }

    static func histogram(_ pixels: Pixels) -> [Entry] {
        let size = 1 << 20
        var counts = [Int](repeating: 0, count: size)
        var red = [Int](repeating: 0, count: size)
        var green = [Int](repeating: 0, count: size)
        var blue = [Int](repeating: 0, count: size)
        var alpha = [Int](repeating: 0, count: size)
        let values = pixels.values
        for index in stride(from: 0, to: values.count, by: 4) {
            let r = Int(values[index])
            let g = Int(values[index + 1])
            let b = Int(values[index + 2])
            let a = Int(values[index + 3])
            let k = key(r, g, b, a)
            counts[k] += 1
            red[k] += r
            green[k] += g
            blue[k] += b
            alpha[k] += a
        }
        var entries: [Entry] = []
        for k in 0..<size where counts[k] > 0 {
            let count = counts[k]
            entries.append(
                Entry(
                    r: red[k] / count, g: green[k] / count, b: blue[k] / count,
                    a: alpha[k] / count, count: count))
        }
        return entries
    }

    static func ranges(_ entries: ArraySlice<Entry>) -> (Int, Int, Int, Int) {
        var low = (255, 255, 255, 255)
        var high = (0, 0, 0, 0)
        for entry in entries {
            low = (
                min(low.0, entry.r), min(low.1, entry.g), min(low.2, entry.b), min(low.3, entry.a)
            )
            high = (
                max(high.0, entry.r), max(high.1, entry.g), max(high.2, entry.b),
                max(high.3, entry.a)
            )
        }
        return (high.0 - low.0, high.1 - low.1, high.2 - low.2, (high.3 - low.3) * 2)
    }

    static func makeBox(_ entries: ArraySlice<Entry>) -> Box {
        Box(entries: entries, weight: entries.reduce(0) { $0 + $1.count }, ranges: ranges(entries))
    }

    static func paletteColors(_ histogram: [Entry], count: Int) -> [Entry] {
        guard histogram.count > count else { return histogram }
        var boxes = [makeBox(histogram[...])]
        while boxes.count < count {
            guard
                let index = boxes.indices.filter({ boxes[$0].entries.count > 1 })
                    .max(by: { boxes[$0].score < boxes[$1].score })
            else { break }
            let box = boxes.remove(at: index)
            let ranges = box.ranges
            let widest = max(ranges.0, ranges.1, ranges.2, ranges.3)
            var sorted = Array(box.entries)
            switch widest {
            case ranges.0: sorted.sort { $0.r < $1.r }
            case ranges.1: sorted.sort { $0.g < $1.g }
            case ranges.2: sorted.sort { $0.b < $1.b }
            default: sorted.sort { $0.a < $1.a }
            }
            let half = box.weight / 2
            var running = 0
            var split = 1
            for (offset, entry) in sorted.enumerated() {
                running += entry.count
                if running >= half {
                    split = min(max(offset + 1, 1), sorted.count - 1)
                    break
                }
            }
            boxes.append(makeBox(sorted[0..<split]))
            boxes.append(makeBox(sorted[split..<sorted.count]))
        }
        return boxes.map { box in
            var totals = (0, 0, 0, 0)
            for entry in box.entries {
                totals.0 += entry.r * entry.count
                totals.1 += entry.g * entry.count
                totals.2 += entry.b * entry.count
                totals.3 += entry.a * entry.count
            }
            let weight = max(box.weight, 1)
            let alpha = totals.3 / weight
            return Entry(
                r: totals.0 / weight, g: totals.1 / weight, b: totals.2 / weight,
                a: alpha >= 250 ? 255 : (alpha <= 4 ? 0 : alpha), count: box.weight)
        }
    }

    static func nearest(_ r: Int, _ g: Int, _ b: Int, _ a: Int, palette: [Entry]) -> Int {
        var best = 0
        var bestDistance = Int.max
        for (index, color) in palette.enumerated() {
            let dr = color.r - r
            let dg = color.g - g
            let db = color.b - b
            let da = color.a - a
            let distance = dr * dr * 3 + dg * dg * 4 + db * db * 2 + da * da * 6
            if distance < bestDistance {
                bestDistance = distance
                best = index
                if distance == 0 { break }
            }
        }
        return best
    }

    static func map(_ pixels: Pixels, palette: [Entry], dither: Bool) -> [UInt8] {
        let width = pixels.width
        let height = pixels.height
        var cache = [Int16](repeating: -1, count: 1 << 20)
        func lookup(_ r: Int, _ g: Int, _ b: Int, _ a: Int) -> Int {
            let k = key(r, g, b, a)
            let cached = cache[k]
            if cached >= 0 { return Int(cached) }
            let found = nearest(r, g, b, a, palette: palette)
            cache[k] = Int16(found)
            return found
        }
        var indices = [UInt8](repeating: 0, count: width * height)
        let values = pixels.values
        guard dither else {
            for pixel in 0..<(width * height) {
                let offset = pixel * 4
                indices[pixel] = UInt8(
                    lookup(
                        Int(values[offset]), Int(values[offset + 1]), Int(values[offset + 2]),
                        Int(values[offset + 3])))
            }
            return indices
        }
        var current = [Int](repeating: 0, count: (width + 2) * 3)
        var next = [Int](repeating: 0, count: (width + 2) * 3)
        for row in 0..<height {
            for column in 0..<width {
                let pixel = row * width + column
                let offset = pixel * 4
                let alpha = Int(values[offset + 3])
                let slot = (column + 1) * 3
                let r = clamp(Int(values[offset]) + current[slot] / 16)
                let g = clamp(Int(values[offset + 1]) + current[slot + 1] / 16)
                let b = clamp(Int(values[offset + 2]) + current[slot + 2] / 16)
                let chosen = lookup(r, g, b, alpha)
                indices[pixel] = UInt8(chosen)
                guard alpha > 0 else { continue }
                let color = palette[chosen]
                let errors = [r - color.r, g - color.g, b - color.b]
                for channel in 0..<3 {
                    let error = errors[channel]
                    current[slot + 3 + channel] += error * 7
                    next[slot - 3 + channel] += error * 3
                    next[slot + channel] += error * 5
                    next[slot + 3 + channel] += error
                }
            }
            swap(&current, &next)
            for index in next.indices { next[index] = 0 }
        }
        return indices
    }

    static func mapExact(_ pixels: Pixels, palette: [Entry]) -> [UInt8] {
        var lookup: [UInt32: UInt8] = [:]
        for (index, color) in palette.enumerated() {
            lookup[pack(color.r, color.g, color.b, color.a)] = UInt8(index)
        }
        let values = pixels.values
        var indices = [UInt8](repeating: 0, count: pixels.width * pixels.height)
        for pixel in indices.indices {
            let offset = pixel * 4
            let color = pack(
                Int(values[offset]), Int(values[offset + 1]), Int(values[offset + 2]),
                Int(values[offset + 3]))
            indices[pixel] = lookup[color] ?? 0
        }
        return indices
    }

    static func clamp(_ value: Int) -> Int {
        min(max(value, 0), 255)
    }
}

enum IndexedPNGEncoder {
    static func encode(_ image: QuantizedImage) throws -> Data {
        var data = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        var header = Data()
        header.append(bigEndian: UInt32(image.width))
        header.append(bigEndian: UInt32(image.height))
        header.append(contentsOf: [8, 3, 0, 0, 0])
        chunk("IHDR", header, into: &data)
        var palette = Data()
        var alphas = Data()
        for color in image.palette {
            palette.append(UInt8((color >> 24) & 0xFF))
            palette.append(UInt8((color >> 16) & 0xFF))
            palette.append(UInt8((color >> 8) & 0xFF))
            alphas.append(UInt8(color & 0xFF))
        }
        chunk("PLTE", palette, into: &data)
        if image.hasTransparency {
            while let last = alphas.last, last == 0xFF { alphas.removeLast() }
            chunk("tRNS", alphas, into: &data)
        }
        var raw = Data(capacity: (image.width + 1) * image.height)
        image.indices.withUnsafeBufferPointer { buffer in
            for row in 0..<image.height {
                raw.append(0)
                let start = row * image.width
                raw.append(buffer.baseAddress! + start, count: image.width)
            }
        }
        chunk("IDAT", try zlib(raw), into: &data)
        chunk("IEND", Data(), into: &data)
        return data
    }

    static func zlib(_ raw: Data) throws -> Data {
        guard let deflated = try? (raw as NSData).compressed(using: .zlib) as Data else {
            throw StudioError.failed("The PNG could not be compressed.")
        }
        var output = Data([0x78, 0xDA])
        output.append(deflated)
        output.append(bigEndian: adler32(raw))
        return output
    }

    static func chunk(_ type: String, _ payload: Data, into data: inout Data) {
        data.append(bigEndian: UInt32(payload.count))
        let typeData = Data(type.utf8)
        data.append(typeData)
        data.append(payload)
        data.append(bigEndian: CRC32.checksum(typeData + payload))
    }

    static func adler32(_ data: Data) -> UInt32 {
        var a: UInt32 = 1
        var b: UInt32 = 0
        data.withUnsafeBytes { buffer in
            var index = 0
            let count = buffer.count
            while index < count {
                let end = min(index + 5552, count)
                while index < end {
                    a += UInt32(buffer[index])
                    b += a
                    index += 1
                }
                a %= 65521
                b %= 65521
            }
        }
        return b << 16 | a
    }
}

enum CRC32 {
    static let table: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 {
            crc = crc & 1 == 1 ? 0xEDB8_8320 ^ (crc >> 1) : crc >> 1
        }
        return crc
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}

extension Data {
    mutating func append(bigEndian value: UInt32) {
        append(contentsOf: [
            UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF),
        ])
    }
}
