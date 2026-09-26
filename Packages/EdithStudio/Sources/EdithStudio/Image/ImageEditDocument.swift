import CoreGraphics
import Foundation

public struct ImagePoint: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public init(_ point: CGPoint) {
        self.init(x: Double(point.x), y: Double(point.y))
    }

    public var cgPoint: CGPoint { CGPoint(x: x, y: y) }
}

public enum ImageFilterPreset: String, CaseIterable, Codable, Sendable {
    case none, mono, noir, chrome, fade, instant, process, tonal, transfer, sepia, vivid, warm,
        cool, vintage

    public var title: String {
        switch self {
        case .none: "Original"
        case .mono: "Mono"
        case .noir: "Noir"
        case .chrome: "Chrome"
        case .fade: "Fade"
        case .instant: "Instant"
        case .process: "Process"
        case .tonal: "Tonal"
        case .transfer: "Transfer"
        case .sepia: "Sepia"
        case .vivid: "Vivid"
        case .warm: "Warm"
        case .cool: "Cool"
        case .vintage: "Vintage"
        }
    }

    public static var choices: [StudioChoice] {
        allCases.map { StudioChoice($0.rawValue, $0.title) }
    }
}

public struct ImageAdjustments: Codable, Equatable, Sendable {
    public enum Key: String, CaseIterable, Codable, Sendable {
        case exposure, brightness, contrast, saturation, vibrance, warmth, tint, highlights,
            shadows, sharpness, vignette, grain

        public var title: String {
            switch self {
            case .exposure: "Exposure"
            case .brightness: "Brightness"
            case .contrast: "Contrast"
            case .saturation: "Saturation"
            case .vibrance: "Vibrance"
            case .warmth: "Warmth"
            case .tint: "Tint"
            case .highlights: "Highlights"
            case .shadows: "Shadows"
            case .sharpness: "Sharpness"
            case .vignette: "Vignette"
            case .grain: "Grain"
            }
        }

        public var range: ClosedRange<Double> {
            switch self {
            case .sharpness, .vignette, .grain: 0...1
            default: -1...1
            }
        }

        public var symbolName: String {
            switch self {
            case .exposure: "plusminus.circle"
            case .brightness: "sun.max"
            case .contrast: "circle.lefthalf.filled"
            case .saturation: "drop"
            case .vibrance: "sparkles"
            case .warmth: "thermometer.medium"
            case .tint: "paintpalette"
            case .highlights: "sun.max.circle"
            case .shadows: "moon"
            case .sharpness: "triangle"
            case .vignette: "circle.dashed"
            case .grain: "circle.grid.3x3"
            }
        }
    }

    public var exposure = 0.0
    public var brightness = 0.0
    public var contrast = 0.0
    public var saturation = 0.0
    public var vibrance = 0.0
    public var warmth = 0.0
    public var tint = 0.0
    public var highlights = 0.0
    public var shadows = 0.0
    public var sharpness = 0.0
    public var vignette = 0.0
    public var grain = 0.0

    public init() {}

    public subscript(key: Key) -> Double {
        get {
            switch key {
            case .exposure: exposure
            case .brightness: brightness
            case .contrast: contrast
            case .saturation: saturation
            case .vibrance: vibrance
            case .warmth: warmth
            case .tint: tint
            case .highlights: highlights
            case .shadows: shadows
            case .sharpness: sharpness
            case .vignette: vignette
            case .grain: grain
            }
        }
        set {
            let value = min(max(newValue, key.range.lowerBound), key.range.upperBound)
            switch key {
            case .exposure: exposure = value
            case .brightness: brightness = value
            case .contrast: contrast = value
            case .saturation: saturation = value
            case .vibrance: vibrance = value
            case .warmth: warmth = value
            case .tint: tint = value
            case .highlights: highlights = value
            case .shadows: shadows = value
            case .sharpness: sharpness = value
            case .vignette: vignette = value
            case .grain: grain = value
            }
        }
    }

    public var isNeutral: Bool { Key.allCases.allSatisfy { abs(self[$0]) < 0.0001 } }
}

public enum ImageTextAlignment: String, CaseIterable, Codable, Sendable {
    case left, center, right
}

public struct ImageTextStyle: Codable, Equatable, Sendable {
    public var text: String
    public var font: String
    public var size: Double
    public var color: String
    public var alignment: ImageTextAlignment
    public var bold: Bool
    public var italic: Bool
    public var strokeColor: String?
    public var strokeWidth: Double
    public var shadow: Bool
    public var background: String?

    public init(
        text: String, font: String = "Helvetica Neue", size: Double = 0.07,
        color: String = "#FFFFFF", alignment: ImageTextAlignment = .center, bold: Bool = true,
        italic: Bool = false, strokeColor: String? = nil, strokeWidth: Double = 0,
        shadow: Bool = true, background: String? = nil
    ) {
        self.text = text
        self.font = font
        self.size = size
        self.color = color
        self.alignment = alignment
        self.bold = bold
        self.italic = italic
        self.strokeColor = strokeColor
        self.strokeWidth = strokeWidth
        self.shadow = shadow
        self.background = background
    }
}

public enum ImageShapeKind: String, CaseIterable, Codable, Sendable {
    case rectangle, ellipse, line, arrow
}

public struct ImageShapeStyle: Codable, Equatable, Sendable {
    public var shape: ImageShapeKind
    public var strokeColor: String
    public var strokeWidth: Double
    public var fillColor: String?
    public var cornerRadius: Double
    public var start: ImagePoint
    public var end: ImagePoint

    public init(
        shape: ImageShapeKind, strokeColor: String = "#FF3B30", strokeWidth: Double = 0.008,
        fillColor: String? = nil, cornerRadius: Double = 0,
        start: ImagePoint = ImagePoint(x: 0, y: 1), end: ImagePoint = ImagePoint(x: 1, y: 0)
    ) {
        self.shape = shape
        self.strokeColor = strokeColor
        self.strokeWidth = strokeWidth
        self.fillColor = fillColor
        self.cornerRadius = cornerRadius
        self.start = start
        self.end = end
    }
}

public struct ImageDrawing: Codable, Equatable, Sendable {
    public var strokes: [[ImagePoint]]
    public var color: String
    public var width: Double
    public var highlighter: Bool

    public init(
        strokes: [[ImagePoint]], color: String = "#FF3B30", width: Double = 0.01,
        highlighter: Bool = false
    ) {
        self.strokes = strokes
        self.color = color
        self.width = width
        self.highlighter = highlighter
    }
}

public enum ImageRedactionStyle: String, CaseIterable, Codable, Sendable {
    case blur, pixelate, solid

    public var title: String {
        switch self {
        case .blur: "Blur"
        case .pixelate: "Pixelate"
        case .solid: "Black box"
        }
    }
}

public struct ImageRedaction: Codable, Equatable, Sendable {
    public var style: ImageRedactionStyle
    public var strength: Double
    public var color: String

    public init(
        style: ImageRedactionStyle = .pixelate, strength: Double = 0.6, color: String = "#000000"
    ) {
        self.style = style
        self.strength = strength
        self.color = color
    }
}

public struct ImageLayer: Codable, Equatable, Identifiable, Sendable {
    public enum Content: Codable, Equatable, Sendable {
        case text(ImageTextStyle)
        case shape(ImageShapeStyle)
        case drawing(ImageDrawing)
        case sticker(String)
        case image(path: String)
        case redaction(ImageRedaction)
    }

    public var id: UUID
    public var content: Content
    public var frame: StudioRect
    public var rotation: Double
    public var opacity: Double
    public var isHidden: Bool

    public init(
        id: UUID = UUID(), content: Content, frame: StudioRect, rotation: Double = 0,
        opacity: Double = 1, isHidden: Bool = false
    ) {
        self.id = id
        self.content = content
        self.frame = frame
        self.rotation = rotation
        self.opacity = opacity
        self.isHidden = isHidden
    }

    public var isRedaction: Bool {
        if case .redaction = content { return true }
        return false
    }

    public var title: String {
        switch content {
        case let .text(style): style.text.isEmpty ? "Text" : style.text
        case let .shape(style): style.shape.rawValue.capitalized
        case .drawing: "Drawing"
        case let .sticker(value): value
        case let .image(path): URL(fileURLWithPath: path).lastPathComponent
        case let .redaction(style): style.style.title
        }
    }

    public static func text(_ text: String, at frame: StudioRect, style: ImageTextStyle? = nil)
        -> ImageLayer
    {
        var resolved = style ?? ImageTextStyle(text: text)
        resolved.text = text
        return ImageLayer(content: .text(resolved), frame: frame)
    }

    public static func drawing(
        canvasStrokes: [[ImagePoint]], color: String, width: Double, highlighter: Bool = false
    ) -> ImageLayer? {
        let points = canvasStrokes.flatMap { $0 }
        guard let first = points.first else { return nil }
        var minX = first.x
        var minY = first.y
        var maxX = first.x
        var maxY = first.y
        for point in points {
            minX = min(minX, point.x)
            minY = min(minY, point.y)
            maxX = max(maxX, point.x)
            maxY = max(maxY, point.y)
        }
        let width = max(maxX - minX, 0.0001)
        let height = max(maxY - minY, 0.0001)
        let local = canvasStrokes.map { stroke in
            stroke.map { ImagePoint(x: ($0.x - minX) / width, y: ($0.y - minY) / height) }
        }
        return ImageLayer(
            content: .drawing(
                ImageDrawing(strokes: local, color: color, width: width, highlighter: highlighter)
            ),
            frame: StudioRect(x: minX, y: minY, width: width, height: height))
    }

    public func contains(_ point: CGPoint, canvas: CGSize, tolerance: Double = 0) -> Bool {
        let rect = frame.canvasRect(in: canvas).insetBy(
            dx: -tolerance * canvas.width, dy: -tolerance * canvas.height)
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let pixel = CGPoint(x: point.x * canvas.width, y: point.y * canvas.height)
        let angle = -rotation * .pi / 180
        let dx = pixel.x - center.x
        let dy = pixel.y - center.y
        let local = CGPoint(
            x: center.x + dx * cos(angle) - dy * sin(angle),
            y: center.y + dx * sin(angle) + dy * cos(angle))
        return rect.contains(local)
    }
}

public enum ImageFrameKind: String, CaseIterable, Codable, Sendable {
    case solid, rounded, polaroid, shadow

    public var title: String {
        switch self {
        case .solid: "Solid"
        case .rounded: "Rounded"
        case .polaroid: "Polaroid"
        case .shadow: "Shadow"
        }
    }
}

public struct ImageFrameStyle: Codable, Equatable, Sendable {
    public var kind: ImageFrameKind
    public var width: Double
    public var color: String
    public var cornerRadius: Double

    public init(
        kind: ImageFrameKind = .solid, width: Double = 0.04, color: String = "#FFFFFF",
        cornerRadius: Double = 0.06
    ) {
        self.kind = kind
        self.width = width
        self.color = color
        self.cornerRadius = cornerRadius
    }
}

public struct ImageExportSettings: Codable, Equatable, Sendable {
    public var format: StudioImageFormat?
    public var quality: Double
    public var maxDimension: Int?

    public init(format: StudioImageFormat? = nil, quality: Double = 0.92, maxDimension: Int? = nil)
    {
        self.format = format
        self.quality = quality
        self.maxDimension = maxDimension
    }
}

public struct ImageEditDocument: Codable, Equatable, Sendable {
    public var sourcePath: String
    public var quarterTurns: Int
    public var flipHorizontal: Bool
    public var flipVertical: Bool
    public var straighten: Double
    public var crop: StudioRect
    public var adjustments: ImageAdjustments
    public var filter: ImageFilterPreset
    public var filterIntensity: Double
    public var layers: [ImageLayer]
    public var frame: ImageFrameStyle?
    public var export: ImageExportSettings

    public init(source: URL) {
        sourcePath = source.path
        quarterTurns = 0
        flipHorizontal = false
        flipVertical = false
        straighten = 0
        crop = .full
        adjustments = ImageAdjustments()
        filter = .none
        filterIntensity = 1
        layers = []
        frame = nil
        export = ImageExportSettings()
    }

    public var sourceURL: URL { URL(fileURLWithPath: sourcePath) }

    public var isUnchanged: Bool {
        self == ImageEditDocument(source: sourceURL)
    }

    public var outputFormat: StudioImageFormat {
        if let format = export.format { return format }
        if let format = StudioImageFormat.of(sourceURL),
            StudioImageFormat.writable.contains(format), format != .pdf, format != .ico,
            format != .icns
        {
            return frame?.kind == .rounded || frame?.kind == .shadow
                ? (format.supportsAlpha ? format : .png) : format
        }
        return .png
    }

    public func orientedSize(for source: CGSize) -> CGSize {
        quarterTurns % 2 == 0 ? source : CGSize(width: source.height, height: source.width)
    }

    public func geometrySize(for source: CGSize) -> CGSize {
        let oriented = orientedSize(for: source)
        let scale = ImageEditGeometry.straightenScale(size: oriented, degrees: straighten)
        return CGSize(
            width: (oriented.width * scale).rounded(), height: (oriented.height * scale).rounded())
    }

    public func canvasSize(for source: CGSize) -> CGSize {
        let geometry = geometrySize(for: source)
        let rect = crop.pixels(in: geometry)
        return rect.size
    }

    public mutating func rotateClockwise() {
        quarterTurns = (quarterTurns + 1) % 4
        swap(&flipHorizontal, &flipVertical)
        crop = crop.rotatedClockwise
    }

    public mutating func rotateCounterclockwise() {
        quarterTurns = (quarterTurns + 3) % 4
        swap(&flipHorizontal, &flipVertical)
        crop = crop.rotatedCounterclockwise
    }

    public mutating func flipHorizontally() {
        flipHorizontal.toggle()
        straighten = -straighten
        crop = crop.mirroredHorizontally
    }

    public mutating func flipVertically() {
        flipVertical.toggle()
        straighten = -straighten
        crop = crop.mirroredVertically
    }

    public mutating func resetGeometry() {
        quarterTurns = 0
        flipHorizontal = false
        flipVertical = false
        straighten = 0
        crop = .full
    }

    public mutating func add(_ layer: ImageLayer) {
        layers.append(layer)
    }

    public mutating func removeLayer(_ id: UUID) {
        layers.removeAll { $0.id == id }
    }

    public mutating func updateLayer(_ id: UUID, _ change: (inout ImageLayer) -> Void) {
        guard let index = layers.firstIndex(where: { $0.id == id }) else { return }
        change(&layers[index])
    }

    public mutating func moveLayer(_ id: UUID, by offset: Int) {
        guard let index = layers.firstIndex(where: { $0.id == id }) else { return }
        let target = min(max(index + offset, 0), layers.count - 1)
        guard target != index else { return }
        let layer = layers.remove(at: index)
        layers.insert(layer, at: target)
    }

    public mutating func duplicateLayer(_ id: UUID) -> UUID? {
        guard let index = layers.firstIndex(where: { $0.id == id }) else { return nil }
        var copy = layers[index]
        copy.id = UUID()
        copy.frame = StudioRect(
            x: min(copy.frame.x + 0.03, 1 - copy.frame.width),
            y: min(copy.frame.y + 0.03, 1 - copy.frame.height), width: copy.frame.width,
            height: copy.frame.height)
        layers.insert(copy, at: index + 1)
        return copy.id
    }

    public func layer(_ id: UUID) -> ImageLayer? {
        layers.first { $0.id == id }
    }

    public func hitTest(_ point: CGPoint, canvas: CGSize, tolerance: Double = 0.01) -> UUID? {
        layers.reversed().first {
            !$0.isHidden && $0.contains(point, canvas: canvas, tolerance: tolerance)
        }?.id
    }
}

extension StudioRect {
    public var rotatedClockwise: StudioRect {
        StudioRect(x: 1 - y - height, y: x, width: height, height: width)
    }

    public var rotatedCounterclockwise: StudioRect {
        StudioRect(x: y, y: 1 - x - width, width: height, height: width)
    }

    public var mirroredHorizontally: StudioRect {
        StudioRect(x: 1 - x - width, y: y, width: width, height: height)
    }

    public var mirroredVertically: StudioRect {
        StudioRect(x: x, y: 1 - y - height, width: width, height: height)
    }

    public func canvasRect(in size: CGSize) -> CGRect {
        CGRect(
            x: x * size.width, y: y * size.height, width: width * size.width,
            height: height * size.height)
    }

    public static func from(canvasRect rect: CGRect, in size: CGSize) -> StudioRect {
        guard size.width > 0, size.height > 0 else { return .full }
        let standard = rect.standardized
        return StudioRect(
            x: standard.minX / size.width, y: standard.minY / size.height,
            width: standard.width / size.width, height: standard.height / size.height)
    }

    public func moved(by delta: CGPoint) -> StudioRect {
        StudioRect(
            x: min(max(x + delta.x, -width * 0.9), 1 - width * 0.1),
            y: min(max(y + delta.y, -height * 0.9), 1 - height * 0.1), width: width,
            height: height)
    }

    public static func centered(width: Double, height: Double) -> StudioRect {
        StudioRect(x: (1 - width) / 2, y: (1 - height) / 2, width: width, height: height)
    }
}

public enum ImageEditGeometry {
    public static func straightenScale(size: CGSize, degrees: Double) -> Double {
        let angle = abs(degrees) * .pi / 180
        guard angle > 0.0001, size.width > 0, size.height > 0 else { return 1 }
        let w = Double(size.width)
        let h = Double(size.height)
        let first = w / (w * cos(angle) + h * sin(angle))
        let second = h / (w * sin(angle) + h * cos(angle))
        return min(first, second)
    }

    public static func fittedRect(content: CGSize, in bounds: CGRect) -> CGRect {
        guard content.width > 0, content.height > 0 else { return bounds }
        let scale = min(bounds.width / content.width, bounds.height / content.height)
        let size = CGSize(width: content.width * scale, height: content.height * scale)
        return CGRect(
            x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width,
            height: size.height)
    }

    public static func normalized(_ point: CGPoint, in viewRect: CGRect) -> CGPoint {
        guard viewRect.width > 0, viewRect.height > 0 else { return .zero }
        return CGPoint(
            x: (point.x - viewRect.minX) / viewRect.width,
            y: (point.y - viewRect.minY) / viewRect.height)
    }

    public static func viewPoint(_ point: CGPoint, in viewRect: CGRect) -> CGPoint {
        CGPoint(
            x: viewRect.minX + point.x * viewRect.width,
            y: viewRect.minY + point.y * viewRect.height)
    }

    public static func viewRect(for frame: StudioRect, in viewRect: CGRect) -> CGRect {
        CGRect(
            x: viewRect.minX + frame.x * viewRect.width,
            y: viewRect.minY + frame.y * viewRect.height,
            width: frame.width * viewRect.width, height: frame.height * viewRect.height)
    }

    public static func aspectCrop(_ ratio: Double, in size: CGSize) -> StudioRect {
        guard ratio > 0, size.width > 0, size.height > 0 else { return .full }
        let current = Double(size.width / size.height)
        if current > ratio {
            let width = ratio / current
            return .centered(width: width, height: 1)
        }
        return .centered(width: 1, height: current / ratio)
    }
}
