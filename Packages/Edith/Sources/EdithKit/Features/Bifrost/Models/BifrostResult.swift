import Foundation

public enum BifrostResultKind: String, Codable, Sendable {
    case application
    case command
    case calculation
    case conversion

    public var title: String {
        switch self {
        case .application: "Applications"
        case .command: "Commands"
        case .calculation: "Calculator"
        case .conversion: "Conversion"
        }
    }

    public var accessory: String {
        switch self {
        case .application: "Application"
        case .command: "Command"
        case .calculation: "Answer"
        case .conversion: "Answer"
        }
    }
}

public enum BifrostAction: Equatable, Sendable {
    case launch(path: String)
    case run(commandID: String)
    case copy(text: String)

    public var targetKey: String {
        switch self {
        case .launch(let path): "app:" + path
        case .run(let commandID): "command:" + commandID
        case .copy: "copy"
        }
    }

    public var copyText: String {
        switch self {
        case .launch(let path): path
        case .run(let commandID): commandID
        case .copy(let text): text
        }
    }

    public var isRepeatable: Bool {
        switch self {
        case .launch, .run: true
        case .copy: false
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
        kind.accessory
    }
}
