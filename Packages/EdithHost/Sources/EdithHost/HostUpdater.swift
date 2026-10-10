import EdithExtensionSupport
import EdithHostCore
import Observation
import Sparkle
import SwiftUI

@MainActor
@Observable
final class HostUpdater: NSObject,
    @preconcurrency SPUStandardUserDriverDelegate, SPUUpdaterDelegate
{
    private(set) var updateReady: String?
    private(set) var updaterAvailable = false
    private(set) var canCheckForUpdates = false
    private(set) var lastUpdateCheckDate: Date?
    private(set) var checkHistory: [HostUpdateCheckRecord] = []
    var checkInterval: TimeInterval = HostUpdateCheckInterval.fallback.seconds {
        didSet {
            guard let updater, updater.updateCheckInterval != checkInterval else { return }
            updater.updateCheckInterval = checkInterval
        }
    }
    var automaticallyChecksForUpdates = true {
        didSet {
            guard
                let updater,
                updater.automaticallyChecksForUpdates != automaticallyChecksForUpdates
            else { return }
            updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        }
    }
    var automaticallyDownloadsUpdates = true {
        didSet {
            guard
                let updater,
                updater.automaticallyDownloadsUpdates != automaticallyDownloadsUpdates
            else { return }
            updater.automaticallyDownloadsUpdates = automaticallyDownloadsUpdates
        }
    }

    private var updaterController: SPUStandardUpdaterController?
    private var canCheckObservation: NSKeyValueObservation?
    private var automaticChecksObservation: NSKeyValueObservation?
    private var automaticDownloadsObservation: NSKeyValueObservation?
    private var updater: SPUUpdater? { updaterController?.updater }
    private var pendingUpdateVersion: String?
    private var updateCheckObserver: NSObjectProtocol?
    private var historyLoadTask: Task<Void, Never>?
    private let logURL: URL?
    var available: Bool { updaterAvailable }

    init(startingUpdater: Bool = true, logURL: URL? = nil) {
        let production =
            Bundle.main.bundleIdentifier == "com.pulkit.edith"
            && Bundle.main.bundleURL.path == "/Applications/Edith.app"
        let directory = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first
        self.logURL =
            logURL
            ?? (production ? directory?.appendingPathComponent("Edith/update-checks.json") : nil)
        super.init()
        historyLoadTask?.cancel()
        if let logURL = self.logURL {
            historyLoadTask = Task { [weak self, logURL] in
                let checkHistory = await Task.detached(priority: .utility) {
                    Self.loadUpdateHistory(at: logURL)
                }.value
                guard !Task.isCancelled else { return }
                self?.checkHistory = checkHistory
            }
        }
        guard startingUpdater, production else { return }
        let updaterController = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
        self.updaterController = updaterController
        Task { [weak self] in
            await self?.startUpdater()
        }
    }

    private nonisolated static func loadUpdateHistory(at logURL: URL) -> [HostUpdateCheckRecord] {
        let checkHistory = HostUpdateCheckLog.load(from: logURL)
        return checkHistory
    }

    var automaticCheckCount: Int { HostUpdateCheckLog.count(of: .automatic, in: checkHistory) }

    func clearCheckHistory() {
        historyLoadTask?.cancel()
        if let logURL { HostUpdateCheckLog.clear(at: logURL) }
        checkHistory = []
    }

    func recordCheck(
        kind: HostUpdateCheckRecord.Kind, outcome: HostUpdateCheckRecord.Outcome,
        version: String? = nil, detail: String? = nil, date: Date = Date()
    ) {
        historyLoadTask?.cancel()
        let entry = HostUpdateCheckRecord(
            date: date, kind: kind, outcome: outcome, version: version,
            detail: detail.map { String($0.prefix(512)) })
        if let logURL {
            checkHistory = HostUpdateCheckLog.append(entry, to: logURL)
        } else {
            checkHistory = Array(([entry] + checkHistory).prefix(HostUpdateCheckLog.limit))
        }
        var payload: [String: Any] = ["outcome": outcome.rawValue, "kind": kind.rawValue]
        if let version { payload["version"] = version }
        if let detail { payload["detail"] = detail }
        IPC.post(HostUpdateEvents.finished, userInfo: payload)
    }

    private func observeUpdateCheckRequests() {
        guard updateCheckObserver == nil else { return }
        updateCheckObserver = IPC.observe(HostUpdateEvents.request) { [weak self] in
            MainActor.assumeIsolated { self?.checkForUpdatesInBackground() }
        }
    }

    private func startUpdater() async {
        guard let updater else { return }
        do {
            try updater.start()
            updaterAvailable = true
            observeUpdateCheckRequests()
        } catch {
            updaterAvailable = false
            return
        }
        if UserDefaults.standard.object(forKey: AppStorageKeys.Update.automaticDownloads) == nil {
            updater.automaticallyDownloadsUpdates = true
        }
        automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
        automaticallyDownloadsUpdates = updater.automaticallyDownloadsUpdates
        checkInterval = updater.updateCheckInterval
        lastUpdateCheckDate = updater.lastUpdateCheckDate
        canCheckObservation = updater.observe(
            \.canCheckForUpdates, options: [.initial, .new]
        ) { [weak self] updater, change in
            let canCheckForUpdates = change.newValue ?? updater.canCheckForUpdates
            let lastUpdateCheckDate = updater.lastUpdateCheckDate
            Task { @MainActor [weak self] in
                self?.canCheckForUpdates = canCheckForUpdates
                self?.lastUpdateCheckDate = lastUpdateCheckDate
            }
        }
        automaticChecksObservation = updater.observe(
            \.automaticallyChecksForUpdates, options: [.new]
        ) { [weak self] _, change in
            guard let value = change.newValue else { return }
            Task { @MainActor [weak self] in
                self?.automaticallyChecksForUpdates = value
            }
        }
        automaticDownloadsObservation = updater.observe(
            \.automaticallyDownloadsUpdates, options: [.new]
        ) { [weak self] _, change in
            guard let value = change.newValue else { return }
            Task { @MainActor [weak self] in
                self?.automaticallyDownloadsUpdates = value
            }
        }
    }

    var supportsGentleScheduledUpdateReminders: Bool { true }

    func checkForUpdates() {
        guard updaterAvailable else { return }
        updaterController?.checkForUpdates(nil)
    }

    func checkForUpdatesInBackground() {
        guard updaterAvailable, let updater, !updater.sessionInProgress else { return }
        updater.checkForUpdatesInBackground()
    }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        guard !state.userInitiated else { return }
        let version = update.displayVersionString
        guard updateReady != version else { return }
        updateReady = version
        IPC.post(HostUpdateEvents.ready, userInfo: ["version": version])
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        updateReady = nil
    }

    func standardUserDriverWillFinishUpdateSession() {
        updateReady = nil
        lastUpdateCheckDate = updater?.lastUpdateCheckDate
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        pendingUpdateVersion = item.displayVersionString
    }

    func updater(
        _ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
        error: (any Error)?
    ) {
        let version = pendingUpdateVersion
        pendingUpdateVersion = nil
        lastUpdateCheckDate = updater.lastUpdateCheckDate
        let kind: HostUpdateCheckRecord.Kind =
            updateCheck == .updatesInBackground ? .automatic : .manual
        if let error {
            let code = (error as NSError).code
            guard code != Int(Sparkle.SUError.noUpdateError.rawValue) else {
                recordCheck(kind: kind, outcome: .upToDate)
                return
            }
            recordCheck(
                kind: kind, outcome: .failed,
                detail: (error as NSError).localizedDescription)
            return
        }
        guard let version else {
            recordCheck(kind: kind, outcome: .upToDate)
            return
        }
        recordCheck(kind: kind, outcome: .updateFound, version: version)
    }
}

enum HostUpdateEvents {
    static let finished = "com.pulkit.edith.updateCheckFinished"
    static let request = "com.pulkit.edith.requestUpdateCheck"
    static let ready = "com.pulkit.edith.updateReadyToInstall"
}
