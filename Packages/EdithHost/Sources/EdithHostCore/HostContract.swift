import EdithExtensionSupport
import Foundation
import ExtensionMarketplace

public enum HostContract {
    public static let version = 1
    public static let compatibility = MarketplaceConfiguration.workerHostABI

    public static func permitsLaunching(identifier: String?, bundleURL: URL) -> Bool {
        identifier != "com.pulkit.edith"
            || bundleURL.standardizedFileURL.path == "/Applications/Edith.app"
    }
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

private final class HostIndexResourceAnchor: NSObject {}

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
        guard let executableURL = Bundle.main.executableURL else {
            throw CocoaError(.fileNoSuchFile)
        }
        let main = Bundle.main.bundleURL
        let owner = Bundle(for: HostIndexResourceAnchor.self).bundleURL
        let bundle =
            !["app", "appex"].contains(main.pathExtension)
                && owner.pathExtension == "xctest" ? owner : main
        let url = try resourceURL(bundleURL: bundle, executableURL: executableURL)
        return try load(data: Data(contentsOf: url))
    }

    static func resourceURL(bundleURL: URL, executableURL: URL) throws -> URL {
        let resource: URL
        if ["app", "appex"].contains(bundleURL.pathExtension) {
            resource = bundleURL.appendingPathComponent("Contents/Resources/index.json")
        } else {
            var directory = executableURL.deletingLastPathComponent()
            if bundleURL.pathExtension == "xctest" {
                directory = bundleURL.deletingLastPathComponent()
            } else {
                for _ in 0..<3 {
                    if directory.pathExtension == "xctest" {
                        directory = directory.deletingLastPathComponent()
                        break
                    }
                    if directory.lastPathComponent != "MacOS"
                        && directory.lastPathComponent != "Contents"
                    {
                        break
                    }
                    directory.deleteLastPathComponent()
                }
            }
            resource = directory.appendingPathComponent("EdithHost_EdithHostCore.bundle/index.json")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resource.path, isDirectory: &isDirectory),
            !isDirectory.boolValue
        else {
            throw CocoaError(.fileNoSuchFile)
        }
        return resource
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

    public func effectiveExtensionDirectory(_ id: String) -> URL {
        ExtensionData.resolve(
            environment: [
                "EDITH_APPLICATION_IDENTIFIER": identifier,
                "EDITH_EXTENSION_ID": id,
                "EDITH_EXTENSION_DATA_ROOT": extensionDirectory(id).path,
            ], fallback: extensionDirectory(id))
    }

    public func persistentExtensionLocations(_ id: String) -> [URL] {
        guard !development, let leaves = ExtensionData.productionLeaves[id] else {
            return [extensionDirectory(id)]
        }
        return leaves.map { root.appendingPathComponent($0) }
    }

    public var applicationDefaultsSuite: String {
        development ? identifier : identifier + ".shared"
    }

    public func extensionDefaultsSuite(_ id: String) -> String {
        development ? identifier + ".extensions." + id : applicationDefaultsSuite
    }
}
