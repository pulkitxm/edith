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
    public private(set) var operations: [String: HostExtensionOperation] = [:]
    public private(set) var batch: HostExtensionBatch?
    public private(set) var readyIDs: Set<String> = []
    public var failures: [String: String] {
        sessions.failureReasons.merging(operationFailures) { _, operation in operation }
    }
    private var operationFailures: [String: String] = [:]
    @ObservationIgnored private var idleShortcuts: HostIdleShortcuts?
    public private(set) var restoring = false
    public private(set) var refreshingCatalog = false
    public private(set) var error: String? {
        get {
            if let startupErrorID, sessions.activeIDs.contains(startupErrorID),
                sessions.failureReasons[startupErrorID] == nil
            {
                return nil
            }
            return errorMessage
        }
        set { errorMessage = newValue; startupErrorID = nil }
    }
    private var errorMessage: String?
    private var startupErrorID: String?
    public private(set) var offline = false
    public var catalogKnown: Bool { catalog != nil }
    public var busy: Bool { restoring || !operations.isEmpty }
    public func isBusy(_ id: String) -> Bool { restoring || operations[id] != nil }
    public func progress(for id: String) -> Double { operations[id]?.fraction ?? 0 }
    public func hasPendingDownload(_ id: String) -> Bool { downloadJobs[id] != nil }
    public func canCancelDownload(_ id: String) -> Bool {
        guard downloadJobs[id] != nil, let phase = operations[id]?.phase else { return false }
        return phase == .queued || phase == .downloading
    }
    @discardableResult public func cancelDownload(id: String) -> Bool {
        guard canCancelDownload(id), let job = downloadJobs[id] else { return false }
        job.cancel()
        return true
    }
    public func markReady(_ id: String) { readyIDs.insert(id) }
    public func acknowledgeReady(_ id: String) { readyIDs.remove(id) }
    public var batchProgress: Double {
        guard let batch, batch.total > 0 else { return 0 }
        let running = batch.ids.filter { !batch.isDone($0) }.map { progress(for: $0) }
        return min(1, (Double(batch.finished) + running.reduce(0, +)) / Double(batch.total))
    }
    public var batchBytesPerSecond: Double {
        operations.values.filter { $0.phase == .downloading }.map(\.bytesPerSecond).reduce(0, +)
    }
    public static let downloadCancelled = "Download cancelled."
    public static let operationInProgress =
        "Another operation is running for this extension. Try again when it finishes."
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
    @ObservationIgnored private let verificationReceipts: HostBundleVerificationReceipts
    @ObservationIgnored private let verifyInstalledBundle: ExtensionPackageInstaller.Verify
    @ObservationIgnored private var catalog: ExtensionCatalog?
    @ObservationIgnored private var catalogRefresh: Task<Void, Never>?
    @ObservationIgnored private var catalogFetch: Task<ExtensionCatalogClient.Result, Error>?
    @ObservationIgnored private var downloadSlots = 0
    @ObservationIgnored private var slotWaiters: [HostDownloadSlotWaiter] = []
    @ObservationIgnored private var slotSequence = 0
    @ObservationIgnored private var downloadJobs: [String: Task<String?, Never>] = [:]
    @ObservationIgnored private var idleWaiters: [String: [CheckedContinuation<Void, Never>]] =
        [:]
    @ObservationIgnored private var transferOwners: [URL: String] = [:]
    @ObservationIgnored private var transferBytes: [URL: Int64] = [:]
    @ObservationIgnored private var transferSamples: [String: HostTransferSample] = [:]

    public init(
        identity: HostIdentity,
        entries: [HostExtension],
        store: ExtensionPackageStore,
        catalogClient: ExtensionCatalogClient,
        installer: ExtensionPackageInstaller,
        sessions: HostExtensionSessions,
        verificationReceipts: HostBundleVerificationReceipts? = nil,
        verifyInstalledBundle: ExtensionPackageInstaller.Verify? = nil,
        transferProgress: HostTransferProgress = HostTransferProgress()
    ) throws {
        self.identity = identity
        self.entries = entries
        self.store = store
        self.catalogClient = catalogClient
        self.installer = installer
        self.sessions = sessions
        self.verificationReceipts = verificationReceipts ?? HostBundleVerification.receipts
        let development = identity.development
        let team = ExtensionCodeSignature.teamIdentifier()
        self.verifyInstalledBundle =
            verifyInstalledBundle ?? { url in
                if development {
                    try ExtensionCodeSignature.verifyDevelopment(url)
                } else {
                    guard let team else { throw MarketplaceError.invalidSignature }
                    try ExtensionCodeSignature.verify(url, teamIdentifier: team)
                }
            }
        guard let preferences = UserDefaults(suiteName: identity.defaultsSuite) else {
            throw CocoaError(.validationMissingMandatoryProperty)
        }
        let surfaces = try HostSurfaces(identity: identity, entries: entries, sessions: sessions)
        self.surfaces = surfaces
        self.preferences = preferences
        let background = Set(entries.filter(\.background).map(\.id))
        let conditions = Dictionary(
            uniqueKeysWithValues: entries.filter { !$0.launchWhen.isEmpty }.map {
                ($0.id, $0.launchWhen)
            })
        sessions.startsAtLaunch = { [weak surfaces] id in
            if background.contains(id) || surfaces?.demandedProviderIDs.contains(id) == true {
                return true
            }
            guard let conditions = conditions[id],
                let defaults = UserDefaults(suiteName: identity.extensionDefaultsSuite(id))
            else { return false }
            return conditions.contains { $0.holds(in: defaults) }
        }
        surfaces.layoutsChanged = { [weak sessions, weak surfaces] in
            guard let sessions, let surfaces else { return }
            for id in surfaces.demandedProviderIDs.intersection(sessions.idleIDs) {
                Task { try? await sessions.activate(id) }
            }
        }
        let shortcuts = HostIdleShortcuts(entries: entries, identity: identity, sessions: sessions)
        idleShortcuts = shortcuts
        let surfacesChanged = sessions.didChange
        sessions.didChange = {
            surfacesChanged()
            shortcuts.synchronize()
        }
        automaticallyUpdatesExtensions =
            preferences.object(forKey: "automaticallyUpdatesExtensions") as? Bool ?? true
        try store.completePendingRemovals()
        try store.prune(hostABI: HostContract.compatibility)
        try reloadInstalled()
        transferProgress.observe { [weak self] url, bytes in
            Task { @MainActor in self?.recordTransfer(url, bytes: bytes) }
        }
    }

    public static func live(identity: HostIdentity) throws -> HostMarketplace {
        let store = ExtensionPackageStore(root: identity.root.appendingPathComponent("Extensions"))
        HostBundleVerification.receipts.configure(
            file: identity.root.appendingPathComponent("ExtensionState/verified-bundles.json"))
        let localCatalog = HostDevelopmentCatalog(
            environment: ProcessInfo.processInfo.environment, development: identity.development)
        let transferProgress = HostTransferProgress()
        let downloader = HostPackageDownloader()
        let download: ExtensionPackageInstaller.Download = { url, count in
            let source =
                localCatalog?.localURL(for: url, repository: MarketplaceConfiguration.repository)
                ?? url
            return try await downloader.download(source, expectedBytes: count) { bytes in
                transferProgress.report(url, bytes: bytes)
            }
        }
        let verify: ExtensionPackageInstaller.Verify
        if identity.development {
            verify = { directory in
                for bundle in try FileManager.default.contentsOfDirectory(
                    at: directory, includingPropertiesForKeys: nil)
                where bundle.pathExtension == "bundle"
                    || bundle.lastPathComponent == "CameraCarrier.app"
                {
                    try ExtensionCodeSignature.verifyDevelopment(bundle)
                }
            }
        } else {
            guard let team = ExtensionCodeSignature.teamIdentifier() else {
                throw MarketplaceError.invalidSignature
            }
            verify = { directory in
                _ = try JSONDecoder().decode(
                    ExtensionPayloadManifest.self,
                    from: Data(contentsOf: directory.appendingPathComponent("package.json")))
                for bundle in try FileManager.default.contentsOfDirectory(
                    at: directory, includingPropertiesForKeys: nil)
                where bundle.pathExtension == "bundle"
                    || bundle.lastPathComponent == "CameraCarrier.app"
                {
                    try ExtensionCodeSignature.verify(bundle, teamIdentifier: team)
                }
            }
        }
        let installer = ExtensionPackageInstaller(store: store, download: download, verify: verify)
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
        let entries = try HostIndex.bundled()
        return try HostMarketplace(
            identity: identity, entries: entries, store: store,
            catalogClient: localCatalog?.client(
                cache: identity.root.appendingPathComponent("development-catalog.json"))
                ?? .live(cache: identity.root.appendingPathComponent("catalog.json")),
            installer: installer, sessions: sessions, transferProgress: transferProgress)
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
        while busy {
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
        }
        guard !Task.isCancelled else { return }
        restoring = true
        defer { restoring = false }
        await sessions.restore(packages: installed)
    }

    private func begin(
        _ id: String, phase: HostExtensionOperation.Phase = .working, announce: Bool = true
    ) -> Bool {
        guard !isBusy(id) else { return false }
        operations[id] = HostExtensionOperation(phase: phase)
        operationFailures[id] = nil
        if announce { error = nil }
        return true
    }

    private func finish(_ id: String) {
        operations[id] = nil
        for waiter in idleWaiters.removeValue(forKey: id) ?? [] { waiter.resume() }
    }

    private func waitUntilIdle(_ id: String) async {
        if operations[id] != nil {
            await withCheckedContinuation { idleWaiters[id, default: []].append($0) }
        } else {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    @discardableResult private func fail(
        _ id: String, _ message: String, announce: Bool = true
    ) -> String {
        operationFailures[id] = message
        if announce { error = message }
        return message
    }

    private func acquireDownloadSlot(id: String, priority: Int) async {
        if downloadSlots < Self.concurrentDownloads, slotWaiters.isEmpty {
            downloadSlots += 1
            return
        }
        slotSequence += 1
        let sequence = slotSequence
        await withCheckedContinuation { continuation in
            slotWaiters.append(
                HostDownloadSlotWaiter(
                    id: id, priority: priority, sequence: sequence, continuation: continuation))
        }
    }

    private func releaseDownloadSlot() {
        guard
            let next = slotWaiters.indices.min(by: {
                (slotWaiters[$0].priority, slotWaiters[$0].sequence)
                    < (slotWaiters[$1].priority, slotWaiters[$1].sequence)
            })
        else {
            downloadSlots -= 1
            return
        }
        slotWaiters.remove(at: next).continuation.resume()
    }

    private func prioritize(_ id: String) {
        for index in slotWaiters.indices where slotWaiters[index].id == id {
            slotWaiters[index].priority = 0
        }
    }

    func downloadPriority(_ id: String) -> Int {
        let migrating = downloadedIDs.contains(id) && installed[id] == nil
        let enabled = sessions.enabledIDs.contains(id)
        switch (migrating, enabled) {
        case (true, true): return 1
        case (true, false): return 2
        case (false, true): return 3
        case (false, false): return 4
        }
    }

    private func updateOperation(_ id: String, _ change: (inout HostExtensionOperation) -> Void) {
        guard var operation = operations[id] else { return }
        change(&operation)
        operations[id] = operation
    }

    private func recordTransfer(_ url: URL, bytes: Int64) {
        guard let owner = transferOwners[url] else { return }
        transferBytes[url] = bytes
        let received = transferOwners.filter { $0.value == owner }.keys.reduce(Int64(0)) {
            $0 + (transferBytes[$1] ?? 0)
        }
        let now = ContinuousClock.now
        var sample = transferSamples[owner] ?? HostTransferSample(instant: now, bytes: 0)
        let speed = sample.update(bytes: received, at: now)
        transferSamples[owner] = sample
        updateOperation(owner) { operation in
            operation.receivedBytes = received
            if let speed { operation.bytesPerSecond = speed }
            if operation.totalBytes > 0 {
                operation.fraction = max(
                    operation.fraction, 0.8 * Double(received) / Double(operation.totalBytes))
            }
        }
    }

    private func clearTransfers(_ id: String) {
        for url in transferOwners.filter({ $0.value == id }).keys {
            transferOwners[url] = nil
            transferBytes[url] = nil
        }
        transferSamples[id] = nil
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
        let incompatibleIDs = downloadedIDs.filter { installed[$0] == nil }
        guard !downloadedIDs.isEmpty, !busy,
            automaticallyUpdatesExtensions || !incompatibleIDs.isEmpty
        else {
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
        let failed =
            automaticallyUpdatesExtensions
            ? await updateAll()
            : await install(ids: incompatibleIDs.sorted().filter { updateAvailable(id: $0) })
        guard incompatibleIDs.isDisjoint(with: failed.keys) else { return }
        preferences.set(now, forKey: "lastAutomaticExtensionCheck")
        preferences.set(hostBuild, forKey: "lastAutomaticExtensionCheckHostBuild")
        preferences.set(HostContract.compatibility, forKey: "lastAutomaticExtensionCheckHostABI")
    }

    @discardableResult public func enable(id: String) async -> String? {
        guard let package = installed[id] else {
            return "Download a compatible version of this extension before enabling it."
        }
        guard let failure = await start(package) else { return nil }
        guard updateAvailable(id: id), !offline else { return failure }
        guard await download(id: id) == nil, let updated = installed[id],
            updated.version != package.version
        else { return fail(id, failure) }
        return await start(updated)
    }

    private func start(_ package: ExtensionPackage) async -> String? {
        let id = package.id
        guard begin(id) else { return Self.operationInProgress }
        defer { finish(id) }
        do { try await sessions.enable(package) } catch {
            let message =
                sessions.pendingDisableIDs.contains(id)
                ? (error as? HostWorkerError)?.disableMessage
                    ?? "Cleanup is pending. Retry disable after finishing macOS approval."
                : sessions.failureReasons[id]
                    ?? "The extension could not start. Try enabling it again."
            self.error = message
            startupErrorID = id
            return message
        }
        return nil
    }

    @discardableResult public func disable(id: String) async -> String? {
        guard begin(id) else { return Self.operationInProgress }
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

    public var updatableIDs: [String] {
        downloadedIDs.sorted().filter { updateAvailable(id: $0) }
    }

    @discardableResult public func updateAll() async -> [String: String] {
        await install(ids: updatableIDs)
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
        let ids = Set(ids).sorted()
        guard !ids.isEmpty else { return [:] }
        let snapshot: ExtensionCatalog
        do {
            snapshot = try await fetchCatalog().catalog
        } catch {
            let message =
                (error as? LocalizedError)?.errorDescription
                ?? "Extension downloads are unavailable. Check your connection and try again."
            return Dictionary(uniqueKeysWithValues: ids.map { ($0, fail($0, message)) })
        }
        var jobs: [(String, Task<String?, Never>)] = []
        var failed: [String: String] = [:]
        let ordered = ids.sorted {
            (downloadPriority($0), $0) < (downloadPriority($1), $1)
        }
        for id in ordered {
            if let job = downloadJobs[id] {
                jobs.append((id, job))
            } else if let job = schedule(
                id, priority: downloadPriority(id), expectedPackage: nil, catalog: snapshot)
            {
                jobs.append((id, job))
            } else {
                failed[id] = Self.operationInProgress
            }
        }
        for (id, job) in jobs {
            if let message = await job.value { failed[id] = message }
        }
        return failed
    }

    @discardableResult public func download(
        id: String, expectedPackage: ExtensionPackage? = nil
    ) async -> String? {
        if let job = downloadJobs[id] {
            guard expectedPackage == nil else { return Self.operationInProgress }
            prioritize(id)
            return await job.value
        }
        guard
            let job = schedule(id, priority: 0, expectedPackage: expectedPackage, catalog: nil)
        else { return Self.operationInProgress }
        return await job.value
    }

    private func schedule(
        _ id: String, priority: Int, expectedPackage: ExtensionPackage?,
        catalog: ExtensionCatalog?
    ) -> Task<String?, Never>? {
        guard begin(id, phase: .queued, announce: priority == 0) else { return nil }
        var tracked = batch ?? HostExtensionBatch()
        tracked.add(id)
        batch = tracked
        let job = Task { @MainActor in
            let failure = await performDownload(
                id: id, priority: priority, expectedPackage: expectedPackage, catalog: catalog)
            downloadJobs[id] = nil
            batch?.complete(id, failed: failure != nil)
            if downloadJobs.isEmpty { batch = nil }
            return failure
        }
        downloadJobs[id] = job
        return job
    }

    private func performDownload(
        id: String, priority: Int, expectedPackage: ExtensionPackage?,
        catalog snapshot: ExtensionCatalog?
    ) async -> String? {
        let announce = priority == 0
        var reserved: [String] = []
        defer {
            for dependency in reserved { finish(dependency) }
            finish(id)
            clearTransfers(id)
        }
        do {
            let catalog: ExtensionCatalog
            if let snapshot {
                catalog = snapshot
            } else {
                catalog = try await fetchCatalog().catalog
            }
            if let expectedPackage {
                guard expectedPackage.id == id, available[id] == expectedPackage else {
                    return fail(
                        id,
                        "The extension package changed. Review its version and size before downloading.",
                        announce: announce)
                }
            }
            let plan = try catalog.installationPlan(
                for: id, hostABI: HostContract.compatibility, architecture: "arm64",
                systemVersion: .init(ProcessInfo.processInfo.operatingSystemVersion))
            let dependencies = plan.map(\.id).filter { $0 != id }
            while let blocked = dependencies.first(where: { isBusy($0) }) {
                await waitUntilIdle(blocked)
            }
            for dependency in dependencies
            where begin(dependency, phase: .queued, announce: announce) {
                reserved.append(dependency)
            }
            await acquireDownloadSlot(id: id, priority: priority)
            defer { releaseDownloadSlot() }
            let previous = plan.compactMap { installed[$0.id] }
            try await mutateStore { [store] in
                for package in previous { try store.select(package) }
            }
            let transfers = plan.filter { installedVersions[$0.id]?.contains($0) != true }
            for package in transfers { transferOwners[package.downloadURL] = id }
            transferSamples[id] = HostTransferSample(instant: .now, bytes: 0)
            updateOperation(id) { operation in
                operation.phase = .downloading
                operation.totalBytes = transfers.reduce(0) { $0 + $1.downloadBytes }
            }
            let report: @Sendable (Double, Bool) -> Void = { [weak self] value, installing in
                Task { @MainActor in
                    self?.updateOperation(id) { operation in
                        operation.fraction = max(operation.fraction, value)
                        if installing, operation.phase == .downloading || operation.phase == .installing
                        {
                            operation.phase = .installing
                        }
                    }
                }
            }
            _ = try await Self.retryingTransfer {
                try await installer.install(
                    plan, repository: MarketplaceConfiguration.repository,
                    progress: { report(0.8 + $0 * 0.1, true) },
                    downloaded: { report($0 * 0.8, $0 >= 1) })
            }
            updateOperation(id) { operation in
                operation.phase = .verifying
                operation.fraction = max(operation.fraction, 0.9)
            }
            await verifyInstalledBundles(plan)
            updateOperation(id) { operation in
                operation.phase = .starting
                operation.fraction = max(operation.fraction, 0.95)
            }
            var activationFailure: String?
            for package in plan {
                if let failure = await activate(
                    package,
                    starting: sessions.automaticallyEnabledIDs.contains(package.id)
                        && sessions.states[package.id] != .active)
                {
                    activationFailure =
                        package.id == id
                        ? failure : "The dependency \(package.id) could not update. " + failure
                    break
                }
            }
            try await mutateStore { [store] in
                try store.prune(hostABI: HostContract.compatibility)
            }
            try reloadInstalled()
            if let activationFailure { return fail(id, activationFailure, announce: announce) }
            return failures[id]
        } catch where Task.isCancelled {
            try? reloadInstalled()
            return Self.downloadCancelled
        } catch MarketplaceError.packageCleanupPending {
            try? reloadInstalled()
            return fail(
                id, "The extension was downloaded. Package files are awaiting cleanup.",
                announce: announce)
        } catch let error as MarketplaceError
            where error == .rateLimited || error == .incompatiblePackage
        {
            return fail(id, error.errorDescription ?? "", announce: announce)
        } catch {
            return fail(
                id, "The extension could not be downloaded. Try again.", announce: announce)
        }
    }

    private func verifyInstalledBundles(_ packages: [ExtensionPackage]) async {
        let contents: [URL] = packages.flatMap { package -> [URL] in
            (try? FileManager.default.contentsOfDirectory(
                at: store.directory(for: package).appendingPathComponent(package.id),
                includingPropertiesForKeys: nil)) ?? []
        }
        let bundles = contents.filter {
            $0.pathExtension == "bundle" || $0.lastPathComponent == "CameraCarrier.app"
        }
        await HostBundleVerification.verifyConcurrently(
            bundles, receipts: verificationReceipts, using: verifyInstalledBundle)
    }

    static func retryingTransfer<T>(_ operation: () async throws -> T) async throws -> T {
        var attempt = 0
        while true {
            do { return try await operation() } catch {
                attempt += 1
                let transient =
                    (error as? MarketplaceError) == .downloadFailed || error is URLError
                guard transient, attempt < 3, !Task.isCancelled else { throw error }
                try await Task.sleep(for: .milliseconds(300 * attempt))
            }
        }
    }

    @discardableResult private func activate(
        _ package: ExtensionPackage, starting: Bool
    ) async -> String? {
        do {
            if sessions.replaceIdle(package) {
                try await mutateStore { [store] in try store.select(package) }
                return nil
            }
            if starting {
                try await sessions.enable(package)
            } else if sessions.states[package.id] == .notInstalled {
                await sessions.restoreArrived(package)
            } else {
                try await sessions.applyUpdate(package)
            }
            if !sessions.enabledIDs.contains(package.id)
                || sessions.versions[package.id] == package.version
            {
                try await mutateStore { [store] in try store.select(package) }
            }
        } catch {
            return fail(
                package.id,
                sessions.failureReasons[package.id]
                    ?? (error as? LocalizedError)?.errorDescription
                    ?? "The update could not start. The previous version will keep running if available."
            )
        }
        return nil
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
        await verifyInstalledBundles([package])
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
        guard begin(id) else { return Self.operationInProgress }
        defer { finish(id) }
        readyIDs.remove(id)
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
