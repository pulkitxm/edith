import AppKit
import Foundation
import GhosttyKit

public struct GhosttyTheme: Equatable, Sendable {
    public var background: String
    public var foreground: String
    public var cursor: String
    public var selectionBackground: String?
    public var selectionForeground: String?
    public var palette: [String]
    public var fontSize: Double?
    public var fontFamily: String?

    public init(
        background: String, foreground: String, cursor: String,
        selectionBackground: String? = nil, selectionForeground: String? = nil,
        palette: [String] = [],
        fontSize: Double? = nil, fontFamily: String? = nil
    ) {
        self.background = background
        self.foreground = foreground
        self.cursor = cursor
        self.selectionBackground = selectionBackground
        self.selectionForeground = selectionForeground
        self.palette = palette
        self.fontSize = fontSize
        self.fontFamily = fontFamily
    }

    public init(
        background: NSColor, foreground: NSColor, cursor: NSColor,
        selectionBackground: NSColor? = nil, selectionForeground: NSColor? = nil,
        palette: [NSColor] = [],
        fontSize: Double? = nil, fontFamily: String? = nil
    ) {
        self.init(
            background: Self.hex(background), foreground: Self.hex(foreground),
            cursor: Self.hex(cursor),
            selectionBackground: selectionBackground.map(Self.hex),
            selectionForeground: selectionForeground.map(Self.hex),
            palette: palette.map(Self.hex),
            fontSize: fontSize, fontFamily: fontFamily)
    }

    public static func hex(_ color: NSColor) -> String {
        let converted = color.usingColorSpace(.sRGB) ?? color
        let red = Int((converted.redComponent * 255).rounded())
        let green = Int((converted.greenComponent * 255).rounded())
        let blue = Int((converted.blueComponent * 255).rounded())
        return String(format: "#%02x%02x%02x", red, green, blue)
    }

    var configuration: String {
        var lines = [
            "background = \(background)",
            "foreground = \(foreground)",
            "cursor-color = \(cursor)",
            "window-decoration = false",
            "window-padding-x = 6",
            "window-padding-y = 4",
            "confirm-close-surface = false",
            "clipboard-read = allow",
            "clipboard-write = allow",
            "copy-on-select = clipboard",
            "mouse-shift-capture = false",
            "link-url = true",
            "link-osc8 = true",
            "link-previews = true",
            #"selection-word-chars = "\t '\"│`|;,()[]{}<>$""#,
            "font-codepoint-map = U+E000-U+F8FF=Symbols Nerd Font Mono",
            "font-codepoint-map = U+F0000-U+FFFFD=Symbols Nerd Font Mono",
            "font-codepoint-map = U+100000-U+10FFFD=Symbols Nerd Font Mono",
            #"keybind = shift+enter=text:\x1b\r"#,
        ]
        if let selectionBackground {
            lines.append("selection-background = \(selectionBackground)")
        }
        if let selectionForeground {
            lines.append("selection-foreground = \(selectionForeground)")
        }
        for (index, color) in palette.prefix(16).enumerated() {
            lines.append("palette = \(index)=\(color)")
        }
        if let fontSize {
            lines.append("font-size = \(Int(fontSize.rounded()))")
        }
        if let fontFamily, !fontFamily.isEmpty {
            lines.append("font-family = \(fontFamily)")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
