import Foundation

extension EdithIcon {
    public static let fallback = EdithIcon.placeholder

    private static let byName: [String: EdithIcon] = {
        var table = aliases
        for icon in allCases { table[icon.rawValue] = icon }
        return table
    }()

    public static var names: [String] { byName.keys.sorted() }

    public init(name: String) {
        self = Self.named(name) ?? Self.fallback
    }

    public static func named(_ name: String) -> EdithIcon? { byName[name] }

    public static func isValid(name: String) -> Bool { byName[name] != nil }
}

extension EdithIcon: Codable {
    public init(from decoder: any Decoder) throws {
        self.init(name: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
