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
    public var dataScopeIDs: [String] { [dataScopeID, "preferences:" + id] }

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

public struct HostStorageInventory: Sendable {
    public let scopes: [HostStorageScope]
    public let extensions: [HostStorageExtension]
    public let categories: [HostStorageCategory]
    public let appVersion: String?
    public let hostABI: String

    @MainActor
    public init(
        marketplace: HostMarketplace, appBundle: URL, appVersion: String?,
        preferencesDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences"),
        systemVersion: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
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
        let known = Dictionary(uniqueKeysWithValues: marketplace.entries.map { ($0.id, $0.title) })
        let ids = Set(known.keys).union(marketplace.installedVersions.keys).sorted()
        var extensions: [HostStorageExtension] = []
        for id in ids {
            guard ExtensionPackage.validComponent(id) else { throw MarketplaceError.invalidCatalog }
            scopes.append(.init(id: "data:" + id, root: identity.extensionDirectory(id)))
            scopes.append(
                .init(
                    id: "preferences:" + id,
                    root: preferencesDirectory.appendingPathComponent(
                        identity.extensionDefaultsSuite(id) + ".plist")))
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
                let carrier = directory.appendingPathComponent(
                    id + "/ExtensionCarrier.app/Contents")
                let worker = carrier.appendingPathComponent(
                    "Extensions/ExtensionWorker.appex/Contents")
                let payload = worker.appendingPathComponent("Resources/Payload/" + id)
                let executableIDs = [key + ":carrier-executable", key + ":worker-executable"]
                let frameworkPaths =
                    [carrier, worker]
                    + ExtensionBundleRuntime.Role.allCases.map {
                        payload.appendingPathComponent($0.rawValue + ".bundle/Contents")
                    }
                let frameworkIDs = frameworkPaths.indices.map { key + ":frameworks:\($0)" }
                scopes.append(.init(id: key, root: directory, expected: true))
                for (scopeID, root) in zip(executableIDs, [carrier, worker]) {
                    scopes.append(.init(id: scopeID, root: root.appendingPathComponent("MacOS")))
                }
                for (scopeID, root) in zip(frameworkIDs, frameworkPaths) {
                    scopes.append(
                        .init(id: scopeID, root: root.appendingPathComponent("Frameworks")))
                }
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
                    pendingRemoval: marketplace.pendingRemovalIDs.contains(id)))
        }
        self.scopes = scopes
        self.extensions = extensions
        self.appVersion = appVersion
        hostABI = HostContract.compatibility
        categories = [
            .init(id: "app", title: "Edith app bundle", scopeIDs: ["app"]),
            .init(
                id: "packages", title: "Extension packages, including retained versions",
                scopeIDs: extensions.flatMap { $0.versions.flatMap(\.scopeIDs) }),
            .init(
                id: "extension-data", title: "Extension user data",
                scopeIDs: extensions.flatMap(\.dataScopeIDs)),
            .init(
                id: "cache", title: "Archives, staging, cache and package metadata",
                scopeIDs: ["package-cache", "cache", "catalog-cache"]),
            .init(
                id: "host-data", title: "Host data and logs, including unassigned data",
                scopeIDs: ["host-data", "logs", "host-preferences"]),
        ]
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
