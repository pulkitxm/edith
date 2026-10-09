import ExtensionMarketplace
import Foundation
import Observation

@MainActor
@Observable
public final class HostMarketplace {
    public let entries: [HostExtension]
    public let identity: HostIdentity
    public let sessions: HostExtensionSessions
    public private(set) var installed: [String: ExtensionPackage] = [:]
    public private(set) var available: [String: ExtensionPackage] = [:]
    public private(set) var operationID: String?
    public private(set) var error: String?
    public private(set) var offline = false
    public private(set) var progress = 0.0
    @ObservationIgnored private let store: ExtensionPackageStore
    @ObservationIgnored private let catalogClient: ExtensionCatalogClient
    @ObservationIgnored private let installer: ExtensionPackageInstaller
    @ObservationIgnored private var catalog: ExtensionCatalog?

    public init(
        identity: HostIdentity,
        entries: [HostExtension],
        store: ExtensionPackageStore,
        catalogClient: ExtensionCatalogClient,
        installer: ExtensionPackageInstaller,
        sessions: HostExtensionSessions
    ) throws {
        self.identity = identity
        self.entries = entries
        self.store = store
        self.catalogClient = catalogClient
        self.installer = installer
        self.sessions = sessions
        try store.completePendingRemovals()
        try reloadInstalled()
    }

    public static func live(identity: HostIdentity) throws -> HostMarketplace {
        let store = ExtensionPackageStore(root: identity.root.appendingPathComponent("Extensions"))
        let installer: ExtensionPackageInstaller
        if identity.development {
            installer = ExtensionPackageInstaller(
                store: store,
                download: { url, count in
                    let (temporary, response) = try await URLSession.shared.download(from: url)
                    guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                        try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize == Int(count)
                    else {
                        try? FileManager.default.removeItem(at: temporary)
                        throw MarketplaceError.downloadFailed
                    }
                    return temporary
                },
                verify: { directory in
                    for bundle in try FileManager.default.contentsOfDirectory(
                        at: directory, includingPropertiesForKeys: nil)
                    where bundle.pathExtension == "bundle" {
                        try ExtensionCodeSignature.verifyDevelopment(bundle)
                    }
                })
        } else {
            guard let team = ExtensionCodeSignature.teamIdentifier() else {
                throw MarketplaceError.invalidSignature
            }
            installer = .live(store: store, teamIdentifier: team)
        }
        guard let executable = Bundle.main.executableURL,
            let defaults = UserDefaults(suiteName: identity.defaultsSuite)
        else { throw CocoaError(.fileNoSuchFile) }
        let sessions = HostExtensionSessions(defaults: defaults) { package in
            HostWorker(
                configuration: HostWorkerConfiguration(
                    identity: identity, extensionID: package.id, version: package.version),
                executable: executable)
        }
        return try HostMarketplace(
            identity: identity, entries: HostIndex.bundled(), store: store,
            catalogClient: .live(cache: identity.root.appendingPathComponent("catalog.json")),
            installer: installer, sessions: sessions)
    }

    public func loadCachedCatalog() async {
        do {
            if let saved = try await catalogClient.cached() { apply(saved) }
        } catch {
            self.error =
                "Saved extension information could not be verified. Check for updates to try again."
        }
    }

    public func restoreEnabledExtensions() async {
        await sessions.restore(packages: installed)
    }

    public func enable(id: String) async {
        guard operationID == nil, let package = installed[id] else { return }
        operationID = id
        error = nil
        defer { operationID = nil }
        do { try await sessions.enable(package) } catch {
            self.error = "The extension could not start. Try enabling it again."
        }
    }

    public func disable(id: String) async {
        guard operationID == nil else { return }
        operationID = id
        error = nil
        defer { operationID = nil }
        do { try await sessions.disable(id: id) } catch {
            self.error = "The extension could not stop. Try again."
        }
    }

    public func show(id: String) async {
        guard operationID == nil else { return }
        do { try await sessions.show(id: id) } catch {
            self.error = "The extension could not open. Try again."
        }
    }

    public func updateAvailable(id: String) -> Bool {
        guard let package = installed[id], let next = available[id] else { return false }
        return package.version.compare(next.version, options: .numeric) == .orderedAscending
    }

    public func checkForUpdates() async {
        guard operationID == nil else { return }
        operationID = "catalog"
        error = nil
        defer { operationID = nil }
        do {
            let result = try await catalogClient.refresh()
            offline = result.offline
            apply(result.catalog)
        } catch {
            self.error = "Extension downloads are unavailable. Check your connection and try again."
        }
    }

    public func download(id: String) async {
        guard operationID == nil else { return }
        operationID = id
        progress = 0
        error = nil
        defer { operationID = nil }
        do {
            let result = try await catalogClient.refresh()
            offline = result.offline
            apply(result.catalog)
            let plan = try result.catalog.installationPlan(
                for: id, hostABI: HostContract.compatibility, architecture: "arm64",
                systemVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion)
            _ = try await installer.install(plan, repository: MarketplaceConfiguration.repository) {
                [weak self] value in
                Task { @MainActor in
                    guard self?.operationID == id else { return }
                    self?.progress = value
                }
            }
            try reloadInstalled()
            if let package = installed[id] {
                do { try await sessions.applyUpdate(package) } catch {
                    self.error =
                        "The update could not start. The previous version will keep running if available."
                }
            }
            try store.prune()
        } catch {
            self.error = "The extension could not be downloaded. Try again."
        }
    }

    public func remove(id: String) async {
        guard operationID == nil else { return }
        operationID = id
        error = nil
        defer { operationID = nil }
        do {
            try await sessions.disable(id: id)
            _ = try store.requestRemoval(id: id)
            try reloadInstalled()
        } catch {
            self.error = "The extension could not be removed. Try again."
        }
    }

    public var installedBytes: Int64 { store.diskBytes() }

    private func apply(_ catalog: ExtensionCatalog) {
        self.catalog = catalog
        var candidates: [String: ExtensionPackage] = [:]
        for package in catalog.packages
        where package.isCompatible(
            hostABI: HostContract.compatibility, architecture: "arm64",
            systemVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion)
        {
            if let previous = candidates[package.id],
                previous.version.compare(package.version, options: .numeric) != .orderedAscending
            {
                continue
            }
            candidates[package.id] = package
        }
        available = candidates
    }

    private func reloadInstalled() throws {
        let pending = try store.pendingRemovals()
        var selected: [String: ExtensionPackage] = [:]
        for entry in entries where !pending.contains(entry.id) {
            if let package = try store.installedPackage(
                id: entry.id, hostABI: HostContract.compatibility, architecture: "arm64")
            {
                selected[entry.id] = package
            }
        }
        installed = selected
    }
}
