import EdithExtensionSupport
import ExtensionMarketplace
import Foundation
import Observation

@MainActor
@Observable
public final class HostMarketplace {
    public let entries: [HostExtension]
    public let identity: HostIdentity
    public let surfaces: HostSurfaces
    public var surfaceLayouts: SurfaceLayoutStore { surfaces.layouts }
    public let sessions: HostExtensionSessions
    public var packageStore: ExtensionPackageStore { store }
    public private(set) var installed: [String: ExtensionPackage] = [:]
    public private(set) var downloadedIDs: Set<String> = []
    public private(set) var installedVersions: [String: [ExtensionPackage]] = [:]
    public private(set) var pendingRemovalIDs: Set<String> = []
    public private(set) var available: [String: ExtensionPackage] = [:]
    public private(set) var operationID: String?
    public private(set) var error: String?
    public private(set) var offline = false
    public private(set) var progress = 0.0
    public var automaticallyUpdatesExtensions: Bool {
        didSet {
            preferences.set(
                automaticallyUpdatesExtensions, forKey: "automaticallyUpdatesExtensions")
        }
    }
    @ObservationIgnored private let preferences: UserDefaults
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
        guard let preferences = UserDefaults(suiteName: identity.defaultsSuite) else {
            throw CocoaError(.validationMissingMandatoryProperty)
        }
        surfaces = try HostSurfaces(identity: identity, entries: entries, sessions: sessions)
        self.preferences = preferences
        automaticallyUpdatesExtensions =
            preferences.object(forKey: "automaticallyUpdatesExtensions") as? Bool ?? true
        try store.completePendingRemovals()
        try store.prune(hostABI: HostContract.compatibility)
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
                    where bundle.pathExtension == "bundle"
                        || bundle.lastPathComponent == "CameraCarrier.app"
                    {
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
        let publicLauncher = try? HostPublicLauncher.capture(
            applicationURL: Bundle.main.bundleURL, hostIdentifier: identity.identifier,
            teamIdentifier: ExtensionCodeSignature.teamIdentifier())
        let sessions = HostExtensionSessions(defaults: defaults) { package in
            HostWorker(
                configuration: HostWorkerConfiguration(
                    identity: identity, extensionID: package.id, version: package.version,
                    publicLauncher: publicLauncher),
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
        guard operationID == nil else { return }
        operationID = "restore"
        defer { operationID = nil }
        await sessions.restore(packages: installed)
    }

    public func updateInstalledIfDue(now: Date = Date()) async {
        guard automaticallyUpdatesExtensions, !downloadedIDs.isEmpty, operationID == nil else {
            return
        }
        if let checked = preferences.object(forKey: "lastAutomaticExtensionCheck") as? Date,
            now.timeIntervalSince(checked) < 8 * 60 * 60
        {
            return
        }
        await checkForUpdates()
        guard error == nil, !offline else { return }
        for id in downloadedIDs.sorted() where updateAvailable(id: id) {
            await download(id: id)
            if error != nil { return }
        }
        preferences.set(now, forKey: "lastAutomaticExtensionCheck")
    }

    public func enable(id: String) async {
        guard operationID == nil, let package = installed[id] else { return }
        operationID = id
        error = nil
        defer { operationID = nil }
        do { try await sessions.enable(package) } catch {
            self.error =
                sessions.pendingDisableIDs.contains(id)
                ? (error as? HostWorkerError)?.disableMessage
                    ?? "Cleanup is pending. Retry disable after finishing macOS approval."
                : "The extension could not start. Try enabling it again."
        }
    }

    public func disable(id: String) async {
        guard operationID == nil else { return }
        operationID = id
        error = nil
        defer { operationID = nil }
        do { try await sessions.disable(id: id) } catch {
            self.error =
                (error as? HostWorkerError)?.disableMessage
                ?? "Cleanup is pending. Retry disable after restoring system settings or finishing macOS approval."
        }
    }

    public func show(id: String) async {
        guard operationID == nil else { return }
        operationID = id
        defer { operationID = nil }
        do { try await sessions.show(id: id) } catch {
            self.error = "The extension could not open. Try again."
        }
    }

    public func updateAvailable(id: String) -> Bool {
        if downloadedIDs.contains(id), installed[id] == nil, available[id] != nil { return true }
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

    public func download(id: String, expectedPackage: ExtensionPackage? = nil) async {
        guard operationID == nil else { return }
        operationID = id
        progress = 0
        error = nil
        defer { operationID = nil }
        do {
            let result = try await catalogClient.refresh()
            offline = result.offline
            apply(result.catalog)
            if let expectedPackage {
                guard expectedPackage.id == id, available[id] == expectedPackage else {
                    error =
                        "The extension package changed. Review its version and size before downloading."
                    return
                }
            }
            let plan = try result.catalog.installationPlan(
                for: id, hostABI: HostContract.compatibility, architecture: "arm64",
                systemVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion)
            if let previous = installed[id] { try store.select(previous) }
            _ = try await installer.install(plan, repository: MarketplaceConfiguration.repository) {
                [weak self] value in
                Task { @MainActor in
                    guard self?.operationID == id else { return }
                    self?.progress = value
                }
            }
            if let package = plan.first(where: { $0.id == id }) {
                do {
                    if sessions.automaticallyEnabledIDs.contains(id), sessions.states[id] != .active
                    {
                        try await sessions.enable(package)
                    } else {
                        try await sessions.applyUpdate(package)
                    }
                    if !sessions.enabledIDs.contains(id) || sessions.versions[id] == package.version
                    {
                        try store.select(package)
                    }
                } catch {
                    self.error =
                        (error as? HostWorkerError)?.disableMessage
                        ?? "The update could not start. The previous version will keep running if available."
                }
            }
            try store.prune(hostABI: HostContract.compatibility)
            try reloadInstalled()
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
            self.error =
                (error as? HostWorkerError)?.disableMessage
                ?? "The extension could not be removed. It remains installed. Open the extension and try again."
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
        let packages = try store.installedPackages()
        installedVersions = Dictionary(grouping: packages, by: \.id)
        pendingRemovalIDs = pending
        downloadedIDs = Set(packages.map(\.id)).subtracting(pending)
        var selected: [String: ExtensionPackage] = [:]
        for entry in entries where !pending.contains(entry.id) {
            if let package = try store.installedPackage(
                id: entry.id, hostABI: HostContract.compatibility, architecture: "arm64"),
                package.isCompatible(
                    hostABI: HostContract.compatibility, architecture: "arm64",
                    systemVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion)
            {
                selected[entry.id] = package
            }
        }
        installed = selected
    }
}
