import Darwin
import EdithCore
import Foundation

public enum AppMaintenanceOperation: String, CaseIterable, Sendable {
    case inventory
    case scan
    case remove
    case install

    public var descriptor: UserOperationDescriptor {
        switch self {
        case .inventory:
            UserOperationDescriptor(
                id: UserOperationID(rawValue: "maintenance.inventory"),
                summary: "List installed applications and available Homebrew updates.",
                cli: ["maintenance", "inventory"], effect: .read)
        case .scan:
            UserOperationDescriptor(
                id: UserOperationID(rawValue: "maintenance.scan"),
                summary: "Preview an application and its exact support files.",
                cli: ["maintenance", "scan"], effect: .read)
        case .remove:
            UserOperationDescriptor(
                id: UserOperationID(rawValue: "maintenance.remove"),
                summary: "Move a reviewed application selection to the Trash.",
                cli: ["maintenance", "remove"], effect: .destructive,
                requiresPreview: true)
        case .install:
            UserOperationDescriptor(
                id: UserOperationID(rawValue: "maintenance.install"),
                summary: "Verify and install the single app inside a disk image.",
                cli: ["maintenance", "install"], effect: .destructive,
                requiresPreview: true)
        }
    }
}

public struct AppMaintenanceUpdate: Equatable, Sendable {
    public let source: String
    public let installedVersion: String
    public let latestVersion: String

    public init(source: String, installedVersion: String, latestVersion: String) {
        self.source = source
        self.installedVersion = installedVersion
        self.latestVersion = latestVersion
    }
}

public struct InstalledApplication: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let bundleID: String
    public let version: String
    public let url: URL
    public let update: AppMaintenanceUpdate?

    public init(
        id: String, name: String, bundleID: String, version: String, url: URL,
        update: AppMaintenanceUpdate? = nil
    ) {
        self.id = id
        self.name = name
        self.bundleID = bundleID
        self.version = version
        self.url = url
        self.update = update
    }
}

public enum AppMaintenanceCategory: String, CaseIterable, Sendable {
    case application = "Application"
    case support = "Application Support"
    case caches = "Caches"
    case preferences = "Preferences"
    case containers = "Containers"
    case logs = "Logs"
    case state = "Saved State"
    case web = "Web Data"
}

public struct AppMaintenanceFileIdentity: Equatable, Sendable {
    public let device: UInt64
    public let inode: UInt64

    public init(device: UInt64, inode: UInt64) {
        self.device = device
        self.inode = inode
    }
}

public struct AppMaintenanceItem: Identifiable, Equatable, Sendable {
    public let id: String
    public let url: URL
    public let category: AppMaintenanceCategory
    public let sizeBytes: Int64
    public let identity: AppMaintenanceFileIdentity

    public init(
        id: String, url: URL, category: AppMaintenanceCategory, sizeBytes: Int64,
        identity: AppMaintenanceFileIdentity
    ) {
        self.id = id
        self.url = url
        self.category = category
        self.sizeBytes = sizeBytes
        self.identity = identity
    }
}

public struct AppMaintenancePlan: Equatable, Sendable {
    public let application: InstalledApplication
    public let items: [AppMaintenanceItem]
    public let roots: [URL]
    public let applicationInfoIdentity: AppMaintenanceFileIdentity

    public init(
        application: InstalledApplication, items: [AppMaintenanceItem], roots: [URL],
        applicationInfoIdentity: AppMaintenanceFileIdentity
    ) {
        self.application = application
        self.items = items
        self.roots = roots
        self.applicationInfoIdentity = applicationInfoIdentity
    }

    public var totalBytes: Int64 { items.reduce(0) { $0 + $1.sizeBytes } }
}

public struct AppMaintenanceRemovalResult: Equatable, Sendable {
    public let removed: [AppMaintenanceItem]
    public let failed: [AppMaintenanceItem]

    public init(removed: [AppMaintenanceItem], failed: [AppMaintenanceItem]) {
        self.removed = removed
        self.failed = failed
    }

    public var reclaimedBytes: Int64 { removed.reduce(0) { $0 + $1.sizeBytes } }
}

public enum AppMaintenanceError: LocalizedError, Equatable {
    case invalidApplication
    case protectedApplication
    case applicationChanged
    case emptySelection

    public var errorDescription: String? {
        switch self {
        case .invalidApplication:
            "Choose a regular app directly inside Applications."
        case .protectedApplication:
            "Edith and Apple system applications cannot be removed here."
        case .applicationChanged:
            "The application changed after it was reviewed. Scan it again."
        case .emptySelection:
            "Select at least one reviewed item."
        }
    }
}

public enum AppMaintenanceInventory {
    public static func applications(
        roots: [URL] = defaultApplicationRoots,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        updateData: Data? = nil
    ) -> [InstalledApplication] {
        let fileManager = FileManager.default
        var found: [InstalledApplication] = []
        var seen = Set<String>()
        for root in roots {
            let entries =
                (try? fileManager.contentsOfDirectory(
                    at: root,
                    includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                    options: [.skipsHiddenFiles])) ?? []
            for url in entries {
                let normalized = url.standardizedFileURL
                guard normalized.pathExtension.caseInsensitiveCompare("app") == .orderedSame,
                    normalized.deletingLastPathComponent() == root.standardizedFileURL,
                    seen.insert(normalized.path).inserted,
                    let values = try? normalized.resourceValues(forKeys: [
                        .isDirectoryKey, .isSymbolicLinkKey,
                    ]),
                    values.isDirectory == true, values.isSymbolicLink != true,
                    let bundle = Bundle(url: normalized),
                    let bundleID = verifiedBundleID(bundle.bundleIdentifier),
                    !isProtected(bundleID: bundleID, url: normalized)
                else { continue }
                let rawName =
                    bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                    ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
                    ?? normalized.deletingPathExtension().lastPathComponent
                let name = displayName(
                    rawName, fallback: normalized.deletingPathExtension().lastPathComponent)
                let version =
                    bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                    ?? bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
                    ?? "Unknown"
                found.append(
                    InstalledApplication(
                        id: normalized.path, name: name, bundleID: bundleID,
                        version: displayName(version, fallback: "Unknown"), url: normalized))
            }
        }
        return applyingHomebrewUpdates(updateData, to: found).sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    public static func applicationsWithUpdates(
        roots: [URL] = defaultApplicationRoots,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        homebrewPaths: [String] = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"],
        run: @escaping AppMaintenanceDiskImageInstaller.RunCommand =
            AppMaintenanceDiskImageInstaller.liveRun
    ) async -> [InstalledApplication] {
        let data = await homebrewOutdatedData(paths: homebrewPaths, run: run)
        return applications(roots: roots, home: home, updateData: data)
    }

    public static func applyingHomebrewUpdates(
        _ data: Data?, to applications: [InstalledApplication]
    ) -> [InstalledApplication] {
        guard let data,
            let document = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let casks = document["casks"] as? [[String: Any]]
        else { return applications }
        var updates: [String: (installed: String, latest: String)] = [:]
        for cask in casks {
            guard let token = cask["name"] as? String,
                let versions = cask["installed_versions"] as? [String],
                let installed = versions.first,
                let latest = cask["current_version"] as? String,
                !installed.isEmpty, !latest.isEmpty
            else { continue }
            updates[normalizedName(token)] = (installed, latest)
        }
        let applicationKeys = Dictionary(
            grouping: applications, by: { normalizedName($0.name) })
        return applications.map { app in
            let key = normalizedName(app.name)
            guard applicationKeys[key]?.count == 1, let update = updates[key],
                normalizedVersion(app.version) != normalizedVersion(update.latest)
            else { return app }
            return InstalledApplication(
                id: app.id, name: app.name, bundleID: app.bundleID, version: app.version,
                url: app.url,
                update: AppMaintenanceUpdate(
                    source: "Homebrew", installedVersion: update.installed,
                    latestVersion: update.latest))
        }
    }

    public static var defaultApplicationRoots: [URL] {
        [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
                "Applications", isDirectory: true),
        ]
    }

    public static func verifiedBundleID(_ rawValue: String?) -> String? {
        guard let rawValue, rawValue.count <= 255,
            rawValue.split(separator: ".").count >= 2,
            rawValue.unicodeScalars.allSatisfy({ scalar in
                CharacterSet.alphanumerics.contains(scalar) || scalar == "." || scalar == "-"
                    || scalar == "_"
            }), !rawValue.contains("..")
        else { return nil }
        return rawValue
    }

    public static func isProtected(bundleID: String, url: URL) -> Bool {
        bundleID == "com.pulkit.edith" || bundleID == "com.pulkit.edith.main"
            || bundleID.hasPrefix("com.apple.") || url.path.hasPrefix("/System/")
    }

    private static func displayName(_ rawValue: String, fallback: String) -> String {
        let flattened = rawValue.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
                && !CharacterSet.illegalCharacters.contains($0)
        }
        let value = String(String.UnicodeScalarView(flattened)).trimmingCharacters(
            in: .whitespacesAndNewlines)
        return value.isEmpty ? fallback : String(value.prefix(120))
    }

    private static func normalizedName(_ value: String) -> String {
        String(value.lowercased().unicodeScalars.filter(CharacterSet.alphanumerics.contains))
    }

    private static func normalizedVersion(_ value: String) -> String {
        value.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func homebrewOutdatedData(
        paths: [String],
        run: @escaping AppMaintenanceDiskImageInstaller.RunCommand
    ) async -> Data? {
        guard let executable = paths.first(where: FileManager.default.isExecutableFile) else {
            return nil
        }
        var environment = CLIToolEnvironment.sanitized()
        environment["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        let request = CLICommandRequest(
            executableURL: URL(fileURLWithPath: executable),
            arguments: ["outdated", "--cask", "--greedy", "--json=v2"],
            environment: environment, timeout: 60, maximumOutputBytes: 2 * 1_024 * 1_024,
            terminatesProcessGroup: true)
        guard let result = try? await run(request), result.terminationStatus == 0 else {
            return nil
        }
        return result.outputData
    }
}

public enum AppMaintenanceExecution {
    public static func plan(
        applicationURL: URL,
        applicationRoots: [URL] = AppMaintenanceInventory.defaultApplicationRoots,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> AppMaintenancePlan {
        let appURL = applicationURL.standardizedFileURL
        let infoURL = appURL.appendingPathComponent("Contents/Info.plist")
        guard
            applicationRoots.map(\.standardizedFileURL).contains(
                appURL.deletingLastPathComponent()),
            appURL.pathExtension.caseInsensitiveCompare("app") == .orderedSame,
            !isSymbolicLink(appURL), !isSymbolicLink(infoURL),
            let infoIdentity = identity(at: infoURL), let bundle = Bundle(url: appURL),
            let bundleID = AppMaintenanceInventory.verifiedBundleID(bundle.bundleIdentifier)
        else { throw AppMaintenanceError.invalidApplication }
        guard !AppMaintenanceInventory.isProtected(bundleID: bundleID, url: appURL) else {
            throw AppMaintenanceError.protectedApplication
        }
        let apps = AppMaintenanceInventory.applications(
            roots: applicationRoots, home: home, updateData: Data())
        guard let application = apps.first(where: { $0.url == appURL }) else {
            throw AppMaintenanceError.invalidApplication
        }
        let library = home.appendingPathComponent("Library", isDirectory: true)
        let definitions: [(AppMaintenanceCategory, URL, String)] = [
            (
                .support, library.appendingPathComponent("Application Support", isDirectory: true),
                bundleID
            ),
            (.caches, library.appendingPathComponent("Caches", isDirectory: true), bundleID),
            (
                .preferences, library.appendingPathComponent("Preferences", isDirectory: true),
                "\(bundleID).plist"
            ),
            (
                .containers, library.appendingPathComponent("Containers", isDirectory: true),
                bundleID
            ),
            (.logs, library.appendingPathComponent("Logs", isDirectory: true), bundleID),
            (
                .state,
                library.appendingPathComponent("Saved Application State", isDirectory: true),
                "\(bundleID).savedState"
            ),
            (.web, library.appendingPathComponent("HTTPStorages", isDirectory: true), bundleID),
            (.web, library.appendingPathComponent("WebKit", isDirectory: true), bundleID),
        ]
        var items: [AppMaintenanceItem] = []
        if let item = item(
            appURL, category: .application, within: appURL.deletingLastPathComponent())
        {
            items.append(item)
        }
        for (category, root, name) in definitions {
            let candidate = root.appendingPathComponent(name).standardizedFileURL
            if let item = item(candidate, category: category, within: root) { items.append(item) }
        }
        return AppMaintenancePlan(
            application: application, items: items,
            roots: applicationRoots + definitions.map { $0.1 },
            applicationInfoIdentity: infoIdentity)
    }

    public static func remove(
        plan: AppMaintenancePlan, selectedIDs: Set<String>,
        trash: (URL) throws -> Void = {
            try FileManager.default.trashItem(at: $0, resultingItemURL: nil)
        }
    ) throws -> AppMaintenanceRemovalResult {
        let selected = plan.items.filter { selectedIDs.contains($0.id) }
        guard !selected.isEmpty else { throw AppMaintenanceError.emptySelection }
        guard let target = plan.items.first(where: { $0.category == .application }),
            identity(at: target.url) == target.identity,
            identity(at: target.url.appendingPathComponent("Contents/Info.plist"))
                == plan.applicationInfoIdentity
        else { throw AppMaintenanceError.applicationChanged }
        var removed: [AppMaintenanceItem] = []
        var failed: [AppMaintenanceItem] = []
        for item in selected {
            guard identity(at: item.url) == item.identity,
                plan.roots.contains(where: { removalPathIsSafe(item.url, within: $0) })
            else {
                failed.append(item)
                continue
            }
            do {
                try trash(item.url)
                removed.append(item)
            } catch {
                failed.append(item)
            }
        }
        return AppMaintenanceRemovalResult(removed: removed, failed: failed)
    }

    public static func identity(at url: URL) -> AppMaintenanceFileIdentity? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        return AppMaintenanceFileIdentity(device: UInt64(info.st_dev), inode: UInt64(info.st_ino))
    }

    public static func removalPathIsSafe(_ url: URL, within root: URL) -> Bool {
        let candidate = url.standardizedFileURL
        let root = root.standardizedFileURL
        guard candidate.deletingLastPathComponent() == root,
            candidate.path.hasPrefix(root.path + "/"), !isSymbolicLink(candidate)
        else { return false }
        return true
    }

    private static func item(
        _ url: URL, category: AppMaintenanceCategory, within root: URL
    ) -> AppMaintenanceItem? {
        guard FileManager.default.fileExists(atPath: url.path),
            removalPathIsSafe(url, within: root), let identity = identity(at: url)
        else { return nil }
        return AppMaintenanceItem(
            id: url.path, url: url, category: category,
            sizeBytes: JunkScanner.directorySize(url), identity: identity)
    }

    private static func isSymbolicLink(_ url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFLNK
    }
}
