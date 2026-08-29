import AppKit
import Foundation

public enum CaptureEditTool: String, CaseIterable, Codable, Sendable {
    case crop
    case pen
    case arrow
    case rectangle
    case ellipse
    case text
    case redact

    public var displayName: String {
        rawValue.capitalized
    }

    public var systemImage: String {
        switch self {
        case .crop: "crop"
        case .pen: "pencil.tip"
        case .arrow: "arrow.up.right"
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .text: "textformat"
        case .redact: "eye.slash"
        }
    }
}

public enum CaptureBackdrop: String, CaseIterable, Codable, Sendable {
    case none
    case light
    case dark
    case gradient

    public var displayName: String { rawValue.capitalized }
}

public struct CaptureAnnotation: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let tool: CaptureEditTool
    public let points: [CGPoint]
    public let text: String
    public let colorHex: String
    public let strokeWidth: CGFloat

    public init(
        id: UUID = UUID(), tool: CaptureEditTool, points: [CGPoint], text: String = "",
        colorHex: String = "#FF453A", strokeWidth: CGFloat = 5
    ) {
        self.id = id
        self.tool = tool
        self.points = points
        self.text = text
        self.colorHex = colorHex
        self.strokeWidth = strokeWidth
    }

    public var rect: CGRect {
        guard let first = points.first else { return .zero }
        return points.dropFirst().reduce(CGRect(origin: first, size: .zero)) {
            $0.union(CGRect(origin: $1, size: .zero))
        }.standardized
    }
}

public struct CaptureEditDocument: Codable, Equatable, Sendable {
    public var cropRect: CGRect?
    public var annotations: [CaptureAnnotation]
    public var backdrop: CaptureBackdrop

    public init(
        cropRect: CGRect? = nil, annotations: [CaptureAnnotation] = [],
        backdrop: CaptureBackdrop = .none
    ) {
        self.cropRect = cropRect
        self.annotations = annotations
        self.backdrop = backdrop
    }
}

public enum CaptureRenderer {
    public static func pngData(
        baseImage: CGImage, document: CaptureEditDocument
    ) throws -> Data {
        let image = try render(baseImage: baseImage, document: document)
        let representation = NSBitmapImageRep(cgImage: image)
        guard let data = representation.representation(using: .png, properties: [:]) else {
            throw CaptureScreenshotError.saveFailed
        }
        return data
    }

    public static func render(
        baseImage: CGImage, document: CaptureEditDocument
    ) throws -> CGImage {
        let bounds = CGRect(x: 0, y: 0, width: baseImage.width, height: baseImage.height)
        let requested = document.cropRect?.standardized.intersection(bounds) ?? bounds
        let crop = requested.width >= 2 && requested.height >= 2 ? requested.integral : bounds
        let padding =
            document.backdrop == .none
            ? 0 : min(120, max(36, min(crop.width, crop.height) * 0.08))
        let outputSize = CGSize(width: crop.width + padding * 2, height: crop.height + padding * 2)
        let image = NSImage(size: outputSize, flipped: true) { destination in
            drawBackdrop(document.backdrop, in: destination)
            let imageRect = destination.insetBy(dx: padding, dy: padding)
            if document.backdrop != .none {
                NSGraphicsContext.current?.cgContext.setShadow(
                    offset: CGSize(width: 0, height: 10), blur: 24,
                    color: NSColor.black.withAlphaComponent(0.3).cgColor)
            }
            NSGraphicsContext.current?.cgContext.saveGState()
            NSBezierPath(
                roundedRect: imageRect, xRadius: padding > 0 ? 14 : 0, yRadius: padding > 0 ? 14 : 0
            ).addClip()
            NSImage(cgImage: baseImage, size: bounds.size).draw(
                in: imageRect, from: crop, operation: .copy, fraction: 1)
            NSGraphicsContext.current?.cgContext.restoreGState()
            for annotation in document.annotations {
                draw(
                    annotation, crop: crop,
                    offset: CGPoint(x: padding - crop.minX, y: padding - crop.minY),
                    clip: imageRect)
            }
            return true
        }
        guard let rendered = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw CaptureScreenshotError.saveFailed
        }
        return rendered
    }

    private static func drawBackdrop(_ backdrop: CaptureBackdrop, in rect: CGRect) {
        switch backdrop {
        case .none:
            NSColor.clear.setFill()
            rect.fill()
        case .light:
            NSColor(calibratedWhite: 0.95, alpha: 1).setFill()
            rect.fill()
        case .dark:
            NSColor(calibratedWhite: 0.08, alpha: 1).setFill()
            rect.fill()
        case .gradient:
            NSGradient(colors: [
                NSColor(srgbRed: 0.33, green: 0.22, blue: 0.86, alpha: 1),
                NSColor(srgbRed: 0.95, green: 0.35, blue: 0.51, alpha: 1),
            ])?.draw(in: rect, angle: -35)
        }
    }

    private static func draw(
        _ annotation: CaptureAnnotation, crop: CGRect, offset: CGPoint, clip: CGRect
    ) {
        guard !annotation.points.isEmpty, annotation.rect.intersects(crop) else { return }
        let color = NSColor(captureHex: annotation.colorHex)
        let points = annotation.points.map { CGPoint(x: $0.x + offset.x, y: $0.y + offset.y) }
        let rect = CaptureAnnotation(
            tool: annotation.tool, points: points, text: annotation.text,
            colorHex: annotation.colorHex, strokeWidth: annotation.strokeWidth
        ).rect
        NSGraphicsContext.current?.cgContext.saveGState()
        NSBezierPath(rect: clip).addClip()
        color.setStroke()
        color.setFill()
        switch annotation.tool {
        case .crop:
            break
        case .pen:
            let path = NSBezierPath()
            path.lineWidth = annotation.strokeWidth
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.move(to: points[0])
            points.dropFirst().forEach(path.line(to:))
            path.stroke()
        case .arrow:
            guard let start = points.first, let end = points.last else { break }
            let path = NSBezierPath()
            path.lineWidth = annotation.strokeWidth
            path.lineCapStyle = .round
            path.move(to: start)
            path.line(to: end)
            let angle = atan2(end.y - start.y, end.x - start.x)
            let head = max(14, annotation.strokeWidth * 4)
            path.move(to: end)
            path.line(
                to: CGPoint(
                    x: end.x - head * cos(angle - .pi / 6),
                    y: end.y - head * sin(angle - .pi / 6)))
            path.move(to: end)
            path.line(
                to: CGPoint(
                    x: end.x - head * cos(angle + .pi / 6),
                    y: end.y - head * sin(angle + .pi / 6)))
            path.stroke()
        case .rectangle:
            let path = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
            path.lineWidth = annotation.strokeWidth
            path.stroke()
        case .ellipse:
            let path = NSBezierPath(ovalIn: rect)
            path.lineWidth = annotation.strokeWidth
            path.stroke()
        case .text:
            annotation.text.draw(
                in: rect.width < 20 || rect.height < 20
                    ? CGRect(x: points[0].x, y: points[0].y, width: 320, height: 80) : rect,
                withAttributes: [
                    .font: NSFont.systemFont(
                        ofSize: max(18, annotation.strokeWidth * 5), weight: .semibold),
                    .foregroundColor: color,
                ])
        case .redact:
            NSColor.black.setFill()
            rect.fill()
        }
        NSGraphicsContext.current?.cgContext.restoreGState()
    }
}

private extension NSColor {
    convenience init(captureHex value: String) {
        let hex = value.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        let number = UInt64(hex, radix: 16) ?? 0xFF453A
        let red = CGFloat((number >> 16) & 0xff) / 255
        let green = CGFloat((number >> 8) & 0xff) / 255
        let blue = CGFloat(number & 0xff) / 255
        self.init(srgbRed: red, green: green, blue: blue, alpha: 1)
    }
}
