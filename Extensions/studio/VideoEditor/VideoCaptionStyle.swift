import AppKit
import CoreText
import Foundation

public struct VideoCaptionStyle: Codable, Equatable, Sendable {
    public struct Color: Codable, Equatable, Sendable {
        public var red: Double
        public var green: Double
        public var blue: Double
        public var alpha: Double

        public init(red: Double = 0, green: Double = 0, blue: Double = 0, alpha: Double = 1) {
            self.red = red
            self.green = green
            self.blue = blue
            self.alpha = alpha
        }

        var cgColor: CGColor {
            CGColor(
                colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                components: [red, green, blue, alpha].map { CGFloat($0) })!
        }

        func validate() throws {
            try VideoCaptionStyle.require(
                [red, green, blue, alpha].allSatisfy { $0.isFinite && (0...1).contains($0) },
                "Color channels and alpha must be finite fractions from 0 through 1.")
        }
    }

    public struct Outline: Codable, Equatable, Sendable {
        public var width: Double
        public var color: Color

        public init(width: Double = 1, color: Color = .init(alpha: 70.0 / 255)) {
            self.width = width
            self.color = color
        }
    }

    public struct Shadow: Codable, Equatable, Sendable {
        public var x: Double
        public var y: Double
        public var blur: Double
        public var strokeWidth: Double
        public var color: Color
        public var strokeColor: Color?

        public init(
            x: Double = 3, y: Double = 7, blur: Double = 9, strokeWidth: Double = 0,
            color: Color = .init(), strokeColor: Color? = nil
        ) {
            self.x = x
            self.y = y
            self.blur = blur
            self.strokeWidth = strokeWidth
            self.color = color
            self.strokeColor = strokeColor
        }
    }

    public struct Gradient: Codable, Equatable, Sendable {
        public struct Stop: Codable, Equatable, Sendable {
            public var location: Double
            public var color: Color

            public init(location: Double, color: Color) {
                self.location = location
                self.color = color
            }
        }

        public var startY: Double
        public var endY: Double
        public var stops: [Stop]

        public init(startY: Double, endY: Double, stops: [Stop]) {
            self.startY = startY
            self.endY = endY
            self.stops = stops
        }
    }

    public enum Alignment: String, Codable, Sendable { case left, center, right }
    public enum Anchor: String, Codable, Sendable { case top, center, bottom }
    public enum Metrics: String, Codable, Sendable { case typographic, fontBounds }

    public var canvasWidth: Double = 2160
    public var canvasHeight: Double = 3840
    public var fontFamily: String = "Arial"
    public var fontStyle: String = "Bold Italic"
    public var fontSize: Double = 104
    public var lineAdvance: Double = 150
    public var alignment: Alignment = .center
    public var anchor: Anchor = .top
    public var metrics: Metrics?
    public var x: Double = 1080
    public var y: Double = 2780
    public var width: Double = 2000
    public var fill: Color = .init(red: 1, green: 1, blue: 1)
    public var outline: Outline?
    public var shadow: Shadow?
    public var gradient: Gradient?

    public init() {}

    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= 65536 else {
            throw VideoEditorService.Failure(
                "invalid_caption_style", "Caption style exceeds 64 KiB.")
        }
        let raw = try JSONSerialization.jsonObject(with: data)
        try VideoEditPlan.validateFields(raw, schema: schema, path: "style")
        let style = try JSONDecoder().decode(Self.self, from: data)
        try style.validate()
        return style
    }

    public func validate() throws {
        try Self.require(
            [canvasWidth, canvasHeight].allSatisfy { $0.isFinite && (2...16384).contains($0) },
            "Reference canvas dimensions must be 2 through 16384 pixels.")
        try Self.require(
            fontSize.isFinite && (1...2048).contains(fontSize)
                && lineAdvance.isFinite && (1...4096).contains(lineAdvance),
            "Font size must be 1 through 2048 pixels and line advance 1 through 4096 pixels.")
        try Self.require(
            x.isFinite && y.isFinite && width.isFinite && width >= 1 && width <= canvasWidth
                && x >= 0 && x <= canvasWidth && y >= 0 && y <= canvasHeight,
            "Caption position and width must fit the reference canvas.")
        try fill.validate()
        if let outline {
            try Self.require(
                outline.width.isFinite && (0...128).contains(outline.width),
                "Outline width must be 0 through 128 pixels.")
            try outline.color.validate()
        }
        if let shadow {
            try Self.require(
                [shadow.x, shadow.y].allSatisfy { $0.isFinite && abs($0) <= 2048 }
                    && shadow.blur.isFinite && (0...256).contains(shadow.blur)
                    && shadow.strokeWidth.isFinite && (0...128).contains(shadow.strokeWidth),
                "Invalid shadow offset, blur or stroke width.")
            try shadow.color.validate()
            try shadow.strokeColor?.validate()
        }
        if let gradient {
            try Self.require(
                gradient.startY.isFinite && gradient.endY.isFinite && gradient.startY >= 0
                    && gradient.endY <= canvasHeight && gradient.startY < gradient.endY
                    && (2...16).contains(gradient.stops.count)
                    && gradient.stops.first?.location == 0 && gradient.stops.last?.location == 1,
                "Gradient extent must fit the canvas, with 2 through 16 stops spanning 0 to 1.")
            var previous = -1.0
            for stop in gradient.stops {
                try Self.require(
                    stop.location.isFinite && (0...1).contains(stop.location)
                        && stop.location > previous,
                    "Gradient stops must be strictly increasing fractions.")
                try stop.color.validate()
                previous = stop.location
            }
        }
        _ = try font()
    }

    func font() throws -> CTFont {
        func normalized(_ value: String) -> String {
            value.lowercased().filter { !$0.isWhitespace && $0 != "-" }
        }
        guard !fontFamily.isEmpty, fontFamily.utf8.count <= 200,
            !fontStyle.isEmpty, fontStyle.utf8.count <= 200,
            let members = NSFontManager.shared.availableMembers(ofFontFamily: fontFamily),
            let member = members.first(where: {
                ($0[1] as? String).map { normalized($0) == normalized(fontStyle) } == true
            }), let name = member.first as? String
        else {
            throw VideoEditorService.Failure(
                "font_not_found", "Font family/style is not installed: \(fontFamily) \(fontStyle).")
        }
        let font = CTFontCreateWithName(name as CFString, fontSize, nil)
        try Self.require(
            CTFontCopyPostScriptName(font) as String == name,
            "The requested font could not be loaded.")
        return font
    }

    func store(in raw: inout [String: Any]) throws {
        try validate()
        raw["edithCaptionStyle"] = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(self))
    }

    static func require(_ valid: Bool, _ message: String) throws {
        guard valid else { throw VideoEditorService.Failure("invalid_caption_style", message) }
    }
}

extension VideoProject.Annotation {
    var captionCanvasRect: CGRect? {
        guard let style = captionStyle else { return nil }
        return try? VideoStyledCaptionImage.rect(text, style: style)
    }

    var captionStyle: VideoCaptionStyle? {
        guard let raw = raw["edithCaptionStyle"],
            let data = try? JSONSerialization.data(withJSONObject: raw)
        else { return nil }
        return try? JSONDecoder().decode(VideoCaptionStyle.self, from: data)
    }
}

extension VideoProject {
    mutating func placeStyledCaption(_ id: String, rect: CGRect) throws {
        let caption = try VideoEditorService.requireCaption(id, project: self)
        guard var style = caption.captionStyle, let original = caption.captionCanvasRect else {
            return
        }
        let scale = rect.width / original.width
        style.width = rect.width * style.canvasWidth
        style.fontSize *= scale
        style.lineAdvance *= scale
        style.x =
            (style.alignment == .center
                ? rect.midX : style.alignment == .right ? rect.maxX : rect.minX) * style.canvasWidth
        let height = original.height * scale * style.canvasHeight
        style.y =
            rect.minY * style.canvasHeight
            + (style.anchor == .center ? height / 2 : style.anchor == .bottom ? height : 0)
        try setCaptionStyle(id, style: style)
    }

    mutating func setCaptionStyle(_ id: String, style: VideoCaptionStyle) throws {
        let caption = try VideoEditorService.requireCaption(id, project: self)
        _ = try VideoStyledCaptionImage.layout(caption.text, style: style)
        var raw = caption.raw
        try style.store(in: &raw)
        editRegion("annotations", id: id) { $0 = raw }
    }
}
