import CoreGraphics
import Foundation

public struct VirtualCameraColor: Codable, Hashable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = Self.unit(red)
        self.green = Self.unit(green)
        self.blue = Self.unit(blue)
        self.alpha = Self.unit(alpha)
    }

    public init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6 || text.count == 8,
            text.allSatisfy(\.isHexDigit),
            let value = UInt64(text, radix: 16)
        else { return nil }
        let hasAlpha = text.count == 8
        let red = hasAlpha ? (value >> 24) & 0xFF : (value >> 16) & 0xFF
        let green = hasAlpha ? (value >> 16) & 0xFF : (value >> 8) & 0xFF
        let blue = hasAlpha ? (value >> 8) & 0xFF : value & 0xFF
        let alpha = hasAlpha ? value & 0xFF : 0xFF
        self.init(
            red: Double(red) / 255, green: Double(green) / 255, blue: Double(blue) / 255,
            alpha: Double(alpha) / 255)
    }

    public var hex: String {
        let components = [red, green, blue].map { Int(($0 * 255).rounded()) }
        let base = String(format: "#%02X%02X%02X", components[0], components[1], components[2])
        guard alpha < 1 else { return base }
        return base + String(format: "%02X", Int((alpha * 255).rounded()))
    }

    public var cgColor: CGColor {
        CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    public var luminance: Double {
        0.2126 * red + 0.7152 * green + 0.0722 * blue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let color = VirtualCameraColor(hex: text) else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "\(text) is not a hex color")
        }
        self = color
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hex)
    }

    private static func unit(_ value: Double) -> Double {
        value.isFinite ? min(max(value, 0), 1) : 0
    }

    public static let white = VirtualCameraColor(red: 1, green: 1, blue: 1)
    public static let black = VirtualCameraColor(red: 0, green: 0, blue: 0)
    public static let slate = VirtualCameraColor(hex: "#1E293B") ?? .black
    public static let accent = VirtualCameraColor(hex: "#0A84FF") ?? .white
    public static let matte = VirtualCameraColor(hex: "#0B0B0E") ?? .black
}
