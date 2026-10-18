import AppKit
import CoreGraphics
import CoreText
import Foundation

enum MediaGraphics {
    static func canvas(width: Int, height: Int) throws -> CGContext {
        guard let context = StudioImageOps.context(width: width, height: height) else {
            throw StudioError.failed("Not enough memory to draw the overlay.")
        }
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        return context
    }

    static func writePNG(_ context: CGContext, to url: URL) throws {
        guard let image = context.makeImage() else {
            throw StudioError.failed("The overlay could not be drawn.")
        }
        try StudioImageIO.write(image, to: url, format: .png)
    }

    static func stampOverlay(_ stamp: StudioStamp, width: Int, height: Int, to url: URL) throws {
        let context = try canvas(width: width, height: height)
        stamp.draw(in: context, size: CGSize(width: width, height: height))
        try writePNG(context, to: url)
    }

    static func slide(
        _ source: URL, width: Int, height: Int, fill: Bool, background: StudioColor, to url: URL
    ) throws {
        let image = try StudioImageIO.load(source, maxPixelSize: max(width, height) * 2)
        let context = try canvas(width: width, height: height)
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(background.cgColor)
        context.fill(bounds)
        let scaleX = Double(width) / Double(image.width)
        let scaleY = Double(height) / Double(image.height)
        let scale = fill ? max(scaleX, scaleY) : min(scaleX, scaleY)
        let size = CGSize(width: Double(image.width) * scale, height: Double(image.height) * scale)
        context.interpolationQuality = .high
        context.draw(
            image,
            in: CGRect(
                x: (Double(width) - size.width) / 2, y: (Double(height) - size.height) / 2,
                width: size.width, height: size.height))
        try writePNG(context, to: url)
    }

    struct CaptionStyle {
        var fontSize: Double
        var color: StudioColor
        var box: Bool
        var top: Bool
    }

    static func caption(
        _ text: String, width: Int, height: Int, style: CaptionStyle, to url: URL
    ) throws {
        let context = try canvas(width: width, height: height)
        if !text.isEmpty {
            let font = StudioStamp.font(named: "Helvetica Neue", size: style.fontSize, bold: true)
            let margin = Double(width) * 0.06
            let available = Double(width) - margin * 2
            let size = StudioText.fittingSize(text, font: font, width: available)
            let textWidth = min(available, ceil(size.width) + 2)
            let textHeight = ceil(size.height) + 2
            let inset = Double(height) * 0.06
            let y = style.top ? Double(height) - inset - textHeight : inset
            let frame = CGRect(
                x: (Double(width) - textWidth) / 2, y: y, width: textWidth, height: textHeight)
            if style.box {
                let pad = style.fontSize * 0.35
                let box = frame.insetBy(dx: -pad, dy: -pad * 0.6)
                context.setFillColor(CGColor(gray: 0, alpha: 0.6))
                context.addPath(
                    CGPath(
                        roundedRect: box, cornerWidth: pad * 0.6, cornerHeight: pad * 0.6,
                        transform: nil))
                context.fillPath()
            }
            StudioText.draw(
                text, in: frame, context: context, font: font, color: style.color,
                stroke: style.box ? nil : .black, strokeWidth: style.box ? 0 : 3)
        }
        try writePNG(context, to: url)
    }
}

public struct SubtitleCue: Equatable, Sendable {
    public var start: Double
    public var end: Double
    public var text: String
}

public enum SubtitleParser {
    public static func parse(_ raw: String) -> [SubtitleCue] {
        let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{FEFF}", with: "")
        var cues: [SubtitleCue] = []
        for block in normalized.components(separatedBy: "\n\n") {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: true).map(
                String.init)
            guard let timingIndex = lines.firstIndex(where: { $0.contains("-->") }) else {
                continue
            }
            let parts = lines[timingIndex].components(separatedBy: "-->")
            guard parts.count == 2, let start = time(parts[0]),
                let end = time(parts[1].split(separator: " ").first.map(String.init) ?? "")
            else { continue }
            let text = lines[(timingIndex + 1)...].map(clean).filter { !$0.isEmpty }
                .joined(separator: "\n")
            guard end > start, !text.isEmpty else { continue }
            cues.append(SubtitleCue(start: start, end: end, text: text))
        }
        return cues.sorted { $0.start < $1.start }
    }

    static func time(_ raw: String) -> Double? {
        let text = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard !text.isEmpty else { return nil }
        return StudioTime.parse(text)
    }

    static func clean(_ line: String) -> String {
        var text = line
        for pattern in [#"<[^>]+>"#, #"\{\\[^}]*\}"#] {
            text = text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        return text.trimmingCharacters(in: .whitespaces)
    }

    public static func timeline(_ cues: [SubtitleCue], duration: Double) -> [(
        start: Double, end: Double, text: String
    )] {
        var boundaries = Set<Double>([0, duration])
        for cue in cues where cue.start < duration {
            boundaries.insert(max(0, cue.start))
            boundaries.insert(min(duration, cue.end))
        }
        let sorted = boundaries.sorted()
        var segments: [(start: Double, end: Double, text: String)] = []
        for (start, end) in zip(sorted, sorted.dropFirst()) where end - start > 0.0005 {
            let active = cues.filter { $0.start <= start + 0.0001 && $0.end >= end - 0.0001 }
            let text = active.map(\.text).joined(separator: "\n")
            if let last = segments.last, last.text == text {
                segments[segments.count - 1].end = end
            } else {
                segments.append((start, end, text))
            }
        }
        return segments
    }
}
