import EdithExtensionSupport
import EdithIcons
import Foundation
import os
import ExtensionMarketplace

public enum HostContract {
    public static let version = 1
    public static let compatibility = MarketplaceConfiguration.workerHostABI

    public static func accepts(_ hostABI: String) -> Bool {
        ExtensionHostABI.accepts(hostABI, host: compatibility)
    }

    public static func permitsLaunching(
        identifier: String?, bundleURL: URL,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Bool {
        guard identifier == "com.pulkit.edith" else { return true }
        let installed = [
            URL(fileURLWithPath: "/Applications"),
            homeDirectory.appendingPathComponent("Applications"),
        ].map { canonicalPath($0.appendingPathComponent("Edith.app")) }
        return installed.contains(canonicalPath(bundleURL))
    }

    private static func canonicalPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}

public struct HostHotKey: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let prefix: String
    public let title: String
    public let subtitle: String
    public let code: Int
    public let modifiers: Int
    public let label: String

    public init(
        id: String, prefix: String, title: String, subtitle: String, code: Int, modifiers: Int,
        label: String
    ) {
        self.id = id
        self.prefix = prefix
        self.title = title
        self.subtitle = subtitle
        self.code = code
        self.modifiers = modifiers
        self.label = label
    }
}

public struct HostLaunchCondition: Codable, Hashable, Sendable {
    public let key: String
    public let `default`: Bool

    public init(key: String, default: Bool) {
        self.key = key
        self.default = `default`
    }

    public func holds(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: key) as? Bool ?? self.default
    }
}

public struct HostPage: Codable, Hashable, Sendable {
    public let detachable: Bool

    public init(detachable: Bool = true) {
        self.detachable = detachable
    }
}

public struct HostGuideStep: Codable, Hashable, Sendable {
    public let icon: EdithIcon
    public let title: String
    public let detail: String

    public init(icon: EdithIcon, title: String, detail: String) {
        self.icon = icon
        self.title = title
        self.detail = detail
    }
}

public struct HostExtensionGuide: Codable, Hashable, Sendable {
    public let tagline: String
    public let summary: String
    public let steps: [HostGuideStep]
    public let examples: [String]

    public init(tagline: String, summary: String, steps: [HostGuideStep], examples: [String] = []) {
        self.tagline = tagline
        self.summary = summary
        self.steps = steps
        self.examples = examples
    }
}

public struct HostExtension: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let icon: EdithIcon
    public let category: String
    public let background: Bool
    public let commands: [String]
    public let hotkeys: [HostHotKey]
    public let launchWhen: [HostLaunchCondition]
    public let page: HostPage?
    public let homeCards: [String]
    public let notchCards: [String]
    public let notchTabs: [String]
    public let guide: HostExtensionGuide?

    public init(
        id: String, title: String, icon: EdithIcon, category: String,
        background: Bool = true, commands: [String] = [], hotkeys: [HostHotKey] = [],
        launchWhen: [HostLaunchCondition] = [], page: HostPage? = nil, homeCards: [String] = [],
        notchCards: [String] = [], notchTabs: [String] = [], guide: HostExtensionGuide? = nil
    ) {
        self.id = id
        self.title = title
        self.icon = icon
        self.category = category
        self.background = background
        self.commands = commands
        self.hotkeys = hotkeys
        self.launchWhen = launchWhen
        self.page = page
        self.homeCards = homeCards
        self.notchCards = notchCards
        self.notchTabs = notchTabs
        self.guide = guide
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
                    && !$0.title.isEmpty && !$0.category.isEmpty
                    && validSurfaces($0)
            })
        else { throw CocoaError(.fileReadCorruptFile) }
        return entries
    }

    private static func validSurfaces(_ entry: HostExtension) -> Bool {
        for cards in [entry.homeCards, entry.notchCards] {
            guard Set(cards).count == cards.count,
                cards.allSatisfy({
                    guard let widget = SurfaceWidget(rawValue: $0), widget != .clocks else {
                        return false
                    }
                    if case .ability(let id) = widget { return id == entry.id }
                    return true
                })
            else { return false }
        }
        return Set(entry.notchTabs).count == entry.notchTabs.count
            && entry.notchTabs.allSatisfy {
                guard let tab = SurfaceNotchTab(rawValue: $0) else { return false }
                return tab != .home
            }
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
        if let cached = bundledCache.withLock({ $0[url] }) { return cached }
        let entries = try load(data: Data(contentsOf: url))
        bundledCache.withLock { $0[url] = entries }
        return entries
    }

    private static let bundledCache = OSAllocatedUnfairLock(initialState: [URL: [HostExtension]]())

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
