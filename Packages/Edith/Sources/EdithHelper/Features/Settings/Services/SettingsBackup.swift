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

struct SettingsBackupPendingState: Equatable, Sendable {
    private(set) var remaining: Set<String>

    init(_ names: Set<String> = []) {
        remaining = names
    }

    mutating func complete(_ name: String) {
        remaining.remove(name)
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
        AppStorageKeys.Tabs.usageEnabled, AppStorageKeys.Tabs.musicEnabled, "usageMachines",
        AppStorageKeys.Tabs.herdrEnabled,
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
        "dashBillingDay", "dashSort", "dashSortAsc",
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
        AppStorageKeys.Tabs.usageEnabled, AppStorageKeys.Tabs.musicEnabled,
        AppStorageKeys.Tabs.herdrEnabled,
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
        "dashBillingDay", "dashSort", "dashSortAsc",
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
    static let sweepInterval: TimeInterval = 30
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
    private var settingsRestorePending = false
    private var settingsRestoreDeadline: Date?
    private var settingsRestoreRetry: Timer?
    private var musicDebounce: Timer?
    private var musicFolderObserver: NSObjectProtocol?
    static let settingsRestoreRetryInterval: TimeInterval = 3
    static let settingsRestoreDeadlineInterval: TimeInterval = 600

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
        processPendingRestore(for: dataClass)
        guard pendingRestoreStates[dataClass]?.remaining.isEmpty == false else { return }
        let deadline = Date().addingTimeInterval(600)
        restoreTasks[dataClass] = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 3_000_000_000)
                } catch {
                    return
                }
                guard self != nil else { return }
                if Date() >= deadline {
                    self?.timeOutRestore(for: dataClass)
                    return
                }
                self?.processPendingRestore(for: dataClass)
                if self?.pendingRestoreStates[dataClass]?.remaining.isEmpty != false { return }
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

    private func processPendingRestore(for dataClass: SettingsBackupDataClass) {
        guard var state = pendingRestoreStates[dataClass],
            let items = pendingRestoreItems[dataClass]
        else { return }
        for name in state.remaining.sorted() {
            guard let item = items[name], restoreIfReady(item, for: dataClass) else { continue }
            state.complete(name)
        }
        pendingRestoreStates[dataClass] = state
        setRestorePending(state.remaining.count, for: dataClass)
        if state.remaining.isEmpty {
            finishRestore(for: dataClass)
        }
    }

    private func restoreIfReady(
        _ item: SettingsBackupRestoreItem,
        for dataClass: SettingsBackupDataClass
    ) -> Bool {
        guard isCloudFileCurrent(item.source) else { return false }
        switch dataClass {
        case .settings:
            return true
        case .usage:
            guard (try? Data(contentsOf: item.source)) != nil else { return false }
            transferUsage(
                decision: SettingsBackupTransferDecision(shouldRestore: true, shouldExport: false),
                restore: true, export: false, requireApplicationSupportRestore: false)
            restoreDidChange(.usage)
            return true
        case .limits:
            guard (try? Data(contentsOf: item.source)) != nil else { return false }
            transferLimits(
                decision: SettingsBackupTransferDecision(shouldRestore: true, shouldExport: false),
                restore: true, export: false, requireApplicationSupportRestore: false)
            restoreDidChange(.limits)
            return true
        case .music, .clipboard:
            let fm = FileManager.default
            if fm.fileExists(atPath: item.destination.path) { return true }
            do {
                try fm.createDirectory(
                    at: item.destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true)
                try fm.copyItem(at: item.source, to: item.destination)
                restoreDidChange(dataClass)
                return true
            } catch {
                return false
            }
        }
    }

    private func restoreDidChange(_ dataClass: SettingsBackupDataClass) {
        switch dataClass {
        case .settings:
            return
        case .usage:
            IPC.post(IPC.Name.usageRefreshFinished)
        case .limits:
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
        exportLimits()
        exportUsage()
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
                self?.debounceFlush()
                self?.syncLimits()
                self?.shutdown()
            }
        }
    }

    func settingsDidChange() {
        let icloudBackup = SharedDefaults.store.bool(forKey: AppStorageKeys.Backup.icloud)
        let shouldRestore = icloudBackup && !observedICloudBackup
        observedICloudBackup = icloudBackup
        if shouldRestore {
            _ = restoreFromCloud()
            observedICloudBackup = SharedDefaults.store.bool(forKey: AppStorageKeys.Backup.icloud)
            exportLimits()
            exportUsage()
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
        if (try? Data(contentsOf: localFile)) != data {
            try? data.write(to: localFile)
        }
        guard cloudEnabled, transferDecision(for: .settings).shouldExport else { return }
        try? FileManager.default.createDirectory(
            at: AppData.cloudDir, withIntermediateDirectories: true)
        if (try? Data(contentsOf: cloudFile)) != data {
            try? data.write(to: cloudFile)
            SharedDefaults.store.set(
                Date().timeIntervalSince1970, forKey: AppStorageKeys.Backup.lastBackupAt)
        }
    }

    func syncData() {
        syncLimits()
        syncUsage()
    }

    func syncLimits() {
        transferLimits(
            decision: transferDecision(for: .limits), restore: true, export: true,
            requireApplicationSupportRestore: false)
    }

    private func exportLimits() {
        transferLimits(
            decision: transferDecision(for: .limits), restore: false, export: true,
            requireApplicationSupportRestore: false)
    }

    private func transferLimits(
        decision: SettingsBackupTransferDecision,
        restore: Bool,
        export: Bool,
        requireApplicationSupportRestore: Bool
    ) {
        guard cloudEnabled else { return }
        let shouldRestore =
            restore && decision.shouldRestore
            && (!requireApplicationSupportRestore || isApplicationSupportURL(localLimits))
        let shouldExport = export && decision.shouldExport
        guard shouldRestore || shouldExport else { return }
        let fm = FileManager.default
        let localText = (try? String(contentsOf: localLimits, encoding: .utf8)) ?? ""
        var cloudText = ""
        if fm.fileExists(atPath: cloudLimits.path) {
            if let t = try? String(contentsOf: cloudLimits, encoding: .utf8) {
                cloudText = t
            } else {
                try? fm.startDownloadingUbiquitousItem(at: cloudLimits)
                return
            }
        }
        let merged = LimitsHistory.merge(localText, cloudText)
        guard !merged.isEmpty else { return }
        let data = Data(merged.utf8)
        try? fm.createDirectory(
            at: localLimits.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.createDirectory(
            at: cloudLimits.deletingLastPathComponent(), withIntermediateDirectories: true)
        if shouldRestore, (try? Data(contentsOf: localLimits)) != data {
            try? data.write(to: localLimits)
        }
        if shouldExport, (try? Data(contentsOf: cloudLimits)) != data {
            try? data.write(to: cloudLimits)
        }
    }

    func syncUsage() {
        transferUsage(
            decision: transferDecision(for: .usage), restore: true, export: true,
            requireApplicationSupportRestore: false)
    }

    private func exportUsage() {
        transferUsage(
            decision: transferDecision(for: .usage), restore: false, export: true,
            requireApplicationSupportRestore: false)
    }

    private func transferUsage(
        decision: SettingsBackupTransferDecision,
        restore: Bool,
        export: Bool,
        requireApplicationSupportRestore: Bool
    ) {
        guard cloudEnabled else { return }
        let shouldRestore =
            restore && decision.shouldRestore
            && (!requireApplicationSupportRestore || isApplicationSupportURL(localUsage))
        let shouldExport = export && decision.shouldExport
        guard shouldRestore || shouldExport else { return }
        let fm = FileManager.default
        let localData = try? Data(contentsOf: localUsage)
        var cloudData: Data?
        if fm.fileExists(atPath: cloudUsage.path) {
            cloudData = try? Data(contentsOf: cloudUsage)
            if cloudData == nil {
                try? fm.startDownloadingUbiquitousItem(at: cloudUsage)
                return
            }
        }
        guard let merged = UsageHistory.merge(local: localData, cloud: cloudData) else { return }
        if shouldRestore {
            try? fm.createDirectory(
                at: localUsage.deletingLastPathComponent(), withIntermediateDirectories: true)
            if (try? Data(contentsOf: localUsage)) != merged { try? merged.write(to: localUsage) }
        }
        if shouldExport {
            try? fm.createDirectory(
                at: cloudUsage.deletingLastPathComponent(), withIntermediateDirectories: true)
            if (try? Data(contentsOf: cloudUsage)) != merged { try? merged.write(to: cloudUsage) }
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
        guard let data = try? Data(contentsOf: cloudFile),
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
