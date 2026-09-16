import Foundation

public enum BifrostResultKind: String, Codable, Sendable {
    case application
    case command
    case calculation
    case conversion
    case clip
    case file
    case quicklink
    case snippet
    case shellCommand
    case shortcut
    case windowAction
    case systemAction
    case runningApp
    case openWindow

    public var title: String {
        switch self {
        case .application: "Applications"
        case .command: "Commands"
        case .calculation: "Calculator"
        case .conversion: "Conversion"
        case .clip: "History"
        case .file: "Files"
        case .quicklink: "Quicklinks"
        case .snippet: "Snippets"
        case .shellCommand: "Shell Commands"
        case .shortcut: "Shortcuts"
        case .windowAction: "Window Management"
        case .systemAction: "System"
        case .runningApp: "Running Apps"
        case .openWindow: "Open Windows"
        }
    }

    public var accessory: String {
        switch self {
        case .application: "Application"
        case .command: "Command"
        case .calculation: "Answer"
        case .conversion: "Answer"
        case .clip: "Clipboard"
        case .file: "File"
        case .quicklink: "Quicklink"
        case .snippet: "Snippet"
        case .shellCommand: "Command"
        case .shortcut: "Shortcut"
        case .windowAction: "Window"
        case .systemAction: "System"
        case .runningApp: "Running"
        case .openWindow: "Window"
        }
    }
}

public enum BifrostAction: Equatable, Sendable {
    case launch(path: String)
    case run(commandID: String)
    case copy(text: String)
    case quicklink(id: String)
    case snippet(id: String)
    case shell(id: String)
    case shortcut(name: String)
    case window(BifrostWindowAction)
    case system(BifrostSystemAction)
    case activate(bundleID: String)
    case quit(bundleID: String)
    case focusWindow(processID: Int32, title: String)

    public var targetKey: String {
        switch self {
        case .launch(let path): "app:" + path
        case .run(let commandID): "command:" + commandID
        case .copy: "copy"
        case .quicklink(let id): "quicklink:" + id
        case .snippet(let id): "snippet:" + id
        case .shell(let id): "shell:" + id
        case .shortcut(let name): "shortcut:" + name
        case .window(let action): "window:" + action.rawValue
        case .system(let action): "system:" + action.rawValue
        case .activate(let bundleID): "activate:" + bundleID
        case .quit(let bundleID): "quit:" + bundleID
        case .focusWindow(let processID, let title): "focus:\(processID):" + title
        }
    }

    public var copyText: String {
        switch self {
        case .launch(let path): path
        case .run(let commandID): commandID
        case .copy(let text): text
        case .quicklink(let id): id
        case .snippet(let id): id
        case .shell(let id): id
        case .shortcut(let name): name
        case .window(let action): action.title
        case .system(let action): action.title
        case .activate(let bundleID): bundleID
        case .quit(let bundleID): bundleID
        case .focusWindow(_, let title): title
        }
    }

    public var isRepeatable: Bool {
        switch self {
        case .copy: false
        default: true
        }
    }

    public var primaryVerb: String {
        switch self {
        case .launch, .quicklink: "Open"
        case .run, .shell, .shortcut, .window, .system: "Run"
        case .copy: "Copy"
        case .snippet: "Insert"
        case .activate, .focusWindow: "Switch"
        case .quit: "Quit"
        }
    }
}

public struct BifrostAnswer: Equatable, Sendable {
    public let input: String
    public let output: String
    public let inputCaption: String
    public let outputCaption: String
    public let footnote: String?

    public init(
        input: String, output: String, inputCaption: String = "", outputCaption: String = "",
        footnote: String? = nil
    ) {
        self.input = input
        self.output = output
        self.inputCaption = inputCaption
        self.outputCaption = outputCaption
        self.footnote = footnote
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
    public let answer: BifrostAnswer?
    public let detail: BifrostDetail?
    public let group: String?
    private let explicitCopyText: String?

    public init(
        id: String, kind: BifrostResultKind, title: String, subtitle: String,
        symbolName: String, iconPath: String? = nil, action: BifrostAction, score: Int,
        answer: BifrostAnswer? = nil, detail: BifrostDetail? = nil, group: String? = nil,
        copyText: String? = nil
    ) {
        explicitCopyText = copyText
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.symbolName = symbolName
        self.iconPath = iconPath
        self.action = action
        self.score = score
        self.answer = answer
        self.detail = detail
        self.group = group
    }

    public var accessoryText: String {
        kind.accessory
    }

    public var copyText: String {
        explicitCopyText ?? action.copyText
    }
}
