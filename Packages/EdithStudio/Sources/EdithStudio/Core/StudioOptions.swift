import CoreGraphics
import Foundation

public struct StudioRect: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public static let full = StudioRect(x: 0, y: 0, width: 1, height: 1)

    public var clamped: StudioRect {
        let x = min(max(self.x, 0), 1)
        let y = min(max(self.y, 0), 1)
        return StudioRect(
            x: x, y: y, width: min(max(width, 0), 1 - x), height: min(max(height, 0), 1 - y))
    }

    public var isFull: Bool {
        abs(x) < 0.0001 && abs(y) < 0.0001 && abs(width - 1) < 0.0001 && abs(height - 1) < 0.0001
    }

    public func pixels(in size: CGSize) -> CGRect {
        let clamped = self.clamped
        return CGRect(
            x: (clamped.x * size.width).rounded(), y: (clamped.y * size.height).rounded(),
            width: max(1, (clamped.width * size.width).rounded()),
            height: max(1, (clamped.height * size.height).rounded()))
    }

    public var text: String {
        [x, y, width, height].map { String(format: "%.4f", $0) }.joined(separator: ",")
    }

    public init?(text: String) {
        let parts = text.split(separator: ",").compactMap {
            Double($0.trimmingCharacters(in: .whitespaces))
        }
        guard parts.count == 4 else { return nil }
        self.init(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
    }
}

public struct StudioSpan: Codable, Hashable, Sendable {
    public var start: Double
    public var end: Double?

    public init(start: Double, end: Double?) {
        self.start = start
        self.end = end
    }

    public static let whole = StudioSpan(start: 0, end: nil)

    public func duration(within total: Double?) -> Double? {
        guard let stop = end ?? total else { return nil }
        return max(0, stop - start)
    }

    public var text: String {
        StudioTime.format(start) + "-" + (end.map(StudioTime.format) ?? "")
    }

    public init?(text: String) {
        let parts = text.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard let first = parts.first, let start = StudioTime.parse(String(first)) else {
            return nil
        }
        let tail = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : ""
        if tail.isEmpty {
            self.init(start: start, end: nil)
            return
        }
        guard let end = StudioTime.parse(tail), end > start else { return nil }
        self.init(start: start, end: end)
    }
}

public enum StudioTime {
    public static func parse(_ raw: String) -> Double? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        let parts = text.split(separator: ":").map(String.init)
        guard (1...3).contains(parts.count) else { return nil }
        var total = 0.0
        for part in parts {
            guard let value = Double(part), value >= 0 else { return nil }
            total = total * 60 + value
        }
        return total
    }

    public static func format(_ seconds: Double) -> String {
        let clamped = max(0, seconds)
        let hours = Int(clamped) / 3600
        let minutes = (Int(clamped) % 3600) / 60
        let rest = clamped - Double(hours * 3600 + minutes * 60)
        let secondsText =
            rest.truncatingRemainder(dividingBy: 1) < 0.0005
            ? String(format: "%02d", Int(rest.rounded(.down)))
            : String(format: "%06.3f", rest)
        if hours > 0 { return String(format: "%d:%02d:", hours, minutes) + secondsText }
        return String(format: "%02d:", minutes) + secondsText
    }
}

public enum StudioValue: Codable, Hashable, Sendable {
    case bool(Bool)
    case number(Double)
    case text(String)
    case rect(StudioRect)
    case span(StudioSpan)

    public var bool: Bool? {
        if case let .bool(value) = self { return value }
        return nil
    }

    public var number: Double? {
        if case let .number(value) = self { return value }
        return nil
    }

    public var text: String? {
        if case let .text(value) = self { return value }
        return nil
    }

    public var rect: StudioRect? {
        if case let .rect(value) = self { return value }
        return nil
    }

    public var span: StudioSpan? {
        if case let .span(value) = self { return value }
        return nil
    }

    public var display: String {
        switch self {
        case let .bool(value): value ? "on" : "off"
        case let .number(value):
            value.rounded() == value ? String(Int(value)) : String(format: "%g", value)
        case let .text(value): value
        case let .rect(value): value.text
        case let .span(value): value.text
        }
    }
}

public struct StudioChoice: Hashable, Sendable {
    public let value: String
    public let label: String

    public init(_ value: String, _ label: String) {
        self.value = value
        self.label = label
    }
}

public struct StudioOption: Identifiable, Sendable {
    public enum Kind: Sendable {
        case choice([StudioChoice])
        case toggle
        case integer(ClosedRange<Int>, unit: String?)
        case number(ClosedRange<Double>, step: Double, unit: String?)
        case percent(ClosedRange<Double>)
        case text(placeholder: String)
        case longText(placeholder: String)
        case password
        case color
        case pages
        case time
        case span
        case rect
        case file([StudioKind])
        case font
        case anchor
    }

    public struct Condition: Sendable {
        public let key: String
        public let values: Set<String>

        public init(_ key: String, _ values: Set<String>) {
            self.key = key
            self.values = values
        }
    }

    public let key: String
    public let label: String
    public let kind: Kind
    public let defaultValue: StudioValue
    public let help: String?
    public let condition: Condition?
    public let isRequired: Bool

    public var id: String { key }

    public init(
        _ key: String, _ label: String, _ kind: Kind, default defaultValue: StudioValue,
        help: String? = nil, when condition: Condition? = nil, required: Bool = false
    ) {
        self.key = key
        self.label = label
        self.kind = kind
        self.defaultValue = defaultValue
        self.help = help
        self.condition = condition
        self.isRequired = required
    }

    public static func choice(
        _ key: String, _ label: String, _ choices: [StudioChoice], default value: String,
        help: String? = nil, when condition: Condition? = nil
    ) -> StudioOption {
        StudioOption(
            key, label, .choice(choices), default: .text(value), help: help, when: condition)
    }

    public static func toggle(
        _ key: String, _ label: String, default value: Bool, help: String? = nil,
        when condition: Condition? = nil
    ) -> StudioOption {
        StudioOption(key, label, .toggle, default: .bool(value), help: help, when: condition)
    }

    public static func integer(
        _ key: String, _ label: String, _ range: ClosedRange<Int>, default value: Int,
        unit: String? = nil, help: String? = nil, when condition: Condition? = nil
    ) -> StudioOption {
        StudioOption(
            key, label, .integer(range, unit: unit), default: .number(Double(value)), help: help,
            when: condition)
    }

    public static func number(
        _ key: String, _ label: String, _ range: ClosedRange<Double>, step: Double,
        default value: Double, unit: String? = nil, help: String? = nil,
        when condition: Condition? = nil
    ) -> StudioOption {
        StudioOption(
            key, label, .number(range, step: step, unit: unit), default: .number(value),
            help: help, when: condition)
    }

    public static func percent(
        _ key: String, _ label: String, _ range: ClosedRange<Double> = 0...1,
        default value: Double, help: String? = nil, when condition: Condition? = nil
    ) -> StudioOption {
        StudioOption(
            key, label, .percent(range), default: .number(value), help: help, when: condition)
    }

    public static func text(
        _ key: String, _ label: String, placeholder: String = "", default value: String = "",
        help: String? = nil, when condition: Condition? = nil, required: Bool = false
    ) -> StudioOption {
        StudioOption(
            key, label, .text(placeholder: placeholder), default: .text(value), help: help,
            when: condition, required: required)
    }

    public static func longText(
        _ key: String, _ label: String, placeholder: String = "", default value: String = "",
        help: String? = nil, when condition: Condition? = nil, required: Bool = false
    ) -> StudioOption {
        StudioOption(
            key, label, .longText(placeholder: placeholder), default: .text(value), help: help,
            when: condition, required: required)
    }

    public static func password(
        _ key: String, _ label: String, help: String? = nil, when condition: Condition? = nil,
        required: Bool = false
    ) -> StudioOption {
        StudioOption(
            key, label, .password, default: .text(""), help: help, when: condition,
            required: required)
    }

    public static func color(
        _ key: String, _ label: String, default value: String, help: String? = nil,
        when condition: Condition? = nil
    ) -> StudioOption {
        StudioOption(key, label, .color, default: .text(value), help: help, when: condition)
    }

    public static func pages(
        _ key: String = "pages", _ label: String = "Pages", default value: String = "all",
        help: String? = "Examples: all, 1-3, 5, 8-, odd, even, last.",
        when condition: Condition? = nil
    ) -> StudioOption {
        StudioOption(key, label, .pages, default: .text(value), help: help, when: condition)
    }

    public static func time(
        _ key: String, _ label: String, default value: Double, help: String? = nil,
        when condition: Condition? = nil
    ) -> StudioOption {
        StudioOption(key, label, .time, default: .number(value), help: help, when: condition)
    }

    public static func span(
        _ key: String = "range", _ label: String = "Range", help: String? = nil,
        when condition: Condition? = nil
    ) -> StudioOption {
        StudioOption(key, label, .span, default: .span(.whole), help: help, when: condition)
    }

    public static func rect(
        _ key: String, _ label: String, default value: StudioRect = .full, help: String? = nil,
        when condition: Condition? = nil
    ) -> StudioOption {
        StudioOption(key, label, .rect, default: .rect(value), help: help, when: condition)
    }

    public static func file(
        _ key: String, _ label: String, kinds: [StudioKind], help: String? = nil,
        when condition: Condition? = nil, required: Bool = false
    ) -> StudioOption {
        StudioOption(
            key, label, .file(kinds), default: .text(""), help: help, when: condition,
            required: required)
    }

    public static func font(
        _ key: String = "font", _ label: String = "Font", default value: String = "Helvetica Neue",
        when condition: Condition? = nil
    ) -> StudioOption {
        StudioOption(key, label, .font, default: .text(value), when: condition)
    }

    public static func anchor(
        _ key: String = "position", _ label: String = "Position", default value: StudioAnchor,
        includeTiled: Bool = false, when condition: Condition? = nil
    ) -> StudioOption {
        StudioOption(
            key, label, .anchor, default: .text(value.rawValue),
            help: includeTiled ? "Choose tiled to repeat across the whole surface." : nil,
            when: condition)
    }

    public func parse(_ raw: String) throws -> StudioValue {
        let text = raw.trimmingCharacters(in: .whitespaces)
        switch kind {
        case let .choice(choices):
            guard let match = choices.first(where: { $0.value.lowercased() == text.lowercased() })
            else {
                throw StudioError.invalidOption(
                    key, "use one of " + choices.map(\.value).joined(separator: ", "))
            }
            return .text(match.value)
        case .toggle:
            switch text.lowercased() {
            case "1", "true", "yes", "on": return .bool(true)
            case "0", "false", "no", "off": return .bool(false)
            default: throw StudioError.invalidOption(key, "use true or false")
            }
        case let .integer(range, _):
            guard let value = Int(text), range.contains(value) else {
                throw StudioError.invalidOption(
                    key, "use a whole number from \(range.lowerBound) to \(range.upperBound)")
            }
            return .number(Double(value))
        case let .number(range, _, _), let .percent(range):
            let percentSuffix = text.hasSuffix("%")
            let body = percentSuffix ? String(text.dropLast()) : text
            guard var value = Double(body) else {
                throw StudioError.invalidOption(key, "use a number")
            }
            if percentSuffix { value /= 100 }
            guard range.contains(value) else {
                throw StudioError.invalidOption(
                    key, "use a value from \(range.lowerBound) to \(range.upperBound)")
            }
            return .number(value)
        case .time:
            guard let value = StudioTime.parse(text) else {
                throw StudioError.invalidOption(key, "use seconds or mm:ss")
            }
            return .number(value)
        case .span:
            guard let value = StudioSpan(text: text) else {
                throw StudioError.invalidOption(key, "use start-end, for example 0:05-0:12")
            }
            return .span(value)
        case .rect:
            guard let value = StudioRect(text: text) else {
                throw StudioError.invalidOption(key, "use x,y,width,height between 0 and 1")
            }
            return .rect(value)
        case .anchor:
            guard StudioAnchor(rawValue: text) != nil else {
                throw StudioError.invalidOption(
                    key,
                    "use one of " + StudioAnchor.allCases.map(\.rawValue).joined(separator: ", "))
            }
            return .text(text)
        case .color:
            guard StudioColor(hex: text) != nil else {
                throw StudioError.invalidOption(key, "use a hex color such as #FF0000")
            }
            return .text(text)
        case .text, .longText, .password, .pages, .file, .font:
            return .text(raw)
        }
    }

    public func isVisible(in settings: StudioSettings) -> Bool {
        guard let condition else { return true }
        let value = settings.values[condition.key]?.display ?? ""
        return condition.values.contains(value)
    }
}

public enum StudioAnchor: String, CaseIterable, Codable, Sendable {
    case topLeft = "top-left"
    case top = "top"
    case topRight = "top-right"
    case left = "left"
    case center = "center"
    case right = "right"
    case bottomLeft = "bottom-left"
    case bottom = "bottom"
    case bottomRight = "bottom-right"
    case tiled = "tiled"

    public var unit: CGPoint {
        switch self {
        case .topLeft: CGPoint(x: 0, y: 0)
        case .top: CGPoint(x: 0.5, y: 0)
        case .topRight: CGPoint(x: 1, y: 0)
        case .left: CGPoint(x: 0, y: 0.5)
        case .center, .tiled: CGPoint(x: 0.5, y: 0.5)
        case .right: CGPoint(x: 1, y: 0.5)
        case .bottomLeft: CGPoint(x: 0, y: 1)
        case .bottom: CGPoint(x: 0.5, y: 1)
        case .bottomRight: CGPoint(x: 1, y: 1)
        }
    }

    public func place(_ size: CGSize, in bounds: CGRect, margin: CGFloat) -> CGRect {
        let unit = self.unit
        let inset = bounds.insetBy(dx: margin, dy: margin)
        let x = inset.minX + (inset.width - size.width) * unit.x
        let y = inset.minY + (inset.height - size.height) * unit.y
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }
}

public struct StudioColor: Hashable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public init?(hex raw: String) {
        var text = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6 || text.count == 8, let value = UInt64(text, radix: 16) else {
            return nil
        }
        if text.count == 6 {
            red = Double((value >> 16) & 0xFF) / 255
            green = Double((value >> 8) & 0xFF) / 255
            blue = Double(value & 0xFF) / 255
            alpha = 1
        } else {
            red = Double((value >> 24) & 0xFF) / 255
            green = Double((value >> 16) & 0xFF) / 255
            blue = Double((value >> 8) & 0xFF) / 255
            alpha = Double(value & 0xFF) / 255
        }
    }

    public var hex: String {
        let components = [red, green, blue].map { Int(($0 * 255).rounded()) }
        let base = String(format: "#%02X%02X%02X", components[0], components[1], components[2])
        return alpha >= 0.999 ? base : base + String(format: "%02X", Int((alpha * 255).rounded()))
    }

    public var cgColor: CGColor {
        CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    public static let black = StudioColor(red: 0, green: 0, blue: 0)
    public static let white = StudioColor(red: 1, green: 1, blue: 1)
}

public struct StudioSettings: Codable, Hashable, Sendable {
    public var values: [String: StudioValue]

    public init(_ values: [String: StudioValue] = [:]) {
        self.values = values
    }

    public static func defaults(for options: [StudioOption]) -> StudioSettings {
        StudioSettings(Dictionary(uniqueKeysWithValues: options.map { ($0.key, $0.defaultValue) }))
    }

    public subscript(key: String) -> StudioValue? {
        get { values[key] }
        set { values[key] = newValue }
    }

    public func merged(over defaults: StudioSettings) -> StudioSettings {
        StudioSettings(defaults.values.merging(values) { _, own in own })
    }

    public func bool(_ key: String) -> Bool { values[key]?.bool ?? false }

    public func number(_ key: String) -> Double { values[key]?.number ?? 0 }

    public func int(_ key: String) -> Int { Int(number(key).rounded()) }

    public func text(_ key: String) -> String { values[key]?.text ?? "" }

    public func trimmed(_ key: String) -> String {
        text(key).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func rect(_ key: String) -> StudioRect { values[key]?.rect ?? .full }

    public func span(_ key: String) -> StudioSpan { values[key]?.span ?? .whole }

    public func color(_ key: String, fallback: StudioColor = .black) -> StudioColor {
        StudioColor(hex: text(key)) ?? fallback
    }

    public func anchor(_ key: String = "position") -> StudioAnchor {
        StudioAnchor(rawValue: text(key)) ?? .center
    }

    public func file(_ key: String) -> URL? {
        let path = trimmed(key)
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }
}
