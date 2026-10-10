import AppKit
import EdithExtensionSupport
import EdithHostCore
import ExtensionMarketplace
import IOKit.ps
import Observation
import SwiftUI

@MainActor @Observable final class HostCoreServices {
    let identity: HostIdentity
    let marketplace: HostMarketplace
    let defaults: UserDefaults
    let cloudPreferences: HostCloudPreferences
    private(set) var snapshot: HostCoreSnapshot?
    private(set) var failure: String?
    private(set) var panelFailure: String?
    private(set) var starting = false
    private(set) var inspecting = false
    private(set) var synchronizing = false
    private(set) var backupFailure: String?
    private(set) var cpuPercent = 0.0
    @ObservationIgnored private var process: HostCoreProcess?
    @ObservationIgnored private var observation: Task<Void, Never>?
    @ObservationIgnored private let executable: URL
    @ObservationIgnored private let panel: HostPanelService
    @ObservationIgnored private let settingsCapture: HostSettingsArchive
    @ObservationIgnored private var settingsScheduler: HostSettingsScheduler?
    @ObservationIgnored private var settingsObserver: NSObjectProtocol?
    @ObservationIgnored private var workflowValue: HostWorkflowOnboardingModel?

    init(
        identity: HostIdentity, marketplace: HostMarketplace,
        executable: URL? = Bundle.main.executableURL, togglePanel: @escaping @MainActor () -> Void
    ) throws {
        guard let executable else { throw CocoaError(.fileNoSuchFile) }
        self.identity = identity
        self.marketplace = marketplace
        defaults = marketplace.surfaces.preferences
        cloudPreferences = try HostCloudPreferences(identity: identity, application: defaults)
        settingsCapture = try HostSettingsArchive(
            identity: identity, cloudDirectory: HostCoreCloud.directory(identity: identity))
        self.executable = executable
        panel = HostPanelService(defaults: defaults, action: togglePanel)
    }

    var online: Bool { process?.ready == true && process?.processIdentifier == snapshot?.pid }
    var activeTaskCount: Int { snapshot?.tasks.filter { $0.phase == .running }.count ?? 0 }
    var activityLabel: String {
        if failure != nil { return "Unavailable" }
        if starting { return "Starting" }
        guard online else { return "Offline" }
        return activeTaskCount > 0 ? "\(activeTaskCount) active" : "Idle"
    }

    func start() async {
        guard !starting, process == nil else { return }
        starting = true
        defer { starting = false }
        NSApp.setActivationPolicy(
            defaults.object(forKey: AppStorageKeys.General.showDockIcon) as? Bool ?? true
                ? .regular : .accessory)
        panelShortcutChanged()
        let process = HostCoreProcess(identity: identity, executable: executable)
        self.process = process
        do {
            update(try await process.start())
            failure = nil
            startSettingsScheduler()
            if workflowModel.incomplete,
                marketplace.downloadedIDs.isEmpty
                    || defaults.bool(forKey: HostWorkflowOnboardingModel.reviewPendingKey)
            {
                workflowModel.present()
            }
            observation = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(5)) } catch { return }
                    guard let self else { return }
                    await self.refresh()
                }
            }
        } catch {
            await process.stop()
            self.process = nil
            failure = "The background service could not start. Try restarting it."
        }
    }

    func refresh() async {
        guard let process, process.ready else { return }
        do { update(try await process.perform(.status)); failure = nil } catch is CancellationError
        {} catch { failure = "The background service could not be reached. Try restarting it." }
    }

    func inspectStorage() async {
        guard !inspecting, !synchronizing, let process, process.ready else { return }
        inspecting = true
        defer { inspecting = false }
        do { update(try await process.perform(.inspect)); failure = nil } catch is CancellationError
        {} catch { failure = "Storage could not be inspected. Reload to try again." }
    }

    func cancelTask(_ id: UUID) {
        guard snapshot?.tasks.contains(where: { $0.id == id && $0.phase == .running }) == true
        else { return }
        process?.cancelCurrentTask()
    }

    func restart() async { await shutdown(); await start() }

    func synchronizeSettings(restoreOnly: Bool = false) async throws -> HostSettingsBackupResult {
        guard !synchronizing, !inspecting, let process, process.ready else {
            throw HostWorkerError.rejected
        }
        synchronizing = true
        defer { synchronizing = false }
        do {
            let next = try await process.perform(restoreOnly ? .restore : .synchronize)
            guard let result = next.settingsBackup else { throw HostWorkerError.invalidResponse }
            update(next)
            backupFailure = nil
            if result.restored {
                defaults.synchronize()
                IPC.post(IPC.Name.settingsChanged)
                panelShortcutChanged()
                await marketplace.sessions.synchronizeAppearance(identity: identity)
            }
            return result
        } catch is CancellationError { throw CancellationError() } catch {
            try Task.checkCancellation()
            backupFailure =
                "Settings could not be backed up or restored. Check iCloud Drive and try again."
            throw error
        }
    }

    func cloudPreferencesChanged() {
        settingsScheduler?.preferencesChanged()
        if !cloudPreferences.enabled(.icloud) || !cloudPreferences.enabled(.settings) {
            if synchronizing { process?.cancelCurrentTask() }
        }
        Task { await marketplace.sessions.synchronizeAppearance(identity: identity) }
    }

    func shutdown() async {
        await workflowValue?.shutdown()
        IPC.stopObserving(settingsObserver)
        settingsObserver = nil
        await settingsScheduler?.shutdown()
        settingsScheduler = nil
        observation?.cancel()
        await observation?.value
        observation = nil
        panel.shutdown()
        await process?.stop()
        process = nil
        snapshot = nil
        cpuPercent = 0
    }

    func panelShortcutChanged() {
        do { try panel.install(); panelFailure = nil } catch {
            panelFailure = "The panel shortcut could not be registered. Choose another shortcut."
        }
    }

    func copyLogCommand() {
        let value =
            "/usr/bin/log show --last 10m --predicate 'subsystem == \"\(identity.identifier)\"'"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    func settings(_ category: String) -> AnyView? {
        switch category {
        case "agent": AnyView(HostBackgroundPage(services: self))
        case "data": AnyView(HostDataPage(services: self))
        case "icloud": AnyView(HostCloudPage(services: self))
        case "home-setup":
            workflowModel.presented
                || (workflowModel.incomplete
                    && (marketplace.downloadedIDs.isEmpty
                        || defaults.bool(forKey: HostWorkflowOnboardingModel.reviewPendingKey)))
                ? AnyView(
                    HostWorkflowOnboardingView(
                        model: workflowModel, progress: { [marketplace] in marketplace.progress }))
                : nil
        default: nil
        }
    }

    func showWelcome() {
        workflowModel.present()
        defaults.set("home", forKey: AppStorageKeys.General.mainWindowSection)
    }

    var workflowModel: HostWorkflowOnboardingModel {
        if let workflowValue { return workflowValue }
        let model = HostWorkflowOnboardingModel(
            entries: marketplace.entries, defaults: defaults,
            environment: HostWorkflowEnvironment(
                available: { [weak self] in self?.marketplace.available ?? [:] },
                installed: { [weak self] in
                    Set(
                        self?.marketplace.installed.keys
                            ?? Dictionary<String, ExtensionPackage>().keys)
                },
                active: { [weak self] in self?.readyWorkflowExtensions() ?? [] },
                refresh: { [weak self] in
                    guard let self, marketplace.operationID == nil else {
                        throw HostWorkerError.rejected
                    }
                    await marketplace.checkForUpdates()
                    try Task.checkCancellation()
                    if let error = marketplace.error { throw HostWorkflowFailure(error) }
                },
                install: { [weak self] id, expectedPackage in
                    guard let self, marketplace.operationID == nil else {
                        throw HostWorkerError.rejected
                    }
                    if marketplace.installed[id] == nil {
                        await marketplace.download(id: id, expectedPackage: expectedPackage)
                        try Task.checkCancellation()
                        if let error = marketplace.error {
                            if let expectedPackage, marketplace.available[id] != expectedPackage {
                                throw HostWorkflowReviewChanged()
                            }
                            throw HostWorkflowFailure(error)
                        }
                    }
                    guard marketplace.installed[id] != nil else {
                        throw HostWorkflowFailure(
                            "A compatible download is unavailable for this extension.")
                    }
                    await marketplace.enable(id: id)
                    try Task.checkCancellation()
                    if let error = marketplace.error { throw HostWorkflowFailure(error) }
                    guard readyWorkflowExtensions().contains(id) else {
                        throw HostWorkerError.rejected
                    }
                },
                restore: { [weak self] in
                    guard let self else { throw CancellationError() }
                    return try await synchronizeSettings(restoreOnly: true)
                },
                changed: { [weak self] in
                    guard let self else { return }
                    defaults.synchronize()
                    IPC.post(IPC.Name.settingsChanged)
                    settingsScheduler?.preferencesChanged()
                }))
        workflowValue = model
        return model
    }

    private func readyWorkflowExtensions() -> Set<String> {
        Set(
            marketplace.sessions.activeIDs.filter { id in
                guard !marketplace.pendingRemovalIDs.contains(id),
                    let package = marketplace.installed[id],
                    marketplace.sessions.versions[id] == package.version,
                    let pid = marketplace.sessions.processIdentifiers[id],
                    let process = try? HostRemoteKernelIdentity.read(pid)
                else { return false }
                return process.isRunning
            })
    }

    private func startSettingsScheduler() {
        settingsScheduler = HostSettingsScheduler(
            signature: { [settingsCapture] in try settingsCapture.capture() },
            enabled: { [weak self] in
                guard let self else { return false }
                return online && cloudPreferences.readyForSettingsBackup
                    && (identity.development || snapshot?.cloudAvailable == true)
            },
            onBattery: {
                guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
                    return false
                }
                return IOPSGetProvidingPowerSourceType(snapshot).takeUnretainedValue() as String
                    == kIOPMBatteryPowerKey
            },
            run: { [weak self] in
                guard let self else { throw CancellationError() }
                _ = try await synchronizeSettings()
                return true
            })
        settingsObserver = IPC.observe(IPC.Name.settingsChanged) { [weak self] in
            MainActor.assumeIsolated { self?.settingsScheduler?.preferencesChanged() }
        }
        settingsScheduler?.start()
    }

    private func update(_ next: HostCoreSnapshot) {
        if let previous = snapshot, previous.pid == next.pid {
            let elapsed = next.collectedAt.timeIntervalSince(previous.collectedAt)
            if elapsed > 0 {
                cpuPercent = max(0, (next.cpuSeconds - previous.cpuSeconds) / elapsed * 100)
            }
        } else {
            cpuPercent = 0
        }
        snapshot = next
    }
}
