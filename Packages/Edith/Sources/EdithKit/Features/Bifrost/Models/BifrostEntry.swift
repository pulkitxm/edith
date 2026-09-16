import Foundation

public struct BifrostEntry: Identifiable, Equatable, Sendable {
    public let id: String
    public let kind: BifrostResultKind
    public let title: String
    public let subtitle: String
    public let symbolName: String
    public let iconPath: String?
    public let terms: [String]
    public let action: BifrostAction
    public let copyText: String
    public let keyword: String?

    public init(
        id: String, kind: BifrostResultKind, title: String, subtitle: String,
        symbolName: String, iconPath: String? = nil, terms: [String] = [],
        action: BifrostAction, copyText: String, keyword: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.symbolName = symbolName
        self.iconPath = iconPath
        self.terms = terms
        self.action = action
        self.copyText = copyText
        self.keyword = keyword
    }

    public var searchText: String {
        ([title] + terms).joined(separator: " ")
    }

    public var target: BifrostMatchTarget {
        BifrostMatchTarget(searchText)
    }
}

public struct BifrostRunningApplication: Identifiable, Equatable, Sendable {
    public let bundleID: String
    public let name: String
    public let path: String?

    public var id: String { bundleID }

    public init(bundleID: String, name: String, path: String? = nil) {
        self.bundleID = bundleID
        self.name = name
        self.path = path
    }
}

public struct BifrostWindowHandle: Identifiable, Equatable, Sendable {
    public let processID: Int32
    public let ownerName: String
    public let title: String
    public let windowNumber: Int

    public var id: Int { windowNumber }

    public init(processID: Int32, ownerName: String, title: String, windowNumber: Int) {
        self.processID = processID
        self.ownerName = ownerName
        self.title = title
        self.windowNumber = windowNumber
    }
}
