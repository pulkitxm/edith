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
    public private(set) var operations: [String: Double] = [:]
    public private(set) var failures: [String: String] = [:]
    public private(set) var restoring = false
    public private(set) var refreshingCatalog = false
    public private(set) var error: String?
    public private(set) var offline = false
    public var busy: Bool { restoring || !operations.isEmpty }
    public func isBusy(_ id: String) -> Bool { restoring || operations[id] != nil }
    public func progress(for id: String) -> Double { operations[id] ?? 0 }
    public static let concurrentDownloads = 3
    public var automaticallyUpdatesExtensions: Bool {
        didSet {
            preferences.set(
                automaticallyUpdatesExtensions, forKey: "automaticallyUpdatesExtensions")
        }
    }
    static let lastCatalogRefreshKey = "lastCatalogRefresh"
    static let lastCatalogCompatibilityKey = "lastCatalogCompatibility"
    static let catalogRefreshInterval: TimeInterval = 8 * 60 * 60
    @ObservationIgnored private let preferences: UserDefaults
    @ObservationIgnored private let store: ExtensionPackageStore
    @ObservationIgnored private let catalogClient: ExtensionCatalogClient
    @ObservationIgnored private let installer: ExtensionPackageInstaller
    @ObservationIgnored private var catalog: ExtensionCatalog?
    @ObservationIgnored private var catalogRefresh: Task<Void, Never>?
    @ObservationIgnored private var catalogFetch: Task<ExtensionCatalogClient.Result, Error>?
    @ObservationIgnored private var downloadSlots = 0
    @ObservationIgnored private var downloadQueue: [CheckedContinuation<Void, Never>] = []

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
        guard let defaults = UserDefaults(suiteName: identity.defaultsSuite) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let publicLauncher = try? HostPublicLauncher.capture(
            applicationURL: Bundle.main.bundleURL, hostIdentifier: identity.identifier,
            teamIdentifier: ExtensionCodeSignature.teamIdentifier())
        let sessions = HostExtensionSessions(defaults: defaults) { package in
            HostWorker(
                configuration: HostWorkerConfiguration(
                    identity: identity, extensionID: package.id, version: package.version,
                    publicLauncher: publicLauncher))
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
        while busy { try? await Task.sleep(for: .milliseconds(100)) }
        restoring = true
        defer { restoring = false }
        await sessions.restore(packages: installed)
    }

    private func begin(_ id: String) -> Bool {
        guard !isBusy(id) else { return false }
        operations[id] = 0
        failures[id] = nil
        error = nil
        return true
    }

    private func finish(_ id: String) { operations[id] = nil }

    @discardableResult private func fail(_ id: String, _ message: String) -> String {
        failures[id] = message
        error = message
        return message
    }

    private func acquireDownloadSlot() async {
        while downloadSlots >= Self.concurrentDownloads {
            await withCheckedContinuation { downloadQueue.append($0) }
        }
        downloadSlots += 1
    }

    private func releaseDownloadSlot() {
        downloadSlots -= 1
        if !downloadQueue.isEmpty { downloadQueue.removeFirst().resume() }
    }

    private func fetchCatalog() async throws -> ExtensionCatalogClient.Result {
        if let catalogFetch { return try await catalogFetch.value }
        let fetch = Task { @MainActor [catalogClient] in
            defer { catalogFetch = nil }
            let result = try await catalogClient.refresh()
            offline = result.offline
            apply(result.catalog)
            if let message = result.fallback?.message { error = message }
            return result
        }
        catalogFetch = fetch
        return try await fetch.value
    }

    private func mutateStore(_ body: @escaping @Sendable () throws -> Void) async throws {
        try await installer.exclusively(body)
    }

    public func refreshCatalogIfStale(now: Date = Date()) async {
        if catalog != nil,
            preferences.string(forKey: Self.lastCatalogCompatibilityKey)
                == HostContract.compatibility,
            let refreshed = preferences.object(forKey: Self.lastCatalogRefreshKey) as? Date,
            now.timeIntervalSince(refreshed) < Self.catalogRefreshInterval
        {
            return
        }
        await checkForUpdates(now: now)
    }

    public func updateInstalledIfDue(
        now: Date = Date(),
        hostBuild: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            ?? ""
    ) async {
        guard automaticallyUpdatesExtensions, !downloadedIDs.isEmpty, !busy else {
            return
        }
        if let checked = preferences.object(forKey: "lastAutomaticExtensionCheck") as? Date,
            now.timeIntervalSince(checked) < Self.catalogRefreshInterval,
            preferences.string(forKey: "lastAutomaticExtensionCheckHostBuild") == hostBuild,
            preferences.string(forKey: "lastAutomaticExtensionCheckHostABI")
                == HostContract.compatibility
        {
            return
        }
        await checkForUpdates(now: now)
        guard error == nil, !offline else { return }
        let failed = await install(ids: downloadedIDs.sorted().filter { updateAvailable(id: $0) })
        guard failed.isEmpty else { return }
        preferences.set(now, forKey: "lastAutomaticExtensionCheck")
        preferences.set(hostBuild, forKey: "lastAutomaticExtensionCheckHostBuild")
        preferences.set(HostContract.compatibility, forKey: "lastAutomaticExtensionCheckHostABI")
    }

    @discardableResult public func enable(id: String) async -> String? {
        guard let package = installed[id], begin(id) else { return nil }
        defer { finish(id) }
        do { try await sessions.enable(package) } catch {
            return fail(
                id,
                sessions.pendingDisableIDs.contains(id)
                    ? (error as? HostWorkerError)?.disableMessage
                        ?? "Cleanup is pending. Retry disable after finishing macOS approval."
                    : sessions.failureReasons[id]
                        ?? "The extension could not start. Try enabling it again.")
        }
        return nil
    }

    @discardableResult public func disable(id: String) async -> String? {
        guard begin(id) else { return nil }
        defer { finish(id) }
        do {
            try await sessions.disable(id: id)
            resetPreferencesOnDisable(id: id)
        } catch {
            return fail(
                id,
                (error as? HostWorkerError)?.disableMessage
                    ?? "Cleanup is pending. Retry disable after restoring system settings or finishing macOS approval."
            )
        }
        return nil
    }

    private static let preferencesResetOnDisable: [String: [String]] = [
        "focusDim": ["focusDimActive", "focusDimEnabled"],
        "hinge": ["hingeActive", "hingeEnabled"],
        "keystrokeHighlight": ["keystrokeHighlightActive", "keystrokeHighlightEnabled"],
    ]

    private func resetPreferencesOnDisable(id: String) {
        guard let keys = Self.preferencesResetOnDisable[id],
            let defaults = UserDefaults(suiteName: identity.extensionDefaultsSuite(id))
        else { return }
        for key in keys { defaults.set(false, forKey: key) }
    }

    public func show(id: String) async {
        guard begin(id) else { return }
        defer { finish(id) }
        do { try await sessions.show(id: id) } catch {
            fail(id, "The extension could not open. Try again.")
        }
    }

    public func updateAvailable(id: String) -> Bool {
        if downloadedIDs.contains(id), installed[id] == nil, available[id] != nil { return true }
        guard let package = installed[id], let next = available[id] else { return false }
        return package.version.compare(next.version, options: .numeric) == .orderedAscending
    }

    public func checkForUpdates(now: Date = Date()) async {
        if let catalogRefresh {
            await catalogRefresh.value
            return
        }
        refreshingCatalog = true
        error = nil
        let refresh = Task { @MainActor in
            do {
                let result = try await fetchCatalog()
                if result.fallback == nil {
                    preferences.set(now, forKey: Self.lastCatalogRefreshKey)
                    preferences.set(
                        HostContract.compatibility, forKey: Self.lastCatalogCompatibilityKey)
                }
            } catch {
                if self.error == nil {
                    self.error =
                        (error as? MarketplaceError) == .rateLimited
                        ? MarketplaceError.rateLimited.errorDescription
                        : "Extension downloads are unavailable. Check your connection and try again."
                }
            }
        }
        catalogRefresh = refresh
        await refresh.value
        catalogRefresh = nil
        refreshingCatalog = false
    }

    @discardableResult public func install(ids: [String]) async -> [String: String] {
        let downloads = Set(ids).sorted().map { id in (id, Task { await download(id: id) }) }
        var failed: [String: String] = [:]
        for (id, download) in downloads {
            if let message = await download.value { failed[id] = message }
        }
        return failed
    }

    @discardableResult public func download(
        id: String, expectedPackage: ExtensionPackage? = nil
    ) async -> String? {
        guard begin(id) else { return nil }
        defer { finish(id) }
        await acquireDownloadSlot()
        defer { releaseDownloadSlot() }
        do {
            _ = try await fetchCatalog()
            if let expectedPackage {
                guard expectedPackage.id == id, available[id] == expectedPackage else {
                    return fail(
                        id,
                        "The extension package changed. Review its version and size before downloading."
                    )
                }
            }
            guard let catalog else { throw MarketplaceError.invalidCatalog }
            let plan = try catalog.installationPlan(
                for: id, hostABI: HostContract.compatibility, architecture: "arm64",
                systemVersion: .init(ProcessInfo.processInfo.operatingSystemVersion))
            if let previous = installed[id] {
                try await mutateStore { [store] in try store.select(previous) }
            }
            let report: @Sendable (Double) -> Void = { [weak self] value in
                Task { @MainActor in
                    guard self?.operations[id] != nil else { return }
                    self?.operations[id] = value
                }
            }
            _ = try await Self.retryingTransfer {
                try await installer.install(
                    plan, repository: MarketplaceConfiguration.repository,
                    progress: { report(0.9 + $0 * 0.1) }, downloaded: { report($0 * 0.9) })
            }
            if let package = plan.first(where: { $0.id == id }) {
                await activate(
                    package,
                    starting: sessions.automaticallyEnabledIDs.contains(id)
                        && sessions.states[id] != .active)
            }
            try await mutateStore { [store] in
                try store.prune(hostABI: HostContract.compatibility)
            }
            try reloadInstalled()
            return failures[id]
        } catch MarketplaceError.packageCleanupPending {
            try? reloadInstalled()
            return fail(id, "The extension was downloaded. Package files are awaiting cleanup.")
        } catch MarketplaceError.rateLimited {
            return fail(id, MarketplaceError.rateLimited.errorDescription ?? "")
        } catch {
            return fail(id, "The extension could not be downloaded. Try again.")
        }
    }

    static func retryingTransfer<T>(_ operation: () async throws -> T) async throws -> T {
        var attempt = 0
        while true {
            do { return try await operation() } catch {
                attempt += 1
                let transient =
                    (error as? MarketplaceError) == .downloadFailed || error is URLError
                guard transient, attempt < 3 else { throw error }
                try await Task.sleep(for: .milliseconds(300 * attempt))
            }
        }
    }

    private func activate(_ package: ExtensionPackage, starting: Bool) async {
        do {
            if starting {
                try await sessions.enable(package)
            } else {
                try await sessions.applyUpdate(package)
            }
            if !sessions.enabledIDs.contains(package.id)
                || sessions.versions[package.id] == package.version
            {
                try await mutateStore { [store] in try store.select(package) }
            }
        } catch {
            fail(
                package.id,
                (error as? HostWorkerError)?.disableMessage
                    ?? "The update could not start. The previous version will keep running if available."
            )
        }
    }

    public static func allowsSideload(identifier: String) -> Bool {
        identifier.hasPrefix("com.pulkit.edith.dev.")
    }

    public func sideload(
        _ sideload: ExtensionSideload,
        admit: @escaping ExtensionPackageInstaller.Verify = HostMarketplace.adHocBundles
    ) async throws -> ExtensionPackage {
        guard Self.allowsSideload(identifier: identity.identifier) else {
            throw HostCLIError.rejected("Only development builds can sideload extensions.")
        }
        let package = sideload.package
        guard entries.contains(where: { $0.id == package.id }) else {
            throw HostCLIError.rejected("Unknown extension identifier.")
        }
        guard
            package.isCompatible(
                hostABI: HostContract.compatibility, architecture: "arm64",
                systemVersion: .init(ProcessInfo.processInfo.operatingSystemVersion))
        else {
            throw HostCLIError.rejected(
                "The package targets \(package.hostABI) on \(package.architecture), but this build "
                    + "runs \(HostContract.compatibility) on arm64. Rebuild it from this worktree.")
        }
        let missing = package.dependencies.filter { installed[$0] == nil }
        guard missing.isEmpty else {
            throw HostCLIError.rejected(
                "Install its dependencies first: " + missing.joined(separator: ", ") + ".")
        }
        guard begin(package.id) else {
            throw HostCLIError.rejected(
                "Another operation is running for this extension. Try again when it finishes.")
        }
        defer { finish(package.id) }
        if let previous = installed[package.id] {
            try await mutateStore { [store] in try store.select(previous) }
        }
        let archive = sideload.archive
        _ = try await installer.install(
            [package], repository: MarketplaceConfiguration.repository,
            source: { _, _ in
                let copy = FileManager.default.temporaryDirectory.appendingPathComponent(
                    "sideload-\(UUID().uuidString).zip")
                try FileManager.default.copyItem(at: archive, to: copy)
                return copy
            }, admit: admit)
        await activate(
            package,
            starting: !sessions.enabledIDs.contains(package.id)
                || sessions.states[package.id] != .active)
        try await mutateStore { [store] in try store.prune(hostABI: HostContract.compatibility) }
        try reloadInstalled()
        if let failure = failures[package.id] { throw HostCLIError.rejected(failure) }
        return package
    }

    public nonisolated static func adHocBundles(_ directory: URL) throws {
        for bundle in try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)
        where bundle.pathExtension == "bundle" || bundle.lastPathComponent == "CameraCarrier.app" {
            try ExtensionCodeSignature.verifyAdHoc(bundle)
        }
    }

    @discardableResult public func remove(id: String) async -> String? {
        guard begin(id) else { return nil }
        defer { finish(id) }
        do {
            try await sessions.disable(id: id)
            try await mutateStore { [store] in _ = try store.requestRemoval(id: id) }
            try reloadInstalled()
        } catch MarketplaceError.packageCleanupPending {
            try? reloadInstalled()
            return fail(
                id,
                installedVersions[id]?.isEmpty == false
                    ? "Package files are awaiting cleanup. Try removing this extension again."
                    : "The extension was removed. Package files are awaiting cleanup.")
        } catch {
            try? reloadInstalled()
            return fail(
                id,
                (error as? HostWorkerError)?.disableMessage
                    ?? "The extension could not be removed. Open the extension and try again.")
        }
        return nil
    }

    public var installedBytes: Int64 { store.diskBytes() }

    private func apply(_ catalog: ExtensionCatalog) {
        self.catalog = catalog
        var candidates: [String: ExtensionPackage] = [:]
        for package in catalog.packages
        where package.isCompatible(
            hostABI: HostContract.compatibility, architecture: "arm64",
            systemVersion: .init(ProcessInfo.processInfo.operatingSystemVersion))
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
                    systemVersion: .init(ProcessInfo.processInfo.operatingSystemVersion))
            {
                selected[entry.id] = package
            }
        }
        installed = selected
    }
}
