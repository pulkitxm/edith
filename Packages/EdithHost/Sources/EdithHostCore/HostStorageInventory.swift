import EdithExtensionSupport
import ExtensionMarketplace
import Foundation

public struct HostStorageVersion: Sendable, Identifiable {
    public let package: ExtensionPackage
    public let state: String
    public let compatible: Bool
    public let scopeIDs: [String]
    public let executableScopeIDs: [String]
    public let frameworkScopeIDs: [String]
    public var id: String { scopeIDs[0] }

    public func bytes(in measurement: HostStorageMeasurement) -> HostStorageBytes {
        measurement.sum(scopeIDs)
    }
}

public struct HostStorageExtension: Sendable, Identifiable {
    public let id: String
    public let title: String
    public let versions: [HostStorageVersion]
    public let catalogVersion: String?
    public let compressedDownloadBytes: Int64?
    public let pendingRemoval: Bool
    public var dataScopeID: String { "data:" + id }
    public var preservedDataScopeIDs: [String] = []
    public var sharedPreferences = false
    public var sharedDataScopeIDs: [String] = []
    public var dataScopeIDs: [String] {
        [dataScopeID] + preservedDataScopeIDs + (sharedPreferences ? [] : ["preferences:" + id])
    }

    public func packageBytes(in measurement: HostStorageMeasurement) -> HostStorageBytes {
        measurement.sum(versions.flatMap(\.scopeIDs))
    }
}

public struct HostStorageCategory: Sendable, Identifiable {
    public let id: String
    public let title: String
    public let scopeIDs: [String]

    public func bytes(in measurement: HostStorageMeasurement) -> HostStorageBytes {
        measurement.sum(scopeIDs)
    }
}

public struct HostStorageItem: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let symbolName: String
    public let extensionID: String?
    public let roots: [URL]
    public let scopeIDs: [String]

    public func bytes(in measurement: HostStorageMeasurement) -> HostStorageBytes {
        measurement.sum(scopeIDs)
    }
}

public struct HostStorageUsage: Identifiable, Sendable {
    public let item: HostStorageItem
    public let bytes: HostStorageBytes
    public var id: String { item.id }
}

public struct HostStorageEntry: Identifiable, Sendable {
    public let url: URL
    public let isDirectory: Bool
    public let bytes: HostStorageBytes
    public var id: String { url.path }
}

public struct HostStorageInventory: Sendable {
    public let scopes: [HostStorageScope]
    public let extensions: [HostStorageExtension]
    public let categories: [HostStorageCategory]
    public let items: [HostStorageItem]
    public let appVersion: String?
    public let hostABI: String

    @MainActor
    public init(
        marketplace: HostMarketplace, appBundle: URL, appVersion: String?,
        preferencesDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences"),
        ownerDefaults: UserDefaults = SharedDefaults.store,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        systemVersion: ExtensionSystemVersion = .init(
            ProcessInfo.processInfo.operatingSystemVersion)
    ) throws {
        let store = marketplace.packageStore
        let identity = marketplace.identity
        var scopes: [HostStorageScope] = [
            .init(id: "app", root: appBundle, expected: true),
            .init(id: "host-data", root: identity.root),
            .init(id: "package-cache", root: store.root),
            .init(id: "cache", root: identity.root.appendingPathComponent("Caches")),
            .init(id: "logs", root: identity.root.appendingPathComponent("Logs")),
            .init(id: "catalog-cache", root: identity.root.appendingPathComponent("catalog.json")),
            .init(
                id: "host-preferences",
                root: preferencesDirectory.appendingPathComponent(identity.defaultsSuite + ".plist")
            ),
        ]
        if !identity.development {
            let library = identity.root.deletingLastPathComponent().deletingLastPathComponent()
            scopes.append(
                .init(id: "preserved-cache", root: library.appendingPathComponent("Caches/Edith")))
            scopes.append(
                .init(id: "preserved-logs", root: library.appendingPathComponent("Logs/Edith")))
            scopes.append(
                .init(
                    id: "shared-preferences",
                    root: preferencesDirectory.appendingPathComponent(
                        identity.applicationDefaultsSuite + ".plist")))
        }
        let known = Dictionary(uniqueKeysWithValues: marketplace.entries.map { ($0.id, $0.title) })
        let symbols = Dictionary(
            uniqueKeysWithValues: marketplace.entries.map { ($0.id, $0.symbolName) })
        let ids = Set(known.keys).union(marketplace.installedVersions.keys).sorted()
        var extensions: [HostStorageExtension] = []
        var packageKeys: [String: [String]] = [:]
        for id in ids {
            guard ExtensionPackage.validComponent(id) else { throw MarketplaceError.invalidCatalog }
            scopes.append(.init(id: "data:" + id, root: identity.extensionDirectory(id)))
            var preservedIDs: [String] = []
            if identity.development {
                scopes.append(
                    .init(
                        id: "preferences:" + id,
                        root: preferencesDirectory.appendingPathComponent(
                            identity.extensionDefaultsSuite(id) + ".plist")))
            } else {
                for (index, relative) in (ExtensionData.productionLeaves[id] ?? []).enumerated() {
                    let key = "preserved-data:" + id + ":" + String(index)
                    preservedIDs.append(key)
                    scopes.append(
                        .init(id: key, root: identity.root.appendingPathComponent(relative)))
                }
            }
            if id == "music",
                let custom = ExtensionData.selectedMusicDirectory(
                    defaults: ownerDefaults, homeDirectory: homeDirectory),
                !identity.persistentExtensionLocations(id).contains(custom)
            {
                let key = "music-selected-directory"
                scopes.append(.init(id: key, root: custom))
            }
            var versions: [HostStorageVersion] = []
            let installed = (marketplace.installedVersions[id] ?? []).sorted {
                if $0.version != $1.version {
                    return $0.version.compare($1.version, options: .numeric) == .orderedDescending
                }
                return $0.hostABI + $0.architecture < $1.hostABI + $1.architecture
            }
            for package in installed {
                guard package.id == id, ExtensionPackage.validComponent(package.version),
                    ExtensionPackage.validComponent(package.hostABI),
                    ["arm64", "x86_64"].contains(package.architecture)
                else { throw MarketplaceError.invalidCatalog }
                let key =
                    "package:\(id):\(package.hostABI):\(package.architecture):\(package.version)"
                let directory = store.directory(for: package)
                let layout = HostStoragePackageScopes(
                    key: key, directory: directory, extensionID: id,
                    roles: ExtensionBundleRuntime.Role.allCases.map(\.rawValue))
                let executableIDs = layout.executableScopeIDs
                let frameworkIDs = layout.frameworkScopeIDs
                scopes.append(contentsOf: layout.scopes)
                packageKeys[id, default: []].append(key)
                let selected = marketplace.installed[id] == package
                let running =
                    marketplace.sessions.versions[id] == package.version
                    && marketplace.sessions.enabledIDs.contains(id)
                    && package.isCompatible(
                        hostABI: HostContract.compatibility, architecture: "arm64",
                        systemVersion: systemVersion)
                let state: String
                if marketplace.pendingRemovalIDs.contains(id) {
                    state = "Pending removal"
                } else if running {
                    state =
                        marketplace.sessions.states[id] == .active
                        ? "Active" : "Enabled, cleanup or startup pending"
                } else if selected {
                    state = "Downloaded, disabled"
                } else {
                    state = "Retained version"
                }
                versions.append(
                    HostStorageVersion(
                        package: package, state: state,
                        compatible: package.isCompatible(
                            hostABI: HostContract.compatibility, architecture: "arm64",
                            systemVersion: systemVersion),
                        scopeIDs: [key] + executableIDs + frameworkIDs,
                        executableScopeIDs: executableIDs, frameworkScopeIDs: frameworkIDs))
            }
            let catalog = marketplace.available[id]
            extensions.append(
                HostStorageExtension(
                    id: id, title: known[id] ?? id, versions: versions,
                    catalogVersion: catalog?.version,
                    compressedDownloadBytes: catalog?.downloadBytes,
                    pendingRemoval: marketplace.pendingRemovalIDs.contains(id),
                    preservedDataScopeIDs: preservedIDs, sharedPreferences: !identity.development))
        }
        if let selected = scopes.first(where: { $0.id == "music-selected-directory" }),
            scopes.contains(where: {
                $0.id != selected.id
                    && $0.root.standardizedFileURL == selected.root.standardizedFileURL
            })
        {
            scopes.removeAll { $0.id == selected.id }
        }
        let data = HostStorageDataScopes(
            scopes: scopes,
            owners: Dictionary(uniqueKeysWithValues: extensions.map { ($0.id, $0.dataScopeIDs) }))
        for index in extensions.indices {
            let entry = extensions[index]
            let owned = Set(data.ownedIDs[entry.id] ?? [])
            extensions[index].preservedDataScopeIDs = entry.preservedDataScopeIDs.filter {
                owned.contains($0)
            }
            extensions[index].sharedDataScopeIDs = data.sharedIDs[entry.id] ?? []
        }
        self.scopes = data.scopes
        self.extensions = extensions
        self.appVersion = appVersion
        hostABI = HostContract.compatibility
        let categories: [HostStorageCategory] = [
            .init(id: "app", title: "Edith app bundle", scopeIDs: ["app"]),
            .init(
                id: "packages", title: "Extension packages, including retained versions",
                scopeIDs: extensions.flatMap { $0.versions.flatMap(\.scopeIDs) }),
            .init(
                id: "extension-data", title: "Extension user data",
                scopeIDs: extensions.flatMap(\.dataScopeIDs)),
            .init(
                id: "shared-extension-data", title: "Shared extension user data",
                scopeIDs: data.sharedScopeIDs),
            .init(
                id: "selected-music-directory",
                title: "Selected music directory, including any other files",
                scopeIDs: scopes.contains { $0.id == "music-selected-directory" }
                    ? ["music-selected-directory"] : []),
            .init(
                id: "cache", title: "Archives, staging, cache and package metadata",
                scopeIDs: ["package-cache", "cache", "catalog-cache"]
                    + (identity.development ? [] : ["preserved-cache"])),
            .init(
                id: "host-data", title: "Host data and logs, including unassigned data",
                scopeIDs: ["host-data", "logs", "host-preferences"]
                    + (identity.development ? [] : ["shared-preferences", "preserved-logs"])),
        ]
        self.categories = categories
        let scopeRoots = Dictionary(uniqueKeysWithValues: data.scopes.map { ($0.id, $0.root) })
        func item(
            _ id: String, _ title: String, _ symbolName: String, extensionID: String? = nil,
            scopeIDs: [String], rootIDs: [String]? = nil
        ) -> HostStorageItem {
            HostStorageItem(
                id: id, title: title, symbolName: symbolName, extensionID: extensionID,
                roots: (rootIDs ?? scopeIDs).compactMap { scopeRoots[$0] }, scopeIDs: scopeIDs)
        }
        func category(_ id: String) -> HostStorageCategory? {
            categories.first { $0.id == id }
        }
        let extensionItems = extensions.map { entry in
            item(
                entry.id, entry.title, symbols[entry.id] ?? "puzzlepiece.extension",
                extensionID: entry.id,
                scopeIDs: entry.versions.flatMap(\.scopeIDs) + entry.dataScopeIDs,
                rootIDs: (packageKeys[entry.id] ?? []) + entry.dataScopeIDs)
        }
        let general: [HostStorageItem] = [
            category("app").map { item("app", "Edith app", "app", scopeIDs: $0.scopeIDs) },
            category("shared-extension-data").map {
                item(
                    "shared-extension-data", "Shared extension data", "square.on.square",
                    scopeIDs: $0.scopeIDs)
            },
            category("selected-music-directory").map {
                item(
                    "selected-music-directory", "Music folder outside Edith", "music.note.list",
                    scopeIDs: $0.scopeIDs)
            },
            category("cache").map {
                item("cache", "Caches and downloads", "archivebox", scopeIDs: $0.scopeIDs)
            },
            category("host-data").map {
                item("host-data", "Logs and other app data", "gearshape", scopeIDs: $0.scopeIDs)
            },
        ].compactMap { $0 }
        items = (extensionItems + general).filter { !$0.scopeIDs.isEmpty }
    }

    public func usage(in measurement: HostStorageMeasurement) -> [HostStorageUsage] {
        items.map { HostStorageUsage(item: $0, bytes: $0.bytes(in: measurement)) }
            .filter { $0.bytes.allocated > 0 || !$0.bytes.complete }
            .sorted {
                $0.bytes.allocated != $1.bytes.allocated
                    ? $0.bytes.allocated > $1.bytes.allocated : $0.item.title < $1.item.title
            }
    }

    public func contents(
        of item: HostStorageItem, limit: Int = 8,
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) throws -> [HostStorageEntry] {
        let own = Set(item.scopeIDs)
        let tops = item.roots.map(\.path).filter { root in
            !item.roots.contains { $0.path != root && Self.contains($0.path, root) }
        }
        let foreign = Set(
            scopes.filter { scope in
                !own.contains(scope.id)
                    && tops.contains { $0 != scope.root.path && Self.contains($0, scope.root.path) }
            }.map(\.root.path))
        var paths: Set<String> = []
        for root in tops {
            paths.formUnion(Self.listing(root).filter { !foreign.contains($0) })
        }
        let entries = paths.sorted()
        let measurement = try HostStorageAccounting.scan(
            scopes: entries.enumerated().map {
                HostStorageScope(id: "entry:\($0.offset)", root: URL(fileURLWithPath: $0.element))
            }
                + foreign.sorted().enumerated().map {
                    HostStorageScope(
                        id: "foreign:\($0.offset)", root: URL(fileURLWithPath: $0.element))
                },
            isCancelled: isCancelled)
        return Array(
            entries.enumerated().map { index, path in
                var isDirectory: ObjCBool = false
                _ = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
                return HostStorageEntry(
                    url: URL(fileURLWithPath: path), isDirectory: isDirectory.boolValue,
                    bytes: measurement.bytes["entry:\(index)"] ?? HostStorageBytes())
            }
            .filter { $0.bytes.allocated > 0 }
            .sorted {
                ($0.bytes.allocated, $0.bytes.logical, $1.url.path)
                    > ($1.bytes.allocated, $1.bytes.logical, $0.url.path)
            }
            .prefix(limit))
    }

    private static func listing(_ path: String) -> [String] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return []
        }
        guard isDirectory.boolValue,
            let names = try? FileManager.default.contentsOfDirectory(atPath: path)
        else { return [path] }
        let children = names.map { (path as NSString).appendingPathComponent($0) }
        if children.count == 1, let only = children.first {
            var onlyIsDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: only, isDirectory: &onlyIsDirectory),
                onlyIsDirectory.boolValue
            {
                return listing(only)
            }
        }
        return children
    }

    private static func contains(_ root: String, _ path: String) -> Bool {
        path == root || path.hasPrefix(root == "/" ? "/" : root + "/")
    }
}

extension HostStorageMeasurement {
    public func sum(_ ids: [String]) -> HostStorageBytes {
        ids.reduce(into: HostStorageBytes()) { result, id in
            if let bytes = bytes[id] {
                result.include(bytes)
            } else {
                result.complete = false
            }
        }
    }
}
