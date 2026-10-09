import Foundation
import ExtensionMarketplace

public enum HostContract {
    public static let version = 1
    public static let compatibility = MarketplaceConfiguration.workerHostABI
}

public struct HostExtension: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let symbolName: String
    public let category: String

    public init(id: String, title: String, symbolName: String, category: String) {
        self.id = id
        self.title = title
        self.symbolName = symbolName
        self.category = category
    }
}

public enum HostIndex {
    public static func load(data: Data) throws -> [HostExtension] {
        let entries = try JSONDecoder().decode([HostExtension].self, from: data)
        guard !entries.isEmpty, Set(entries.map(\.id)).count == entries.count,
            entries.allSatisfy({
                !$0.id.isEmpty && $0.id.utf8.count <= 80
                    && $0.id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
                    && !$0.title.isEmpty && !$0.symbolName.isEmpty && !$0.category.isEmpty
            })
        else { throw CocoaError(.fileReadCorruptFile) }
        return entries
    }

    public static func bundled() throws -> [HostExtension] {
        let bundle = Bundle.main.bundleURL.pathExtension == "app" ? Bundle.main : Bundle.module
        guard let url = bundle.url(forResource: "index", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try load(data: Data(contentsOf: url))
    }
}

public struct HostIdentity: Sendable {
    public let identifier: String
    public let root: URL
    public let development: Bool

    public init(identifier: String, supportDirectory: URL) throws {
        guard
            identifier == "com.pulkit.edith"
                || identifier.hasPrefix("com.pulkit.edith.dev.")
                || identifier.hasPrefix("com.pulkit.edith.tests.")
        else { throw CocoaError(.validationMissingMandatoryProperty) }
        guard
            identifier.utf8.count <= 200
                && identifier.components(separatedBy: ".").allSatisfy({ !$0.isEmpty })
                && identifier.allSatisfy({
                    $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-")
                })
        else { throw CocoaError(.validationMissingMandatoryProperty) }
        self.identifier = identifier
        development = identifier != "com.pulkit.edith"
        if development {
            let slot = identifier.components(separatedBy: ".").dropFirst(4).joined(separator: ".")
            guard !slot.isEmpty else { throw CocoaError(.validationMissingMandatoryProperty) }
            let namespace =
                identifier.hasPrefix("com.pulkit.edith.tests.") ? "Edith Tests" : "Edith Dev"
            root = supportDirectory.appendingPathComponent(namespace, isDirectory: true)
                .appendingPathComponent(slot, isDirectory: true)
        } else {
            root = supportDirectory.appendingPathComponent("Edith", isDirectory: true)
        }
    }

    public var defaultsSuite: String { identifier + ".host" }

    public func extensionDirectory(_ id: String) -> URL {
        root.appendingPathComponent("Data", isDirectory: true).appendingPathComponent(
            id, isDirectory: true)
    }

    public func extensionDefaultsSuite(_ id: String) -> String {
        identifier + ".extensions." + id
    }
}
