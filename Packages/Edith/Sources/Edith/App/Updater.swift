import EdithKit
import Sparkle
import SwiftUI

@MainActor
final class UpdaterModel: NSObject, ObservableObject,
    @preconcurrency SPUStandardUserDriverDelegate, SPUUpdaterDelegate
{
    @Published private(set) var updateReady: String?
    @Published private(set) var updaterAvailable = false
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var lastUpdateCheckDate: Date?
    @Published private(set) var checkHistory: [UpdateCheckRecord] = []
    @Published var checkInterval: TimeInterval = UpdateCheckInterval.fallback.seconds {
        didSet {
            guard let updater, updater.updateCheckInterval != checkInterval else { return }
            updater.updateCheckInterval = checkInterval
        }
    }
    @Published var automaticallyChecksForUpdates = true {
        didSet {
            guard
                let updater,
                updater.automaticallyChecksForUpdates != automaticallyChecksForUpdates
            else { return }
            updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        }
    }
    @Published var automaticallyDownloadsUpdates = true {
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
    private let logURL: URL

    init(startingUpdater: Bool = false, logURL: URL = UpdateCheckLog.url) {
        self.logURL = logURL
        super.init()
        checkHistory = UpdateCheckLog.load(from: logURL)
        guard startingUpdater else { return }
        let updaterController = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
        self.updaterController = updaterController
        Task { [weak self] in
            await self?.startUpdater()
        }
    }

    var automaticCheckCount: Int { UpdateCheckLog.count(of: .automatic, in: checkHistory) }

    func clearCheckHistory() {
        UpdateCheckLog.clear(at: logURL)
        checkHistory = []
    }

    func recordCheck(
        kind: UpdateCheckRecord.Kind, outcome: UpdateCheckRecord.Outcome,
        version: String? = nil, detail: String? = nil, date: Date = Date()
    ) {
        let entry = UpdateCheckRecord(
            date: date, kind: kind, outcome: outcome, version: version, detail: detail)
        checkHistory = UpdateCheckLog.append(entry, to: logURL)
        var payload: [String: Any] = ["outcome": outcome.rawValue, "kind": kind.rawValue]
        if let version { payload["version"] = version }
        if let detail { payload["detail"] = detail }
        IPC.post(IPC.Name.updateCheckFinished, userInfo: payload)
    }

    private func observeUpdateCheckRequests() {
        guard updateCheckObserver == nil else { return }
        updateCheckObserver = IPC.observe(IPC.Name.requestUpdateCheck) { [weak self] in
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
        if UserDefaults.standard.object(forKey: "SUAutomaticallyUpdate") == nil {
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
        IPC.post(IPC.Name.updateReadyToInstall, userInfo: ["version": version])
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
        let kind: UpdateCheckRecord.Kind =
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
