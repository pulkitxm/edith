import Foundation

public enum BifrostMode: String, CaseIterable, Codable, Sendable {
    case launcher
    case clipboard
    case files

    public var title: String {
        switch self {
        case .launcher: "Bifrost"
        case .clipboard: "Clipboard History"
        case .files: "Search Files"
        }
    }

    public var placeholder: String {
        switch self {
        case .launcher: "Search apps, commands, sums and units"
        case .clipboard: "Type to filter entries"
        case .files: "Search files"
        }
    }

    public var primaryAction: String {
        switch self {
        case .launcher: "Open"
        case .clipboard: "Paste"
        case .files: "Open"
        }
    }

    public var symbolName: String {
        switch self {
        case .launcher: "rainbow"
        case .clipboard: "doc.on.clipboard"
        case .files: "magnifyingglass"
        }
    }

    public var showsDetail: Bool { self != .launcher }
}

public struct BifrostDetailRow: Identifiable, Equatable, Sendable {
    public let id: String
    public let label: String
    public let value: String

    public init(_ label: String, _ value: String) {
        id = label
        self.label = label
        self.value = value
    }
}

public struct BifrostDetail: Equatable, Sendable {
    public let title: String
    public let rows: [BifrostDetailRow]
    public let imagePath: String?
    public let text: String?

    public init(
        title: String, rows: [BifrostDetailRow], imagePath: String? = nil, text: String? = nil
    ) {
        self.title = title
        self.rows = rows
        self.imagePath = imagePath
        self.text = text
    }
}

public struct BifrostScope: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let path: String?
    public let machine: String?

    public init(id: String, title: String, path: String? = nil, machine: String? = nil) {
        self.id = id
        self.title = title
        self.path = path
        self.machine = machine
    }
}

public enum BifrostScopeCatalog {
    public static func clipboard() -> [BifrostScope] {
        [
            BifrostScope(id: "all", title: "All Types"),
            BifrostScope(id: "text", title: "Text"),
            BifrostScope(id: "link", title: "Links"),
            BifrostScope(id: "image", title: "Images"),
            BifrostScope(id: "file", title: "Files"),
        ]
    }

    public static func files(
        home: String = NSHomeDirectory(), machines: [String] = []
    ) -> [BifrostScope] {
        let name = (home as NSString).lastPathComponent
        var scopes = [
            BifrostScope(id: "home", title: "User (\(name))", path: home),
            BifrostScope(id: "desktop", title: "Desktop", path: home + "/Desktop"),
            BifrostScope(id: "documents", title: "Documents", path: home + "/Documents"),
            BifrostScope(id: "downloads", title: "Downloads", path: home + "/Downloads"),
            BifrostScope(id: "everywhere", title: "Everywhere"),
        ]
        for machine in machines {
            scopes.append(
                BifrostScope(id: "machine:" + machine, title: machine, machine: machine))
        }
        return scopes
    }

    public static func scopes(for mode: BifrostMode, machines: [String] = []) -> [BifrostScope] {
        switch mode {
        case .launcher: []
        case .clipboard: clipboard()
        case .files: files(machines: machines)
        }
    }
}
