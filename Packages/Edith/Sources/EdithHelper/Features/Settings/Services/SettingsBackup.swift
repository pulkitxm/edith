import AppKit
import EdithKit
import Foundation
import Observation

enum SettingsBackupDataClass: String, CaseIterable, Hashable, Sendable {
    case settings
    case usage
    case limits
    case music
    case clipboard
}

func settingsBackupShouldImport(
    localFileExists: Bool, freshInstall: Bool, cloudDate: Date, localDate: Date
) -> Bool {
    if !localFileExists || freshInstall { return true }
    return cloudDate > localDate.addingTimeInterval(2)
}

func settingsBackupMissingNames(cloudNames: Set<String>, localNames: Set<String>) -> Set<String> {
    cloudNames.subtracting(localNames)
}

func settingsBackupLidAwakeBatteryThreshold(_ value: Any) -> Int? {
    guard !(value is Bool), let number = value as? NSNumber else { return nil }
    let threshold = number.doubleValue
    guard threshold.isFinite, threshold.rounded() == threshold,
        threshold >= Double(LidAwakeState.batteryThresholdRange.lowerBound),
        threshold <= Double(LidAwakeState.batteryThresholdRange.upperBound)
    else { return nil }
    return Int(threshold)
}

struct SettingsBackupPendingState: Equatable, Sendable {
    private(set) var remaining: Set<String>

    init(_ names: Set<String> = []) {
        remaining = names
    }

    mutating func complete(_ name: String) {
        remaining.remove(name)
    }
}

struct SettingsBackupPersistenceIntents: Equatable, Sendable {
    var limitsRestore = false
    var limitsExport = false
    var usageRestore = false
    var usageExport = false

    var isEmpty: Bool {
        !limitsRestore && !limitsExport && !usageRestore && !usageExport
    }

    mutating func formUnion(_ other: SettingsBackupPersistenceIntents) {
        limitsRestore = limitsRestore || other.limitsRestore
        limitsExport = limitsExport || other.limitsExport
        usageRestore = usageRestore || other.usageRestore
        usageExport = usageExport || other.usageExport
    }
}

func settingsBackupRetryPersistence(
    _ initial: SettingsBackupPersistenceIntents,
    deadline: ContinuousClock.Instant? = nil,
    retryInterval: Duration,
    transferLimits: (Bool, Bool) async -> Bool,
    transferUsage: (Bool, Bool) async -> Bool
) async -> SettingsBackupPersistenceIntents {
    let clock = ContinuousClock()
    var remaining = initial
    while !remaining.isEmpty {
        guard !Task.isCancelled else { return remaining }
        if remaining.limitsRestore || remaining.limitsExport,
            await transferLimits(remaining.limitsRestore, remaining.limitsExport)
        {
            remaining.limitsRestore = false
            remaining.limitsExport = false
        }
        guard !Task.isCancelled else { return remaining }
        if remaining.usageRestore || remaining.usageExport,
            await transferUsage(remaining.usageRestore, remaining.usageExport)
        {
            remaining.usageRestore = false
            remaining.usageExport = false
        }
        guard !remaining.isEmpty else { return remaining }
        let delay: Duration
        if let deadline {
            let available = clock.now.duration(to: deadline)
            guard available > .zero else { return remaining }
            delay = min(retryInterval, available)
        } else {
            delay = retryInterval
        }
        do {
            try await Task.sleep(for: max(delay, .milliseconds(1)))
        } catch {
            return remaining
        }
    }
    return remaining
}

struct SettingsBackupRestoreGenerationState: Equatable, Sendable {
    private var generations: [SettingsBackupDataClass: Int] = [:]

    mutating func begin(_ dataClass: SettingsBackupDataClass) -> Int {
        generations[dataClass, default: 0] += 1
        return generations[dataClass]!
    }

    mutating func invalidate(_ dataClass: SettingsBackupDataClass) {
        generations[dataClass, default: 0] += 1
    }

    func accepts(_ generation: Int, for dataClass: SettingsBackupDataClass) -> Bool {
        generations[dataClass] == generation
    }
}

final class SettingsBackupRestoreToken: @unchecked Sendable {
    private let lock = NSLock()
    private var valid = true

    func invalidate() {
        lock.lock()
        valid = false
        lock.unlock()
    }

    func performIfValid(_ body: () throws -> Void) rethrows -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard valid else { return false }
        try body()
        return true
    }
}

private struct SettingsBackupRestoreItem: Sendable {
    let name: String
    let source: URL
    let destination: URL
}

struct SettingsBackupTransferDecision: Equatable, Sendable {
    let shouldRestore: Bool
    let shouldExport: Bool
}

func settingsBackupTransferDecision(
    for dataClass: SettingsBackupDataClass,
    masterEnabled: Bool,
    subToggleEnabled: Bool,
    extensionEnabled: Bool
) -> SettingsBackupTransferDecision {
    switch dataClass {
    case .settings, .usage, .limits, .music, .clipboard:
        let shouldRestore = masterEnabled && subToggleEnabled
        return SettingsBackupTransferDecision(
            shouldRestore: shouldRestore,
            shouldExport: shouldRestore && extensionEnabled)
    }
}

func settingsBackupEnableRestoreDecision(
    for dataClass: SettingsBackupDataClass,
    cloudDataExists: Bool,
    masterEnabled: Bool
) -> Bool {
    switch (dataClass, cloudDataExists, masterEnabled) {
    case (.settings, _, _), (_, false, _): return false
    case (_, true, _): return true
    }
}

func settingsBackupTransferLimits(
    localURL: URL, cloudURL: URL, shouldRestore: Bool, shouldExport: Bool,
    willAcquireDataLock: (() -> Void)? = nil,
    restoreToken: SettingsBackupRestoreToken? = nil
) -> Bool {
    do {
        return try settingsBackupCoordinateCloud(at: cloudURL, writing: shouldExport) {
            coordinatedCloudURL in
            var cloudData: Data?
            var publication: Data?
            let transferred = try UsageDataTransaction.withExclusiveAccess(
                dataDirectory: localURL.deletingLastPathComponent(),
                willAcquireDataLock: willAcquireDataLock
            ) {
                let localData = try UsageDataFiles.readRegularFile(
                    at: localURL, maximumBytes: UsageDataFiles.maximumLimitsHistoryBytes)
                cloudData = try UsageDataFiles.readRegularFile(
                    at: coordinatedCloudURL,
                    maximumBytes: UsageDataFiles.maximumLimitsHistoryBytes)
                let cloudText = String(decoding: cloudData ?? Data(), as: UTF8.self)
                if shouldRestore, let cloudData, !cloudData.isEmpty,
                    !LimitsHistory.isValidDocument(cloudText)
                {
                    return false
                }
                let merged = LimitsHistory.merge(
                    String(decoding: localData ?? Data(), as: UTF8.self), cloudText)
                guard !merged.isEmpty else {
                    return (localData?.isEmpty ?? true) && (cloudData?.isEmpty ?? true)
                }
                let data = Data(merged.utf8)
                guard data.count <= UsageDataFiles.maximumLimitsHistoryBytes else { return false }
                if shouldRestore, localData != data {
                    let prepared = try UsageDataFiles.prepareWrite(data, to: localURL)
                    guard
                        try restoreToken?.performIfValid({
                            try prepared.publish()
                        })
                            ?? {
                                try prepared.publish()
                                return true
                            }()
                    else { return false }
                    try prepared.finish()
                }
                publication = data
                return true
            }
            if transferred, shouldExport, let publication, cloudData != publication {
                try publication.write(to: coordinatedCloudURL, options: .atomic)
            }
            return transferred
        }
    } catch {
        return false
    }
}

func settingsBackupTransferUsage(
    localURL: URL, cloudURL: URL, shouldRestore: Bool, shouldExport: Bool,
    willAcquireDataLock: (() -> Void)? = nil,
    restoreToken: SettingsBackupRestoreToken? = nil
) -> Bool {
    do {
        return try settingsBackupCoordinateCloud(at: cloudURL, writing: shouldExport) {
            coordinatedCloudURL in
            var cloudData: Data?
            var publication: Data?
            let transferred = try UsageDataTransaction.withExclusiveAccess(
                dataDirectory: localURL.deletingLastPathComponent(),
                willAcquireDataLock: willAcquireDataLock
            ) {
                let localData = try UsageDataFiles.readRegularFile(
                    at: localURL, maximumBytes: UsageDataFiles.maximumUsageDocumentBytes)
                cloudData = try UsageDataFiles.readRegularFile(
                    at: coordinatedCloudURL,
                    maximumBytes: UsageDataFiles.maximumUsageDocumentBytes)
                if shouldRestore, let cloudData, !cloudData.isEmpty,
                    !UsageHistory.isValidDocument(cloudData)
                {
                    return false
                }
                let mergeLocal = localData.flatMap {
                    UsageHistory.isValidDocument($0) ? $0 : nil
                }
                guard let merged = UsageHistory.merge(local: mergeLocal, cloud: cloudData) else {
                    return mergeLocal == nil && cloudData == nil
                }
                guard merged.count <= UsageDataFiles.maximumUsageDocumentBytes,
                    UsageHistory.isValidDocument(merged)
                else { return false }
                if shouldRestore, localData != merged {
                    let prepared = try UsageDataFiles.prepareWrite(merged, to: localURL)
                    guard
                        try restoreToken?.performIfValid({
                            try prepared.publish()
                        })
                            ?? {
                                try prepared.publish()
                                return true
                            }()
                    else { return false }
                    try prepared.finish()
                }
                publication = merged
                return true
            }
            if transferred, shouldExport, let publication, cloudData != publication {
                try publication.write(to: coordinatedCloudURL, options: .atomic)
            }
            return transferred
        }
    } catch {
        return false
    }
}

private func settingsBackupCoordinateCloud<T>(
    at cloudURL: URL, writing: Bool, _ accessor: (URL) throws -> T
) throws -> T {
    if writing {
        try FileManager.default.createDirectory(
            at: cloudURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    }
    if !writing, !FileManager.default.fileExists(atPath: cloudURL.path) {
        return try accessor(cloudURL)
    }
    let coordinator = NSFileCoordinator(filePresenter: nil)
    var result: Result<T, Error>?
    var coordinationError: NSError?
    if writing {
        coordinator.coordinate(
            writingItemAt: cloudURL, options: .forMerging, error: &coordinationError
        ) { coordinatedURL in
            result = Result { try accessor(coordinatedURL) }
        }
    } else {
        coordinator.coordinate(
            readingItemAt: cloudURL, options: .withoutChanges, error: &coordinationError
        ) { coordinatedURL in
            result = Result { try accessor(coordinatedURL) }
        }
    }
    if let coordinationError { throw coordinationError }
    guard let result else { throw CocoaError(.fileReadUnknown) }
    return try result.get()
}

private func settingsBackupCloudFileIsCurrent(_ url: URL) -> Bool {
    let fm = FileManager.default
    guard fm.fileExists(atPath: url.path) else {
        let placeholder = url.deletingLastPathComponent().appendingPathComponent(
            ".\(url.lastPathComponent).icloud")
        return !fm.fileExists(atPath: placeholder.path)
    }
    let values = try? url.resourceValues(
        forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
    if values?.isUbiquitousItem == true {
        return values?.ubiquitousItemDownloadingStatus == .current
    }
    return fm.isReadableFile(atPath: url.path)
}

private func settingsBackupRequestCloudDownload(_ url: URL) {
    do {
        try FileManager.default.startDownloadingUbiquitousItem(at: url)
    } catch {
        try? FileManager.default.startDownloadingUbiquitousItem(
            at: url.deletingLastPathComponent())
    }
}

enum SettingsBackupTransferOutcome: Sendable {
    case done
    case unavailable
    case retryable
}

func settingsBackupBoundedTransfer(
    timeout: Duration,
    operation: @escaping @Sendable () async -> SettingsBackupTransferOutcome
) async -> SettingsBackupTransferOutcome {
    let (stream, continuation) = AsyncStream.makeStream(of: SettingsBackupTransferOutcome.self)
    let work = Task {
        continuation.yield(await operation())
        continuation.finish()
    }
    let timer = Task {
        try? await Task.sleep(for: timeout)
        continuation.yield(.unavailable)
        continuation.finish()
    }
    var iterator = stream.makeAsyncIterator()
    let outcome = await iterator.next() ?? .unavailable
    timer.cancel()
    work.cancel()
    return outcome
}

actor SettingsBackupUsageWorker {
    static let shared = SettingsBackupUsageWorker()

    func transferLimits(
        localURL: URL, cloudURL: URL, shouldRestore: Bool, shouldExport: Bool,
        backupEnabled: Bool,
        requireCloudAvailability: Bool = true,
        restoreToken: SettingsBackupRestoreToken? = nil
    ) -> Bool {
        transferLimitsOutcome(
            localURL: localURL, cloudURL: cloudURL, shouldRestore: shouldRestore,
            shouldExport: shouldExport, backupEnabled: backupEnabled,
            requireCloudAvailability: requireCloudAvailability,
            restoreToken: restoreToken) == .done
    }

    func transferLimitsOutcome(
        localURL: URL, cloudURL: URL, shouldRestore: Bool, shouldExport: Bool,
        backupEnabled: Bool,
        requireCloudAvailability: Bool = true,
        restoreToken: SettingsBackupRestoreToken? = nil
    ) -> SettingsBackupTransferOutcome {
        guard backupEnabled, !requireCloudAvailability || AppData.cloudAvailable else {
            return .unavailable
        }
        guard settingsBackupCloudFileIsCurrent(cloudURL) else {
            settingsBackupRequestCloudDownload(cloudURL)
            return .unavailable
        }
        return settingsBackupTransferLimits(
            localURL: localURL, cloudURL: cloudURL, shouldRestore: shouldRestore,
            shouldExport: shouldExport, restoreToken: restoreToken) ? .done : .retryable
    }

    func transferUsage(
        localURL: URL, cloudURL: URL, shouldRestore: Bool, shouldExport: Bool,
        backupEnabled: Bool,
        requireCloudAvailability: Bool = true,
        willAcquireDataLock: (() -> Void)? = nil,
        restoreToken: SettingsBackupRestoreToken? = nil
    ) -> Bool {
        transferUsageOutcome(
            localURL: localURL, cloudURL: cloudURL, shouldRestore: shouldRestore,
            shouldExport: shouldExport, backupEnabled: backupEnabled,
            requireCloudAvailability: requireCloudAvailability,
            willAcquireDataLock: willAcquireDataLock,
            restoreToken: restoreToken) == .done
    }

    func transferUsageOutcome(
        localURL: URL, cloudURL: URL, shouldRestore: Bool, shouldExport: Bool,
        backupEnabled: Bool,
        requireCloudAvailability: Bool = true,
        willAcquireDataLock: (() -> Void)? = nil,
        restoreToken: SettingsBackupRestoreToken? = nil
    ) -> SettingsBackupTransferOutcome {
        guard backupEnabled, !requireCloudAvailability || AppData.cloudAvailable else {
            return .unavailable
        }
        guard settingsBackupCloudFileIsCurrent(cloudURL) else {
            settingsBackupRequestCloudDownload(cloudURL)
            return .unavailable
        }
        return settingsBackupTransferUsage(
            localURL: localURL, cloudURL: cloudURL, shouldRestore: shouldRestore,
            shouldExport: shouldExport, willAcquireDataLock: willAcquireDataLock,
            restoreToken: restoreToken) ? .done : .retryable
    }
}

let settingsBackupMaximumSettingsBytes = 1_024 * 1_024

func settingsBackupReadSettingsFile(
    at url: URL, maximumBytes: Int = settingsBackupMaximumSettingsBytes
) -> Data? {
    guard maximumBytes >= 0, maximumBytes < Int.max else { return nil }
    let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
    guard descriptor >= 0 else { return nil }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
        metadata.st_size >= 0, UInt64(metadata.st_size) <= UInt64(maximumBytes)
    else {
        try? handle.close()
        return nil
    }
    do {
        var data = Data()
        while data.count <= maximumBytes {
            let remaining = maximumBytes + 1 - data.count
            guard let chunk = try handle.read(upToCount: min(64 * 1_024, remaining)),
                !chunk.isEmpty
            else { break }
            data.append(chunk)
        }
        try handle.close()
        return data.count <= maximumBytes ? data : nil
    } catch {
        try? handle.close()
        return nil
    }
}

func settingsBackupReadCloudSettingsFile(
    at url: URL, maximumBytes: Int = settingsBackupMaximumSettingsBytes
) -> Data? {
    guard maximumBytes >= 0, maximumBytes < Int.max else { return nil }
    var metadata = stat()
    guard lstat(url.path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
        metadata.st_size >= 0, UInt64(metadata.st_size) <= UInt64(maximumBytes)
    else { return nil }
    do {
        return try settingsBackupCoordinateCloud(at: url, writing: false) { coordinatedURL in
            settingsBackupReadSettingsFile(at: coordinatedURL, maximumBytes: maximumBytes)
        }
    } catch {
        return nil
    }
}

@MainActor
func settingsBackupAwaitFinalSettingsExport(
    after previousExport: Task<Void, Never>?, generation: Int,
    ownsGeneration: (Int) -> Bool
) async -> Bool {
    previousExport?.cancel()
    await previousExport?.value
    return !Task.isCancelled && ownsGeneration(generation)
}

@MainActor
func settingsBackupDrainSettingsExports(
    generation: Int, ownsGeneration: (Int) -> Bool, takePending: () -> Data?,
    publish: (Data) async -> Bool, didPublish: (Bool) -> Void
) async {
    while !Task.isCancelled, ownsGeneration(generation), let data = takePending() {
        let exported = await publish(data)
        guard !Task.isCancelled, ownsGeneration(generation) else { return }
        didPublish(exported)
    }
}

actor SettingsBackupFileWorker {
    static let shared = SettingsBackupFileWorker()

    func exportSettings(
        data: Data?, localURL: URL, cloudURL: URL, shouldExportCloud: Bool
    ) -> Bool {
        guard let data else { return false }
        do {
            try FileManager.default.createDirectory(
                at: localURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if settingsBackupReadSettingsFile(at: localURL) != data {
                try data.write(to: localURL, options: .atomic)
            }
        } catch {
            return false
        }
        guard shouldExportCloud else { return false }
        guard AppData.cloudAvailable else { return false }
        do {
            return try settingsBackupCoordinateCloud(at: cloudURL, writing: true) {
                coordinatedURL in
                guard settingsBackupReadSettingsFile(at: coordinatedURL) != data else {
                    return false
                }
                try data.write(to: coordinatedURL, options: .atomic)
                return true
            }
        } catch {
            return false
        }
    }
}

@MainActor
@Observable
final class SettingsBackup {
    static let shared = SettingsBackup()

    private(set) var musicBackupRunning = false
    private(set) var clipboardBackupRunning = false

    nonisolated static let backedKeys = [
        "onboardingCompleted", "dashPaths", MusicFade.enabledKey, MusicFade.secondsKey,
        AppStorageKeys.General.theme, AppStorageKeys.General.panelTab,
        AppStorageKeys.Presenter.mode,
        AppStorageKeys.Presenter.blurMusic, AppStorageKeys.Presenter.blurMoney,
        AppStorageKeys.Presenter.blurUsage, AppStorageKeys.Presenter.blurAgents,
        AppStorageKeys.Presenter.enabled,
        AppStorageKeys.Presenter.autoEnabled, AppStorageKeys.Presenter.hideMenuBarNumbers,
        AppStorageKeys.Presenter.detectRecording,
        AppStorageKeys.Presenter.detectScreenSharing, AppStorageKeys.Presenter.detectMirroring,
        "presenterHotKeyCode", "presenterHotKeyMods", "presenterHotKeyLabel",
        AppStorageKeys.Tabs.attentionEnabled, AppStorageKeys.Tabs.usageEnabled,
        AppStorageKeys.Tabs.musicEnabled, "usageMachines",
        AppStorageKeys.Tabs.herdrEnabled, AppStorageKeys.Tabs.quinjetEnabled,
        AppStorageKeys.Herdr.ghosttyTerminal,
        AppStorageKeys.Quinjet.terminal, AppStorageKeys.Quinjet.theme,
        AppStorageKeys.General.hotKeyCode, AppStorageKeys.General.hotKeyMods,
        AppStorageKeys.General.hotKeyLabel, AppStorageKeys.Music.volume,
        AppStorageKeys.Music.downloadKind,
        Repo.pathKey,
        AppStorageKeys.Backup.icloud, AppStorageKeys.Music.backup,
        AppStorageKeys.General.lastPaletteTheme, AppStorageKeys.General.appearance,
        AppStorageKeys.Tabs.systemEnabled, AppStorageKeys.General.preventSleep,
        AppStorageKeys.Tabs.order,
        AppStorageKeys.Tabs.machinesEnabled, AppStorageKeys.Machines.notifyDown,
        AppStorageKeys.Machines.notifyDiskFull,
        AppStorageKeys.Machines.diskThreshold, AppStorageKeys.Machines.autoConnect,
        AppStorageKeys.Tabs.companionEnabled, AppStorageKeys.Companion.endpoint,
        "finderViewMode", "finderSortKey", "finderSortAscending", "finderShowHidden",
        "finderIconSize", "dockerLogWrap", "dockerLogTimestamps", "dockerLogFontSize",
        AppStorageKeys.Backup.settings, AppStorageKeys.Backup.usage, AppStorageKeys.Backup.limits,
        AppStorageKeys.Budget.enabled, AppStorageKeys.Budget.mode, AppStorageKeys.Budget.kind,
        AppStorageKeys.Budget.capPercent, AppStorageKeys.Budget.deadline,
        AppStorageKeys.Limits.claudeEnabled, AppStorageKeys.Limits.codexEnabled,
        AppStorageKeys.Limits.provider,
        AppStorageKeys.Limits.inMenuBar, AppStorageKeys.MenuBar.colorMode,
        AppStorageKeys.MenuBar.claudeWindows, AppStorageKeys.MenuBar.codexWindows,
        AppStorageKeys.MenuBar.limitsStyle,
        AppStorageKeys.General.smartColor,
        AppStorageKeys.MenuBar.subColorHex, AppStorageKeys.MenuBar.lowColorHex,
        AppStorageKeys.MenuBar.midColorHex, AppStorageKeys.MenuBar.highColorHex,
        AppStorageKeys.MenuBar.statsColorHex, AppStorageKeys.Limits.warnPercent,
        AppStorageKeys.Limits.critPercent, AppStorageKeys.Limits.pacingMargin,
        AppStorageKeys.Notify.master, AppStorageKeys.Notify.trackSession,
        AppStorageKeys.Notify.trackWeekly,
        AppStorageKeys.Notify.recovery, AppStorageKeys.Notify.pacingWarning,
        AppStorageKeys.Notify.pacingHot,
        AppStorageKeys.Notify.reminderSession, AppStorageKeys.Notify.reminderSessionOffsetMin,
        AppStorageKeys.Notify.reminderWeekly, AppStorageKeys.Notify.reminderWeeklyOffsetMin,
        AppStorageKeys.Notify.tokenExpired,
        "dashRange", "dashSources", "dashKnownSources", "dashSourceSelectionVersion", "dashModels",
        "dashSort", "dashSortAsc",
        "dashHeatMetric", "projSort", "projSortAsc", "systemAppsSort", "systemAppsSortAsc",
        AppStorageKeys.MenuBar.systemStats, AppStorageKeys.Mic.muteEnabled,
        AppStorageKeys.Mic.muteInMenuBar,
        "micHotKeyCode", "micHotKeyMods", "micHotKeyLabel", "cleanerSelectionOverrides",
        "cleanerCategoryDefaults",
        "cleanerSelectedDrives", "cleanerCustomFolders",
        LidAwakeState.enabledKey, LidAwakeState.restoreOnQuitKey, LidAwakeState.sessionKey,
        LidAwakeState.batteryThresholdKey,
        AppStorageKeys.Notch.shelfEnabled, AppStorageKeys.Notch.shelfOpenOnDrag,
        AppStorageKeys.Notch.shelfOpenOnHover,
        AppStorageKeys.Notch.shelfRequireOption, AppStorageKeys.Notch.shelfKeepDuration,
        AppStorageKeys.Notch.shelfRemoveAfterDragOut,
        AppStorageKeys.Notch.shelfShowOnExternal, AppStorageKeys.Notch.shelfHaptics,
        AppStorageKeys.Notch.shelfShowMusic,
        AppStorageKeys.Notch.alertsEnabled, AppStorageKeys.Notch.alertAudio,
        AppStorageKeys.Notch.alertPower, AppStorageKeys.Notch.alertBattery,
        AppStorageKeys.Notch.alertBluetooth, AppStorageKeys.Notch.audioMixerEnabled,
        AppStorageKeys.Clipboard.enabled, "clipboardHotKeyCode", "clipboardHotKeyMods",
        "clipboardHotKeyLabel",
        AppStorageKeys.Clipboard.maxItems, AppStorageKeys.Clipboard.maxItemBytes,
        AppStorageKeys.Clipboard.maxAgeDays,
        AppStorageKeys.Clipboard.ignoredApps, AppStorageKeys.Clipboard.autoPaste,
        AppStorageKeys.Clipboard.pastePlainText,
        AppStorageKeys.Clipboard.checkInterval, AppStorageKeys.Clipboard.backup,
        AppStorageKeys.Clipboard.lastBackupAt,
        AppStorageKeys.Clipboard.popupAt, AppStorageKeys.Clipboard.pinTo,
        AppStorageKeys.Clipboard.showFooter,
        AppStorageKeys.Clipboard.saveFiles, AppStorageKeys.Clipboard.saveImages,
        AppStorageKeys.Clipboard.saveText,
        "clipboardWindowPositionX", "clipboardWindowPositionY",
        FocusDimState.enabledKey, AppStorageKeys.FocusDim.intensity,
        AppStorageKeys.FocusDim.animationDuration,
        AppStorageKeys.FocusDim.otherDisplaysMode, AppStorageKeys.FocusDim.hotKeyCode,
        AppStorageKeys.FocusDim.hotKeyMods,
        AppStorageKeys.FocusDim.hotKeyLabel,
        AppStorageKeys.ColorPicker.enabled, AppStorageKeys.ColorPicker.copyFormat,
        AppStorageKeys.ColorPicker.profile,
        AppStorageKeys.ColorPicker.historySize, "colorPickerHotKeyCode", "colorPickerHotKeyMods",
        "colorPickerHotKeyLabel",
        AppStorageKeys.General.creditHidden, AppStorageKeys.General.homeClockZones,
        AppStorageKeys.Presenter.blurCalendar, AppStorageKeys.General.showDockIcon,
        AppStorageKeys.Tabs.calendarEnabled, AppStorageKeys.Music.looping,
        AppStorageKeys.Music.shuffling,
        AppStorageKeys.Music.gridView,
        "musicFavourites", "musicLastTrack", "musicLastPosition", "musicWasPlaying",
        "SUAutomaticallyUpdate", "SUEnableAutomaticChecks", "SUScheduledCheckInterval",
        AppStorageKeys.General.mainWindowSection, AppStorageKeys.General.settingsTab,
        AppStorageKeys.General.mainSidebarOpen, AppStorageKeys.General.mainSidebarWidth,
    ]

    nonisolated static let sharedKeys: Set<String> = [
        "onboardingCompleted", "dashPaths", MusicFade.enabledKey, MusicFade.secondsKey,
        AppStorageKeys.General.theme, AppStorageKeys.General.lastPaletteTheme,
        AppStorageKeys.General.appearance, AppStorageKeys.Music.downloadKind,
        AppStorageKeys.Presenter.mode, AppStorageKeys.Presenter.enabled,
        AppStorageKeys.Presenter.blurMusic, AppStorageKeys.Presenter.blurMoney,
        AppStorageKeys.Presenter.blurUsage, AppStorageKeys.Presenter.blurAgents,
        AppStorageKeys.Presenter.autoEnabled, AppStorageKeys.Presenter.hideMenuBarNumbers,
        AppStorageKeys.Presenter.detectRecording,
        AppStorageKeys.Presenter.detectScreenSharing, AppStorageKeys.Presenter.detectMirroring,
        "presenterHotKeyCode", "presenterHotKeyMods", "presenterHotKeyLabel",
        AppStorageKeys.Tabs.attentionEnabled, AppStorageKeys.Tabs.usageEnabled,
        AppStorageKeys.Tabs.musicEnabled,
        AppStorageKeys.Tabs.herdrEnabled, AppStorageKeys.Tabs.quinjetEnabled,
        AppStorageKeys.Herdr.ghosttyTerminal,
        AppStorageKeys.Quinjet.terminal, AppStorageKeys.Quinjet.theme,
        AppStorageKeys.Tabs.systemEnabled, AppStorageKeys.Tabs.calendarEnabled,
        AppStorageKeys.Tabs.order,
        "usageMachines",
        AppStorageKeys.Tabs.machinesEnabled, AppStorageKeys.Machines.notifyDown,
        AppStorageKeys.Machines.notifyDiskFull,
        AppStorageKeys.Machines.diskThreshold, AppStorageKeys.Machines.autoConnect,
        AppStorageKeys.Tabs.companionEnabled, AppStorageKeys.Companion.endpoint,
        "finderViewMode", "finderSortKey", "finderSortAscending", "finderShowHidden",
        "finderIconSize", "dockerLogWrap", "dockerLogTimestamps", "dockerLogFontSize",
        AppStorageKeys.Backup.icloud, AppStorageKeys.Backup.lastBackupAt,
        AppStorageKeys.Music.backup, AppStorageKeys.Music.lastBackupAt,
        AppStorageKeys.Backup.settings, AppStorageKeys.Backup.usage, AppStorageKeys.Backup.limits,
        AppStorageKeys.Budget.enabled, AppStorageKeys.Budget.mode, AppStorageKeys.Budget.kind,
        AppStorageKeys.Budget.capPercent, AppStorageKeys.Budget.deadline,
        AppStorageKeys.Limits.claudeEnabled, AppStorageKeys.Limits.codexEnabled,
        AppStorageKeys.Limits.provider,
        AppStorageKeys.Limits.inMenuBar, AppStorageKeys.MenuBar.colorMode,
        AppStorageKeys.MenuBar.claudeWindows, AppStorageKeys.MenuBar.codexWindows,
        AppStorageKeys.MenuBar.limitsStyle,
        AppStorageKeys.General.smartColor,
        AppStorageKeys.MenuBar.subColorHex, AppStorageKeys.MenuBar.lowColorHex,
        AppStorageKeys.MenuBar.midColorHex, AppStorageKeys.MenuBar.highColorHex,
        AppStorageKeys.MenuBar.statsColorHex, AppStorageKeys.Limits.warnPercent,
        AppStorageKeys.Limits.critPercent, AppStorageKeys.Limits.pacingMargin,
        AppStorageKeys.Notify.master, AppStorageKeys.Notify.trackSession,
        AppStorageKeys.Notify.trackWeekly,
        AppStorageKeys.Notify.recovery, AppStorageKeys.Notify.pacingWarning,
        AppStorageKeys.Notify.pacingHot,
        AppStorageKeys.Notify.reminderSession, AppStorageKeys.Notify.reminderSessionOffsetMin,
        AppStorageKeys.Notify.reminderWeekly, AppStorageKeys.Notify.reminderWeeklyOffsetMin,
        AppStorageKeys.Notify.tokenExpired, AppStorageKeys.General.hotKeyCode,
        AppStorageKeys.General.hotKeyMods,
        AppStorageKeys.General.hotKeyLabel,
        "dashRange", "dashSources", "dashKnownSources", "dashSourceSelectionVersion", "dashModels",
        "dashSort", "dashSortAsc",
        "dashHeatMetric", "projSort", "projSortAsc", "systemAppsSort", "systemAppsSortAsc",
        AppStorageKeys.MenuBar.systemStats, AppStorageKeys.Mic.muteEnabled,
        AppStorageKeys.Mic.muteInMenuBar,
        "micHotKeyCode", "micHotKeyMods", "micHotKeyLabel", "cleanerSelectionOverrides",
        "cleanerCategoryDefaults",
        "cleanerSelectedDrives", "cleanerCustomFolders",
        AppStorageKeys.General.preventSleep, Repo.pathKey,
        LidAwakeState.enabledKey, LidAwakeState.restoreOnQuitKey, LidAwakeState.sessionKey,
        LidAwakeState.batteryThresholdKey,
        AppStorageKeys.Notch.shelfEnabled, AppStorageKeys.Notch.shelfOpenOnDrag,
        AppStorageKeys.Notch.shelfOpenOnHover,
        AppStorageKeys.Notch.shelfRequireOption, AppStorageKeys.Notch.shelfKeepDuration,
        AppStorageKeys.Notch.shelfRemoveAfterDragOut,
        AppStorageKeys.Notch.shelfShowOnExternal, AppStorageKeys.Notch.shelfHaptics,
        AppStorageKeys.Notch.shelfShowMusic,
        AppStorageKeys.Notch.alertsEnabled, AppStorageKeys.Notch.alertAudio,
        AppStorageKeys.Notch.alertPower, AppStorageKeys.Notch.alertBattery,
        AppStorageKeys.Notch.alertBluetooth, AppStorageKeys.Notch.audioMixerEnabled,
        AppStorageKeys.Clipboard.enabled, "clipboardHotKeyCode", "clipboardHotKeyMods",
        "clipboardHotKeyLabel",
        AppStorageKeys.Clipboard.maxItems, AppStorageKeys.Clipboard.maxItemBytes,
        AppStorageKeys.Clipboard.maxAgeDays,
        AppStorageKeys.Clipboard.ignoredApps, AppStorageKeys.Clipboard.autoPaste,
        AppStorageKeys.Clipboard.pastePlainText,
        AppStorageKeys.Clipboard.checkInterval, AppStorageKeys.Clipboard.backup,
        AppStorageKeys.Clipboard.lastBackupAt,
        AppStorageKeys.Clipboard.popupAt, AppStorageKeys.Clipboard.pinTo,
        AppStorageKeys.Clipboard.showFooter,
        AppStorageKeys.Clipboard.saveFiles, AppStorageKeys.Clipboard.saveImages,
        AppStorageKeys.Clipboard.saveText,
        "clipboardWindowPositionX", "clipboardWindowPositionY",
        FocusDimState.enabledKey, AppStorageKeys.FocusDim.intensity,
        AppStorageKeys.FocusDim.animationDuration,
        AppStorageKeys.FocusDim.otherDisplaysMode, AppStorageKeys.FocusDim.hotKeyCode,
        AppStorageKeys.FocusDim.hotKeyMods,
        AppStorageKeys.FocusDim.hotKeyLabel,
        AppStorageKeys.ColorPicker.enabled, AppStorageKeys.ColorPicker.copyFormat,
        AppStorageKeys.ColorPicker.profile,
        AppStorageKeys.ColorPicker.historySize, "colorPickerHotKeyCode", "colorPickerHotKeyMods",
        "colorPickerHotKeyLabel",
        AppStorageKeys.General.creditHidden, AppStorageKeys.General.homeClockZones,
        AppStorageKeys.Presenter.blurCalendar, AppStorageKeys.Presenter.blurAgents,
        AppStorageKeys.General.showDockIcon,
        AppStorageKeys.Music.gridView, "musicFavourites",
        AppStorageKeys.General.mainWindowSection, AppStorageKeys.General.settingsTab,
        AppStorageKeys.General.mainSidebarOpen, AppStorageKeys.General.mainSidebarWidth,
    ]

    nonisolated static let deviceLocalKeys: Set<String> = [
        "extensionsExpand", "hasPromptedPermissions", AppStorageKeys.Backup.lastBackupAt,
        AppStorageKeys.Music.lastBackupAt,
        AppStorageKeys.Clipboard.lastBackupAt, "micMuted", "migratedFromControlCenter",
        "notifSessionLevel", "notifSessionPacing", "notifTokenExpiredAt", "notifWeeklyLevel",
        "notifWeeklyPacing", AppStorageKeys.Permissions.filter, "permissionPromptCount",
        "permissionHintShown",
        "focusDimActive",
        AppStorageKeys.Permissions.accessibilityGranted,
        AppStorageKeys.Permissions.calendarGranted,
        AppStorageKeys.Permissions.cameraGranted, AppStorageKeys.Permissions.fullDiskGranted,
        AppStorageKeys.Permissions.inputMonitoringGranted,
        AppStorageKeys.Permissions.notificationsGranted,
        AppStorageKeys.Permissions.screenRecordingGranted, AppStorageKeys.Presenter.autoActive,
        AppStorageKeys.Presenter.autoPaused,
        AppStorageKeys.Presenter.autoReason, "settingsSection", Repo.musicFolderPathKey,
        Repo.musicFolderStaleKey,
        LidAwakeState.activeKey,
        "musicFolderExternalConfirmation", "musicRevealPath", "repoPathExternalConfirmation",
        "cleanerConfirmedExternalPaths",
        "mainWindowZoom", AppStorageKeys.General.editMainWindowFullScreen,
        AppStorageKeys.Machines.selection, AppStorageKeys.Machines.tab,
        AppStorageKeys.Machines.mode, AppStorageKeys.Companion.tab,
        CompletionScripts.autoRefreshKey, "completionScriptPaths",
        "restorePending.usage", "restorePending.limits", "restorePending.music",
        "restorePending.clipboard", "restoreTimedOut.usage", "restoreTimedOut.limits",
        "restoreTimedOut.music", "restoreTimedOut.clipboard",
    ]

    private func store(for key: String) -> UserDefaults {
        Self.sharedKeys.contains(key) ? SharedDefaults.store : .standard
    }

    private var debounce: Timer?
    private var sweep: Timer?
    nonisolated static let sweepInterval: TimeInterval = 30
    private var localFile: URL { AppData.supportDir.appendingPathComponent("settings.json") }
    private var cloudFile: URL { AppData.cloudDir.appendingPathComponent("settings.json") }

    private var localLimits: URL { LimitsHistory.url }
    private var cloudLimits: URL {
        AppData.cloudDir.appendingPathComponent("data/limits-history.jsonl")
    }
    private var localUsage: URL { Repo.usageJSON }
    private var cloudUsage: URL { AppData.cloudDir.appendingPathComponent("data/usage.json") }
    private var observedICloudBackup = false
    private var pendingRestoreItems:
        [SettingsBackupDataClass: [String: SettingsBackupRestoreItem]] =
            [:]
    private var pendingRestoreStates: [SettingsBackupDataClass: SettingsBackupPendingState] = [:]
    private var restoreTasks: [SettingsBackupDataClass: Task<Void, Never>] = [:]
    private var restoreGenerationState = SettingsBackupRestoreGenerationState()
    private var restoreTokens: [SettingsBackupDataClass: SettingsBackupRestoreToken] = [:]
    private var persistenceMaintenanceTask: Task<Void, Never>?
    private var persistenceMaintenanceGeneration = 0
    private var pendingPersistence = SettingsBackupPersistenceIntents()
    private var settingsExportTask: Task<Void, Never>?
    private var settingsExportGeneration = 0
    private var pendingSettingsData: Data?
    private var settingsRestorePending = false
    private var settingsRestoreDeadline: Date?
    private var settingsRestoreRetry: Timer?
    private var musicDebounce: Timer?
    private var musicFolderObserver: NSObjectProtocol?
    static let settingsRestoreRetryInterval: TimeInterval = 3
    static let settingsRestoreDeadlineInterval: TimeInterval = 600
    nonisolated static let persistenceMaintenanceTimeout: Duration = .seconds(6)
    nonisolated static let persistenceRetryInterval: Duration = .seconds(3)
    nonisolated static let terminationPersistenceRetryInterval: Duration = .milliseconds(50)
    nonisolated static let terminationPersistenceTimeout: Duration = .seconds(1)
    nonisolated static let terminationAttemptTimeout: Duration = .seconds(1)

    private var cloudEnabled: Bool {
        SharedDefaults.store.bool(forKey: AppStorageKeys.Backup.icloud) && AppData.cloudAvailable
    }

    private func flag(_ key: String) -> Bool {
        store(for: key).object(forKey: key) as? Bool ?? true
    }

    private func transferDecision(
        for dataClass: SettingsBackupDataClass
    ) -> SettingsBackupTransferDecision {
        let subToggleEnabled: Bool
        let extensionEnabled: Bool
        switch dataClass {
        case .settings:
            subToggleEnabled = flag(AppStorageKeys.Backup.settings)
            extensionEnabled = true
        case .usage:
            subToggleEnabled = flag(AppStorageKeys.Backup.usage)
            extensionEnabled = SharedDefaults.store.bool(forKey: AppStorageKeys.Tabs.usageEnabled)
        case .limits:
            subToggleEnabled = flag(AppStorageKeys.Backup.limits)
            extensionEnabled = SharedDefaults.store.bool(forKey: AppStorageKeys.Tabs.usageEnabled)
        case .music:
            subToggleEnabled = SharedDefaults.store.bool(forKey: AppStorageKeys.Music.backup)
            extensionEnabled = SharedDefaults.store.bool(forKey: AppStorageKeys.Tabs.musicEnabled)
        case .clipboard:
            subToggleEnabled = SharedDefaults.store.bool(forKey: AppStorageKeys.Clipboard.backup)
            extensionEnabled = SharedDefaults.store.bool(forKey: AppStorageKeys.Clipboard.enabled)
        }
        return settingsBackupTransferDecision(
            for: dataClass,
            masterEnabled: SharedDefaults.store.bool(forKey: AppStorageKeys.Backup.icloud),
            subToggleEnabled: subToggleEnabled,
            extensionEnabled: extensionEnabled)
    }

    func restoreDataOnEnable(for dataClass: SettingsBackupDataClass) {
        guard cloudEnabled else { return }
        let dataExists = cloudDataExists(for: dataClass)
        guard
            settingsBackupEnableRestoreDecision(
                for: dataClass, cloudDataExists: dataExists,
                masterEnabled: SharedDefaults.store.bool(forKey: AppStorageKeys.Backup.icloud))
        else { return }
        let restoreOnly = SettingsBackupTransferDecision(shouldRestore: true, shouldExport: false)
        switch dataClass {
        case .settings:
            return
        case .usage:
            restoreArchive(
                cloudUsage, destination: localUsage, dataClass: dataClass, decision: restoreOnly,
                requireApplicationSupportDestination: false)
        case .limits:
            restoreArchive(
                cloudLimits, destination: localLimits, dataClass: dataClass, decision: restoreOnly,
                requireApplicationSupportDestination: false)
        case .music:
            restoreMusic(
                decision: restoreOnly, requireApplicationSupportDestination: false)
        case .clipboard:
            restoreClipboard(decision: restoreOnly)
        }
    }

    private func cloudDataExists(for dataClass: SettingsBackupDataClass) -> Bool {
        let fm = FileManager.default
        switch dataClass {
        case .settings:
            return false
        case .usage:
            return fm.fileExists(atPath: cloudUsage.path)
                || fm.fileExists(atPath: placeholderURL(for: cloudUsage).path)
        case .limits:
            return fm.fileExists(atPath: cloudLimits.path)
                || fm.fileExists(atPath: placeholderURL(for: cloudLimits).path)
        case .music:
            let directory = AppData.cloudDir.appendingPathComponent("music")
            return !((try? fm.contentsOfDirectory(atPath: directory.path)) ?? []).isEmpty
        case .clipboard:
            let index = cloudClipboardDir.appendingPathComponent("index.jsonl")
            return fm.fileExists(atPath: index.path)
                || fm.fileExists(atPath: placeholderURL(for: index).path)
        }
    }

    private func placeholderURL(for url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).icloud")
    }

    private func restoreArchive(
        _ source: URL,
        destination: URL,
        dataClass: SettingsBackupDataClass,
        decision: SettingsBackupTransferDecision,
        requireApplicationSupportDestination: Bool
    ) {
        guard decision.shouldRestore,
            !requireApplicationSupportDestination || isApplicationSupportURL(destination),
            cloudFileExists(at: source)
        else {
            clearRestoreState(for: dataClass)
            return
        }
        beginProgressiveRestore(
            [
                SettingsBackupRestoreItem(
                    name: source.lastPathComponent, source: source, destination: destination)
            ],
            for: dataClass)
    }

    private func isApplicationSupportURL(_ url: URL) -> Bool {
        let supportPath = AppData.supportDir.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        return path == supportPath || path.hasPrefix(supportPath + "/")
    }

    private func cloudFileExists(at url: URL) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: url.path)
            || fm.fileExists(atPath: placeholderURL(for: url).path)
    }

    private func missingRestoreItems(from source: URL, to destination: URL)
        -> [SettingsBackupRestoreItem]
    {
        let cloudFiles = filesByRelativeName(in: source, normalizePlaceholders: true)
        let localNames = Set(filesByRelativeName(in: destination).keys)
        let missingNames = settingsBackupMissingNames(
            cloudNames: Set(cloudFiles.keys), localNames: localNames)
        return missingNames.sorted().compactMap { name in
            guard let cloudFile = cloudFiles[name] else { return nil }
            return SettingsBackupRestoreItem(
                name: name,
                source: cloudFile,
                destination: destination.appendingPathComponent(name))
        }
    }

    private func filesByRelativeName(
        in root: URL,
        normalizePlaceholders: Bool = false
    ) -> [String: URL] {
        let fm = FileManager.default
        guard
            let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsPackageDescendants])
        else { return [:] }
        var files: [String: URL] = [:]
        while let url = enumerator.nextObject() as? URL {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
            if values?.isDirectory == true { continue }
            guard var name = relativeName(of: url, in: root) else { continue }
            if normalizePlaceholders {
                name = normalizedPlaceholderName(name)
            }
            guard !name.isEmpty, (name as NSString).lastPathComponent != ".DS_Store" else {
                continue
            }
            files[name] = root.appendingPathComponent(name)
        }
        return files
    }

    private func relativeName(of url: URL, in root: URL) -> String? {
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard url.path.hasPrefix(rootPath) else { return nil }
        return String(url.path.dropFirst(rootPath.count))
    }

    private func normalizedPlaceholderName(_ name: String) -> String {
        let path = name as NSString
        let component = path.lastPathComponent
        guard component.hasPrefix("."), component.hasSuffix(".icloud") else { return name }
        let original = String(component.dropFirst().dropLast(".icloud".count))
        let parent = path.deletingLastPathComponent
        return parent.isEmpty ? original : (parent as NSString).appendingPathComponent(original)
    }

    private func beginProgressiveRestore(
        _ items: [SettingsBackupRestoreItem],
        for dataClass: SettingsBackupDataClass
    ) {
        restoreTasks[dataClass]?.cancel()
        restoreTokens[dataClass]?.invalidate()
        let restoreToken = SettingsBackupRestoreToken()
        restoreTokens[dataClass] = restoreToken
        let generation = restoreGenerationState.begin(dataClass)
        let itemsByName = Dictionary(
            items.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        pendingRestoreItems[dataClass] = itemsByName
        pendingRestoreStates[dataClass] = SettingsBackupPendingState(Set(itemsByName.keys))
        setRestorePending(itemsByName.count, for: dataClass)
        setRestoreTimedOut(0, for: dataClass)
        guard !itemsByName.isEmpty else {
            pendingRestoreItems.removeValue(forKey: dataClass)
            pendingRestoreStates.removeValue(forKey: dataClass)
            restoreTasks.removeValue(forKey: dataClass)
            return
        }
        if dataClass == .music {
            IPC.post(IPC.Name.musicFolderChanged)
        }
        for item in itemsByName.values where !isCloudFileCurrent(item.source) {
            requestCloudDownload(for: item.source)
        }
        let deadline = Date().addingTimeInterval(600)
        restoreTasks[dataClass] = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.processPendingRestore(
                    for: dataClass, generation: generation, restoreToken: restoreToken)
                guard !Task.isCancelled,
                    self.restoreGenerationState.accepts(generation, for: dataClass)
                else {
                    return
                }
                if self.pendingRestoreStates[dataClass]?.remaining.isEmpty != false { return }
                if Date() >= deadline {
                    self.timeOutRestore(for: dataClass)
                    return
                }
                do {
                    try await Task.sleep(nanoseconds: 3_000_000_000)
                } catch {
                    return
                }
            }
        }
    }

    private func isCloudFileCurrent(_ url: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return false }
        let values = try? url.resourceValues(
            forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
        if values?.isUbiquitousItem == true {
            return values?.ubiquitousItemDownloadingStatus == .current
        }
        return fm.isReadableFile(atPath: url.path)
    }

    private func requestCloudDownload(for url: URL) {
        do {
            try FileManager.default.startDownloadingUbiquitousItem(at: url)
        } catch {
            try? FileManager.default.startDownloadingUbiquitousItem(
                at: url.deletingLastPathComponent())
        }
    }

    private func processPendingRestore(
        for dataClass: SettingsBackupDataClass, generation: Int,
        restoreToken: SettingsBackupRestoreToken
    ) async {
        guard !Task.isCancelled, restoreGenerationState.accepts(generation, for: dataClass) else {
            return
        }
        guard var state = pendingRestoreStates[dataClass],
            let items = pendingRestoreItems[dataClass]
        else { return }
        for name in state.remaining.sorted() {
            guard
                let item = items[name],
                await restoreIfReady(
                    item, for: dataClass, generation: generation, restoreToken: restoreToken)
            else {
                continue
            }
            guard !Task.isCancelled, restoreGenerationState.accepts(generation, for: dataClass)
            else { return }
            state.complete(name)
        }
        guard !Task.isCancelled, restoreGenerationState.accepts(generation, for: dataClass) else {
            return
        }
        pendingRestoreStates[dataClass] = state
        setRestorePending(state.remaining.count, for: dataClass)
        if state.remaining.isEmpty {
            finishRestore(for: dataClass)
        }
    }

    private func restoreIfReady(
        _ item: SettingsBackupRestoreItem,
        for dataClass: SettingsBackupDataClass,
        generation: Int,
        restoreToken: SettingsBackupRestoreToken
    ) async -> Bool {
        guard !Task.isCancelled, restoreGenerationState.accepts(generation, for: dataClass),
            isCloudFileCurrent(item.source)
        else { return false }
        switch dataClass {
        case .settings:
            return true
        case .usage:
            guard
                await transferUsage(
                    decision: SettingsBackupTransferDecision(
                        shouldRestore: true, shouldExport: false),
                    restore: true, export: false, requireApplicationSupportRestore: false,
                    restoreToken: restoreToken) == .done
            else { return false }
            guard !Task.isCancelled, restoreGenerationState.accepts(generation, for: dataClass)
            else {
                return false
            }
            restoreDidChange(.usage)
            return true
        case .limits:
            guard
                await transferLimits(
                    decision: SettingsBackupTransferDecision(
                        shouldRestore: true, shouldExport: false),
                    restore: true, export: false, requireApplicationSupportRestore: false,
                    restoreToken: restoreToken) == .done
            else { return false }
            guard !Task.isCancelled, restoreGenerationState.accepts(generation, for: dataClass)
            else {
                return false
            }
            restoreDidChange(.limits)
            return true
        case .music, .clipboard:
            let restored = await Task.detached(priority: .utility) {
                let fm = FileManager.default
                if fm.fileExists(atPath: item.destination.path) { return true }
                let staged = item.destination.deletingLastPathComponent().appendingPathComponent(
                    ".restore-\(UUID().uuidString)")
                defer { try? fm.removeItem(at: staged) }
                do {
                    try fm.createDirectory(
                        at: item.destination.deletingLastPathComponent(),
                        withIntermediateDirectories: true)
                    try fm.copyItem(at: item.source, to: staged)
                    return try restoreToken.performIfValid {
                        if !fm.fileExists(atPath: item.destination.path) {
                            try fm.moveItem(at: staged, to: item.destination)
                        }
                    }
                } catch {
                    return false
                }
            }.value
            guard !Task.isCancelled, restoreGenerationState.accepts(generation, for: dataClass)
            else {
                return false
            }
            if restored { restoreDidChange(dataClass) }
            return restored
        }
    }

    private func restoreDidChange(_ dataClass: SettingsBackupDataClass) {
        switch dataClass {
        case .settings:
            return
        case .usage:
            NotificationCenter.default.post(name: .usageBackupRestored, object: nil)
            IPC.post(IPC.Name.usageRefreshFinished)
        case .limits:
            NotificationCenter.default.post(name: .limitsBackupRestored, object: nil)
            IPC.post(IPC.Name.limitsUpdated)
        case .music:
            NotificationCenter.default.post(name: .musicFolderChangedLocally, object: nil)
            IPC.post(IPC.Name.musicFolderChanged)
        case .clipboard:
            IPC.post(IPC.Name.clipboardChanged)
        }
    }

    private func finishRestore(for dataClass: SettingsBackupDataClass) {
        restoreTasks[dataClass]?.cancel()
        restoreTasks.removeValue(forKey: dataClass)
        pendingRestoreItems.removeValue(forKey: dataClass)
        pendingRestoreStates.removeValue(forKey: dataClass)
        restoreTokens.removeValue(forKey: dataClass)
        setRestorePending(0, for: dataClass)
        setRestoreTimedOut(0, for: dataClass)
        if dataClass == .clipboard {
            ClipboardRepository.pruneEntriesMissingBlobs()
            IPC.post(IPC.Name.clipboardChanged)
        }
    }

    private func timeOutRestore(for dataClass: SettingsBackupDataClass) {
        let remaining = pendingRestoreStates[dataClass]?.remaining ?? []
        restoreTasks[dataClass]?.cancel()
        restoreTokens[dataClass]?.invalidate()
        restoreTokens.removeValue(forKey: dataClass)
        restoreTasks.removeValue(forKey: dataClass)
        pendingRestoreItems.removeValue(forKey: dataClass)
        pendingRestoreStates.removeValue(forKey: dataClass)
        setRestorePending(0, for: dataClass)
        setRestoreTimedOut(remaining.count, for: dataClass)
        if dataClass == .music {
            IPC.post(IPC.Name.musicFolderChanged)
        }
        NSLog(
            "iCloud restore timed out for %@ with %ld files remaining: %@",
            dataClass.rawValue, remaining.count, remaining.sorted().joined(separator: ", "))
    }

    private func clearRestoreState(for dataClass: SettingsBackupDataClass) {
        let previousPending = SharedDefaults.store.integer(
            forKey: "restorePending.\(dataClass.rawValue)")
        restoreTasks[dataClass]?.cancel()
        restoreTokens[dataClass]?.invalidate()
        restoreTokens.removeValue(forKey: dataClass)
        restoreGenerationState.invalidate(dataClass)
        restoreTasks.removeValue(forKey: dataClass)
        pendingRestoreItems.removeValue(forKey: dataClass)
        pendingRestoreStates.removeValue(forKey: dataClass)
        setRestorePending(0, for: dataClass)
        setRestoreTimedOut(0, for: dataClass)
        if dataClass == .music, previousPending > 0 {
            IPC.post(IPC.Name.musicFolderChanged)
        }
    }

    private func setRestorePending(_ count: Int, for dataClass: SettingsBackupDataClass) {
        SharedDefaults.store.set(count, forKey: "restorePending.\(dataClass.rawValue)")
    }

    private func setRestoreTimedOut(_ count: Int, for dataClass: SettingsBackupDataClass) {
        SharedDefaults.store.set(count, forKey: "restoreTimedOut.\(dataClass.rawValue)")
    }

    func start() {
        for dataClass in SettingsBackupDataClass.allCases
        where dataClass != .settings && restoreTasks[dataClass] == nil {
            clearRestoreState(for: dataClass)
        }
        observedICloudBackup = SharedDefaults.store.bool(forKey: AppStorageKeys.Backup.icloud)
        beginSettingsRestore()
        let restored = restoreFromCloud()
        export()
        queuePersistence(
            limitsRestore: false, limitsExport: true, usageRestore: false, usageExport: true)
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.scheduleExport() }
        }
        sweep?.invalidate()
        sweep = Timer.scheduledTimer(
            withTimeInterval: Self.sweepInterval, repeats: true
        ) { _ in
            Task { @MainActor in SettingsBackup.shared.export() }
        }
        if !restored.music {
            backupMusic()
        }
        if !restored.clipboard {
            backupClipboard()
        }
        musicFolderObserver = IPC.observe(IPC.Name.musicFolderChanged) {
            Task { @MainActor in SettingsBackup.shared.scheduleMusicBackup() }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.shutdown()
            }
        }
    }

    func settingsDidChange() {
        let icloudBackup = SharedDefaults.store.bool(forKey: AppStorageKeys.Backup.icloud)
        let shouldRestore = icloudBackup && !observedICloudBackup
        observedICloudBackup = icloudBackup
        for dataClass in SettingsBackupDataClass.allCases where dataClass != .settings {
            if !transferDecision(for: dataClass).shouldRestore {
                clearRestoreState(for: dataClass)
            }
        }
        if shouldRestore {
            _ = restoreFromCloud()
            observedICloudBackup = SharedDefaults.store.bool(forKey: AppStorageKeys.Backup.icloud)
            queuePersistence(
                limitsRestore: false, limitsExport: true, usageRestore: false,
                usageExport: true)
            backupMusic()
        }
        scheduleExport()
        scheduleClipboardBackup()
    }

    @discardableResult
    private func restoreFromCloud() -> (music: Bool, clipboard: Bool) {
        guard cloudEnabled else {
            return (false, false)
        }
        importFromCloudIfNewer(decision: transferDecision(for: .settings))
        let decisions = Dictionary(
            uniqueKeysWithValues: SettingsBackupDataClass.allCases.map {
                ($0, transferDecision(for: $0))
            })
        if decisions[.limits]!.shouldExport {
            restoreArchive(
                cloudLimits, destination: localLimits, dataClass: .limits,
                decision: decisions[.limits]!, requireApplicationSupportDestination: true)
        }
        if decisions[.usage]!.shouldExport {
            restoreArchive(
                cloudUsage, destination: localUsage, dataClass: .usage,
                decision: decisions[.usage]!, requireApplicationSupportDestination: true)
        }
        let music = restoreMusic(
            decision: SettingsBackupTransferDecision(
                shouldRestore: decisions[.music]!.shouldExport, shouldExport: false),
            requireApplicationSupportDestination: true)
        let clipboard = restoreClipboard(
            decision: SettingsBackupTransferDecision(
                shouldRestore: decisions[.clipboard]!.shouldExport, shouldExport: false))
        return (music, clipboard)
    }

    private func shutdown() {
        sweep?.invalidate()
        sweep = nil
        for task in restoreTasks.values {
            task.cancel()
        }
        persistenceMaintenanceGeneration += 1
        persistenceMaintenanceTask?.cancel()
        persistenceMaintenanceTask = nil
        settingsExportGeneration += 1
        settingsExportTask?.cancel()
        settingsExportTask = nil
        pendingSettingsData = nil
        for dataClass in SettingsBackupDataClass.allCases {
            restoreGenerationState.invalidate(dataClass)
            restoreTokens[dataClass]?.invalidate()
        }
        restoreTokens.removeAll()
        restoreTasks.removeAll()
        pendingRestoreItems.removeAll()
        pendingRestoreStates.removeAll()
        for dataClass in SettingsBackupDataClass.allCases where dataClass != .settings {
            setRestorePending(0, for: dataClass)
        }
    }

    func debounceFlush() {
        if debounce?.isValid == true {
            debounce?.invalidate()
            export()
        }
    }

    func prepareForTermination() {
        debounce?.invalidate()
        debounce = nil
    }

    func backupMusic() {
        guard !musicBackupRunning, cloudEnabled,
            pendingRestoreStates[.music] == nil,
            transferDecision(for: .music).shouldExport,
            FileManager.default.fileExists(atPath: Repo.musicDir.path)
        else { return }
        musicBackupRunning = true
        let destination = AppData.cloudDir.appendingPathComponent("music")
        try? FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/rsync")
        p.arguments = ["-a", "--delete", Repo.musicDir.path + "/", destination.path + "/"]
        p.qualityOfService = .utility
        p.terminationHandler = { process in
            Task { @MainActor in
                self.musicBackupRunning = false
                if process.terminationStatus == 0 {
                    SharedDefaults.store.set(
                        Date().timeIntervalSince1970, forKey: AppStorageKeys.Music.lastBackupAt)
                }
            }
        }
        do {
            try p.run()
        } catch {
            musicBackupRunning = false
        }
    }

    @discardableResult
    private func restoreMusic(
        decision: SettingsBackupTransferDecision,
        requireApplicationSupportDestination: Bool
    ) -> Bool {
        let destination = Repo.musicDir
        guard decision.shouldRestore,
            !requireApplicationSupportDestination || isApplicationSupportURL(destination)
        else {
            clearRestoreState(for: .music)
            return false
        }
        let source = AppData.cloudDir.appendingPathComponent("music")
        let items = missingRestoreItems(from: source, to: destination)
        beginProgressiveRestore(items, for: .music)
        return !items.isEmpty
    }

    private var localClipboardDir: URL { ClipboardPaths.dir }
    private var cloudClipboardDir: URL { AppData.cloudDir.appendingPathComponent("clipboard") }
    private var clipboardDebounce: Timer?

    func scheduleClipboardBackup() {
        guard cloudEnabled, transferDecision(for: .clipboard).shouldExport else {
            clipboardDebounce?.invalidate()
            clipboardDebounce = nil
            return
        }
        clipboardDebounce?.invalidate()
        clipboardDebounce = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { _ in
            Task { @MainActor in SettingsBackup.shared.backupClipboard() }
        }
    }

    func backupClipboard() {
        guard !clipboardBackupRunning, cloudEnabled,
            transferDecision(for: .clipboard).shouldExport,
            FileManager.default.fileExists(atPath: localClipboardDir.path)
        else { return }
        clipboardBackupRunning = true
        try? FileManager.default.createDirectory(
            at: cloudClipboardDir, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/rsync")
        p.arguments = [
            "-a", "--delete", "--max-size=1m",
            "--include", "*/", "--include", "index.jsonl",
            "--include", "*.txt", "--include", "*.rtf", "--include", "*.html",
            "--include", "*.url", "--include", "*.png", "--include", "*.tiff",
            "--exclude", "*",
            localClipboardDir.path + "/", cloudClipboardDir.path + "/",
        ]
        p.qualityOfService = .utility
        p.terminationHandler = { process in
            Task { @MainActor in
                self.clipboardBackupRunning = false
                if process.terminationStatus == 0 {
                    SharedDefaults.store.set(
                        Date().timeIntervalSince1970, forKey: AppStorageKeys.Clipboard.lastBackupAt)
                }
            }
        }
        do {
            try p.run()
        } catch {
            clipboardBackupRunning = false
        }
    }

    @discardableResult
    private func restoreClipboard(
        decision: SettingsBackupTransferDecision
    ) -> Bool {
        guard decision.shouldRestore else {
            clearRestoreState(for: .clipboard)
            return false
        }
        let items = missingRestoreItems(from: cloudClipboardDir, to: localClipboardDir)
        beginProgressiveRestore(items, for: .clipboard)
        return !items.isEmpty
    }

    func scheduleExport() {
        debounce?.invalidate()
        debounce = Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { _ in
            Task { @MainActor in SettingsBackup.shared.export() }
        }
    }

    private func snapshot() -> Data? {
        var dict: [String: Any] = [:]
        for key in Self.backedKeys {
            if let value = store(for: key).object(forKey: key) { dict[key] = value }
        }
        return try? JSONSerialization.data(
            withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
    }

    func export() {
        guard !settingsRestorePending else { return }
        guard let data = snapshot() else { return }
        pendingSettingsData = data
        guard settingsExportTask == nil else { return }
        settingsExportGeneration += 1
        let generation = settingsExportGeneration
        settingsExportTask = Task { [weak self] in
            await self?.drainSettingsExports(generation: generation)
        }
    }

    private func drainSettingsExports(generation: Int) async {
        await settingsBackupDrainSettingsExports(
            generation: generation, ownsGeneration: { settingsExportGeneration == $0 },
            takePending: {
                let data = pendingSettingsData
                pendingSettingsData = nil
                return data
            },
            publish: { data in
                await SettingsBackupFileWorker.shared.exportSettings(
                    data: data, localURL: localFile, cloudURL: cloudFile,
                    shouldExportCloud: transferDecision(for: .settings).shouldExport)
            },
            didPublish: { exported in
                if exported {
                    SharedDefaults.store.set(
                        Date().timeIntervalSince1970,
                        forKey: AppStorageKeys.Backup.lastBackupAt)
                }
            })
        guard settingsExportGeneration == generation else { return }
        settingsExportTask = nil
        if pendingSettingsData != nil { export() }
    }

    func syncData() async {
        _ = await syncLimits()
        _ = await syncUsage()
    }

    @discardableResult
    func syncLimits() async -> Bool {
        let decision = transferDecision(for: .limits)
        return await transferLimits(
            decision: decision, restore: true, export: true,
            requireApplicationSupportRestore: false) == .done
    }

    @discardableResult
    private func exportLimits() async -> Bool {
        let decision = transferDecision(for: .limits)
        return await transferLimits(
            decision: decision, restore: false, export: true,
            requireApplicationSupportRestore: false) == .done
    }

    private func transferLimits(
        decision: SettingsBackupTransferDecision,
        restore: Bool,
        export: Bool,
        requireApplicationSupportRestore: Bool,
        restoreToken: SettingsBackupRestoreToken? = nil,
        attemptTimeout: Duration? = nil
    ) async -> SettingsBackupTransferOutcome {
        let backupEnabled = SharedDefaults.store.bool(forKey: AppStorageKeys.Backup.icloud)
        guard backupEnabled else { return .unavailable }
        let shouldRestore =
            restore && decision.shouldRestore
            && (!requireApplicationSupportRestore || isApplicationSupportURL(localLimits))
        let shouldExport = export && decision.shouldExport
        guard shouldRestore || shouldExport else { return .done }
        let localURL = localLimits
        let cloudURL = cloudLimits
        guard let attemptTimeout else {
            return await SettingsBackupUsageWorker.shared.transferLimitsOutcome(
                localURL: localURL, cloudURL: cloudURL,
                shouldRestore: shouldRestore, shouldExport: shouldExport,
                backupEnabled: backupEnabled,
                restoreToken: restoreToken)
        }
        return await settingsBackupBoundedTransfer(timeout: attemptTimeout) {
            await SettingsBackupUsageWorker.shared.transferLimitsOutcome(
                localURL: localURL, cloudURL: cloudURL,
                shouldRestore: shouldRestore, shouldExport: shouldExport,
                backupEnabled: backupEnabled,
                restoreToken: restoreToken)
        }
    }

    @discardableResult
    func syncUsage() async -> Bool {
        let decision = transferDecision(for: .usage)
        return await transferUsage(
            decision: decision, restore: true, export: true,
            requireApplicationSupportRestore: false) == .done
    }

    @discardableResult
    private func exportUsage() async -> Bool {
        let decision = transferDecision(for: .usage)
        return await transferUsage(
            decision: decision, restore: false, export: true,
            requireApplicationSupportRestore: false) == .done
    }

    private func transferUsage(
        decision: SettingsBackupTransferDecision,
        restore: Bool,
        export: Bool,
        requireApplicationSupportRestore: Bool,
        restoreToken: SettingsBackupRestoreToken? = nil,
        attemptTimeout: Duration? = nil
    ) async -> SettingsBackupTransferOutcome {
        let backupEnabled = SharedDefaults.store.bool(forKey: AppStorageKeys.Backup.icloud)
        guard backupEnabled else { return .unavailable }
        let shouldRestore =
            restore && decision.shouldRestore
            && (!requireApplicationSupportRestore || isApplicationSupportURL(localUsage))
        let shouldExport = export && decision.shouldExport
        guard shouldRestore || shouldExport else { return .done }
        let localURL = localUsage
        let cloudURL = cloudUsage
        guard let attemptTimeout else {
            return await SettingsBackupUsageWorker.shared.transferUsageOutcome(
                localURL: localURL, cloudURL: cloudURL,
                shouldRestore: shouldRestore, shouldExport: shouldExport,
                backupEnabled: backupEnabled,
                restoreToken: restoreToken)
        }
        return await settingsBackupBoundedTransfer(timeout: attemptTimeout) {
            await SettingsBackupUsageWorker.shared.transferUsageOutcome(
                localURL: localURL, cloudURL: cloudURL,
                shouldRestore: shouldRestore, shouldExport: shouldExport,
                backupEnabled: backupEnabled,
                restoreToken: restoreToken)
        }
    }

    private func queuePersistence(
        limitsRestore: Bool, limitsExport: Bool, usageRestore: Bool, usageExport: Bool
    ) {
        pendingPersistence.formUnion(
            SettingsBackupPersistenceIntents(
                limitsRestore: limitsRestore, limitsExport: limitsExport,
                usageRestore: usageRestore, usageExport: usageExport))
        guard persistenceMaintenanceTask == nil else { return }
        persistenceMaintenanceGeneration += 1
        let generation = persistenceMaintenanceGeneration
        let deadline = ContinuousClock().now.advanced(by: Self.persistenceMaintenanceTimeout)
        persistenceMaintenanceTask = Task { [weak self] in
            await self?.drainPersistence(
                generation: generation, deadline: deadline,
                retryInterval: Self.persistenceRetryInterval)
        }
    }

    private func drainPersistence(
        generation: Int, deadline: ContinuousClock.Instant?, retryInterval: Duration,
        terminationAttemptTimeout: Duration? = nil
    ) async {
        while !Task.isCancelled, persistenceMaintenanceGeneration == generation {
            let intents = pendingPersistence
            guard !intents.isEmpty else { break }
            pendingPersistence = SettingsBackupPersistenceIntents()
            let remaining = await settingsBackupRetryPersistence(
                intents, deadline: deadline, retryInterval: retryInterval,
                transferLimits: { [weak self] restore, export in
                    guard let self else { return false }
                    let outcome = await self.transferLimits(
                        decision: self.transferDecision(for: .limits), restore: restore,
                        export: export, requireApplicationSupportRestore: false,
                        attemptTimeout: terminationAttemptTimeout)
                    return terminationAttemptTimeout == nil
                        ? outcome == .done : outcome != .retryable
                },
                transferUsage: { [weak self] restore, export in
                    guard let self else { return false }
                    let outcome = await self.transferUsage(
                        decision: self.transferDecision(for: .usage), restore: restore,
                        export: export, requireApplicationSupportRestore: false,
                        attemptTimeout: terminationAttemptTimeout)
                    return terminationAttemptTimeout == nil
                        ? outcome == .done : outcome != .retryable
                })
            pendingPersistence.formUnion(remaining)
            guard !Task.isCancelled, persistenceMaintenanceGeneration == generation else {
                return
            }
            if !remaining.isEmpty { break }
        }
        guard persistenceMaintenanceGeneration == generation else { return }
        persistenceMaintenanceTask = nil
    }

    func flushForTermination(
        persistenceTimeout: Duration = SettingsBackup.terminationPersistenceTimeout,
        persistenceRetryInterval: Duration = SettingsBackup.terminationPersistenceRetryInterval,
        attemptTimeout: Duration = SettingsBackup.terminationAttemptTimeout
    ) async {
        prepareForTermination()
        let previousSettingsExport = settingsExportTask
        settingsExportGeneration += 1
        let settingsGeneration = settingsExportGeneration
        let finalSettingsExport = Task { [weak self] in
            guard let self else { return }
            guard
                await settingsBackupAwaitFinalSettingsExport(
                    after: previousSettingsExport, generation: settingsGeneration,
                    ownsGeneration: { self.settingsExportGeneration == $0 })
            else { return }
            if !self.settingsRestorePending {
                self.pendingSettingsData = self.snapshot()
            }
            await self.drainSettingsExports(generation: settingsGeneration)
        }
        settingsExportTask = finalSettingsExport
        let previousPersistence = persistenceMaintenanceTask
        persistenceMaintenanceGeneration += 1
        previousPersistence?.cancel()
        await previousPersistence?.value
        guard !Task.isCancelled else { return }
        persistenceMaintenanceTask = nil
        guard cloudEnabled else {
            await withTaskCancellationHandler {
                await finalSettingsExport.value
            } onCancel: {
                finalSettingsExport.cancel()
            }
            return
        }
        pendingPersistence.formUnion(
            SettingsBackupPersistenceIntents(
                limitsRestore: false, limitsExport: true, usageRestore: false,
                usageExport: true))
        persistenceMaintenanceGeneration += 1
        let generation = persistenceMaintenanceGeneration
        let deadline = ContinuousClock().now.advanced(
            by: max(persistenceTimeout, .zero))
        let persistence = Task { [weak self] in
            guard let self else { return }
            await self.drainPersistence(
                generation: generation, deadline: deadline,
                retryInterval: persistenceRetryInterval,
                terminationAttemptTimeout: attemptTimeout)
        }
        persistenceMaintenanceTask = persistence
        await withTaskCancellationHandler {
            await persistence.value
            await finalSettingsExport.value
        } onCancel: {
            persistence.cancel()
            finalSettingsExport.cancel()
        }
    }

    private func importFromCloudIfNewer(decision: SettingsBackupTransferDecision) {
        guard decision.shouldRestore else {
            finishSettingsRestore()
            return
        }
        let fm = FileManager.default
        guard cloudFileExists(at: cloudFile) else {
            finishSettingsRestore()
            return
        }
        guard
            let cloudDate = (try? fm.attributesOfItem(atPath: cloudFile.path))?[.modificationDate]
                as? Date
        else {
            awaitSettingsDownload()
            return
        }
        let localDate =
            (try? fm.attributesOfItem(atPath: localFile.path))?[.modificationDate] as? Date
            ?? .distantPast
        guard
            settingsBackupShouldImport(
                localFileExists: fm.fileExists(atPath: localFile.path),
                freshInstall: localSettingsAreEmpty,
                cloudDate: cloudDate, localDate: localDate)
        else {
            finishSettingsRestore()
            return
        }
        guard let data = settingsBackupReadCloudSettingsFile(at: cloudFile),
            let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            awaitSettingsDownload()
            return
        }
        for (key, value) in dict where Self.backedKeys.contains(key) {
            switch key {
            case Repo.pathKey:
                guard let path = value as? String else { continue }
                guard RestoredPathValidation.verdict(for: path) == .keep else {
                    Repo.setDevRootPath(nil)
                    SharedDefaults.store.set(true, forKey: Repo.musicFolderStaleKey)
                    continue
                }
                store(for: key).set(path, forKey: key)
            case "cleanerSelectedDrives", "cleanerCustomFolders":
                guard let paths = value as? [String] else { continue }
                store(for: key).set(
                    paths.filter { RestoredPathValidation.verdict(for: $0) == .keep },
                    forKey: key)
            case LidAwakeState.batteryThresholdKey:
                guard let threshold = settingsBackupLidAwakeBatteryThreshold(value) else {
                    continue
                }
                store(for: key).set(threshold, forKey: key)
            default:
                store(for: key).set(value, forKey: key)
            }
        }
        Repo.prepareStoredPaths()
        try? data.write(to: localFile)
        HotKey.register()
        IPC.post(IPC.Name.settingsChanged)
        finishSettingsRestore()
    }

    private var localSettingsAreEmpty: Bool {
        SharedDefaults.store.bool(forKey: ExtensionDefaultsMigration.freshInstallKey)
    }

    private func beginSettingsRestore() {
        guard cloudEnabled, cloudFileExists(at: cloudFile) else {
            finishSettingsRestore()
            return
        }
        settingsRestorePending = true
        settingsRestoreDeadline = Date().addingTimeInterval(Self.settingsRestoreDeadlineInterval)
    }

    private func awaitSettingsDownload() {
        try? FileManager.default.startDownloadingUbiquitousItem(at: cloudFile)
        guard settingsRestorePending else { return }
        guard let deadline = settingsRestoreDeadline, Date() < deadline else {
            finishSettingsRestore()
            return
        }
        settingsRestoreRetry?.invalidate()
        settingsRestoreRetry = Timer.scheduledTimer(
            withTimeInterval: Self.settingsRestoreRetryInterval, repeats: false
        ) { _ in
            Task { @MainActor in
                SettingsBackup.shared.retrySettingsRestore()
            }
        }
    }

    private func retrySettingsRestore() {
        guard settingsRestorePending else { return }
        importFromCloudIfNewer(decision: transferDecision(for: .settings))
    }

    private func finishSettingsRestore() {
        settingsRestoreRetry?.invalidate()
        settingsRestoreRetry = nil
        settingsRestoreDeadline = nil
        guard settingsRestorePending else { return }
        settingsRestorePending = false
        export()
    }

    func scheduleMusicBackup() {
        guard cloudEnabled, transferDecision(for: .music).shouldExport,
            pendingRestoreStates[.music] == nil
        else {
            musicDebounce?.invalidate()
            musicDebounce = nil
            return
        }
        musicDebounce?.invalidate()
        musicDebounce = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { _ in
            Task { @MainActor in SettingsBackup.shared.backupMusic() }
        }
    }
}

extension Notification.Name {
    static let usageBackupRestored = Notification.Name("usageBackupRestored")
    static let limitsBackupRestored = Notification.Name("limitsBackupRestored")
}
