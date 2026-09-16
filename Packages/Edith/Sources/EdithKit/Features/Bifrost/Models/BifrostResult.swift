import Foundation

public enum BifrostResultKind: String, Codable, Sendable {
    case application
    case calculation
    case conversion

    public var title: String {
        switch self {
        case .application: "Applications"
        case .calculation: "Calculator"
        case .conversion: "Conversion"
        }
    }
}

public enum BifrostAction: Equatable, Sendable {
    case launch(path: String)
    case copy(text: String)

    public var targetKey: String {
        switch self {
        case .launch(let path): "app:" + path
        case .copy: "copy"
        }
    }
}

public struct BifrostResult: Identifiable, Equatable, Sendable {
    public let id: String
    public let kind: BifrostResultKind
    public let title: String
    public let subtitle: String
    public let symbolName: String
    public let iconPath: String?
    public let action: BifrostAction
    public let score: Int

    public init(
        id: String, kind: BifrostResultKind, title: String, subtitle: String,
        symbolName: String, iconPath: String? = nil, action: BifrostAction, score: Int
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.symbolName = symbolName
        self.iconPath = iconPath
        self.action = action
        self.score = score
    }

    public var accessoryText: String {
        switch action {
        case .launch: "Open"
        case .copy: "Copy"
        }
    }
}
