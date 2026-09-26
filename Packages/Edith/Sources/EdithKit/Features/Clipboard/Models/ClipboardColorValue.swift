import Foundation

public struct ClipboardColorValue: Equatable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double
    public let alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = Self.unit(red)
        self.green = Self.unit(green)
        self.blue = Self.unit(blue)
        self.alpha = Self.unit(alpha)
    }

    public init?(parsing text: String) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard (4...64).contains(value.count) else { return nil }
        if value.hasPrefix("#") {
            guard let color = Self.hex(value.dropFirst()) else { return nil }
            self = color
            return
        }
        guard let open = value.firstIndex(of: "("), value.hasSuffix(")") else { return nil }
        let name = value[..<open].trimmingCharacters(in: .whitespaces)
        let arguments = Self.arguments(
            value[value.index(after: open)..<value.index(before: value.endIndex)])
        switch name {
        case "rgb", "rgba":
            guard let color = Self.rgb(arguments) else { return nil }
            self = color
        case "hsl", "hsla":
            guard let color = Self.hsl(arguments) else { return nil }
            self = color
        default:
            return nil
        }
    }

    public var hexString: String {
        let channels = [red, green, blue].map { String(format: "%02x", Int(($0 * 255).rounded())) }
        let base = "#" + channels.joined()
        return alpha < 1 ? base + String(format: "%02x", Int((alpha * 255).rounded())) : base
    }

    private static func unit(_ value: Double) -> Double {
        value.isFinite ? min(1, max(0, value)) : 0
    }

    private static func hex(_ digits: Substring) -> ClipboardColorValue? {
        guard [3, 4, 6, 8].contains(digits.count), digits.allSatisfy(\.isHexDigit),
            let raw = UInt64(digits, radix: 16)
        else { return nil }
        let short = digits.count <= 4
        let width: UInt64 = short ? 4 : 8
        let count = short ? digits.count : digits.count / 2
        let maximum = Double((1 << width) - 1)
        let channels = (0..<count).map { index -> Double in
            let shift = width * UInt64(count - 1 - index)
            return Double((raw >> shift) & ((1 << width) - 1)) / maximum
        }
        return ClipboardColorValue(
            red: channels[0], green: channels[1], blue: channels[2],
            alpha: channels.count == 4 ? channels[3] : 1)
    }

    private static func arguments(_ body: Substring) -> [String] {
        body.split(whereSeparator: { $0 == "," || $0 == "/" || $0.isWhitespace })
            .map(String.init)
    }

    private static func rgb(_ arguments: [String]) -> ClipboardColorValue? {
        guard arguments.count == 3 || arguments.count == 4 else { return nil }
        let channels = arguments.prefix(3).map { channel($0, scale: 255) }
        guard channels.allSatisfy({ $0 != nil }), let alpha = alpha(arguments) else { return nil }
        let values = channels.compactMap { $0 }
        return ClipboardColorValue(red: values[0], green: values[1], blue: values[2], alpha: alpha)
    }

    private static func hsl(_ arguments: [String]) -> ClipboardColorValue? {
        guard arguments.count == 3 || arguments.count == 4,
            let hue = degrees(arguments[0]),
            let saturation = channel(arguments[1], scale: 100),
            let lightness = channel(arguments[2], scale: 100),
            let alpha = alpha(arguments)
        else { return nil }
        let chroma = (1 - abs(2 * lightness - 1)) * saturation
        let sector = hue / 60
        let secondary = chroma * (1 - abs(sector.truncatingRemainder(dividingBy: 2) - 1))
        let (red, green, blue): (Double, Double, Double)
        switch sector {
        case ..<1: (red, green, blue) = (chroma, secondary, 0)
        case ..<2: (red, green, blue) = (secondary, chroma, 0)
        case ..<3: (red, green, blue) = (0, chroma, secondary)
        case ..<4: (red, green, blue) = (0, secondary, chroma)
        case ..<5: (red, green, blue) = (secondary, 0, chroma)
        default: (red, green, blue) = (chroma, 0, secondary)
        }
        let match = lightness - chroma / 2
        return ClipboardColorValue(
            red: red + match, green: green + match, blue: blue + match, alpha: alpha)
    }

    private static func channel(_ token: String, scale: Double) -> Double? {
        let percent = token.hasSuffix("%")
        guard let number = Double(percent ? String(token.dropLast()) : token), number.isFinite
        else { return nil }
        let value = percent ? number / 100 : number / scale
        return (0...1).contains(value) ? value : nil
    }

    private static func degrees(_ token: String) -> Double? {
        let trimmed = token.hasSuffix("deg") ? String(token.dropLast(3)) : token
        guard let number = Double(trimmed), number.isFinite else { return nil }
        let wrapped = number.truncatingRemainder(dividingBy: 360)
        return wrapped < 0 ? wrapped + 360 : wrapped
    }

    private static func alpha(_ arguments: [String]) -> Double? {
        guard arguments.count == 4 else { return 1 }
        return channel(arguments[3], scale: 1)
    }
}
