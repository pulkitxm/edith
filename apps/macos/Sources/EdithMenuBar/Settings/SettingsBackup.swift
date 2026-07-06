import AppKit
import EdithKit
import Foundation

extension Notification.Name {
    static let musicFolderChanged = Notification.Name("musicFolderChanged")
}

@MainActor
final class SettingsBackup: ObservableObject {
    static let shared = SettingsBackup()

    @Published private(set) var musicBackupRunning = false

    private static let keys = [
        "theme", "tab", "presenterMode", "presenterBlurMusic", "presenterBlurMoney",
        "tabUsageEnabled", "tabMusicEnabled",
        "hotKeyCode", "hotKeyMods", "hotKeyLabel", "musicVolume", "repoPath",
        "icloudBackup", "musicBackup", "lastPaletteTheme", "appearance",
        "tabSystemEnabled", "preventSleep", "tabOrder",
        "backupSettings", "backupUsage", "backupLimits",
        "limitsInMenuBar", "menuBarColorMode", "smartColor",
        "warnPercent", "critPercent", "pacingMargin",
        "notifyMaster", "notifyTrackSession", "notifyTrackWeekly",
        "notifyRecovery", "notifyPacingWarning", "notifyPacingHot",
        "notifyReminderSession", "notifyReminderSessionOffsetMin",
        "notifyReminderWeekly", "notifyReminderWeeklyOffsetMin",
        "notifyTokenExpired",
        "dashRange", "dashSources", "dashModels", "dashBillingDay", "dashSort", "dashSortAsc",
    ]

    private var debounce: Timer?
    private var localFile: URL { AppData.supportDir.appendingPathComponent("settings.json") }
    private var cloudFile: URL { AppData.cloudDir.appendingPathComponent("settings.json") }

    private var localLimits: URL { LimitsHistory.url }
    private var cloudLimits: URL {
        AppData.cloudDir.appendingPathComponent("data/limits-history.jsonl")
    }
    private var localUsage: URL { Repo.usageJSON }
    private var cloudUsage: URL { AppData.cloudDir.appendingPathComponent("data/usage.json") }

    private func flag(_ key: String) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }
    private var backupOn: Bool {
        UserDefaults.standard.bool(forKey: "icloudBackup") && AppData.cloudAvailable
    }

    func start() {
        importFromCloudIfNewer()
        export()
        syncData()
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.scheduleExport() }
        }
        if UserDefaults.standard.bool(forKey: "musicBackup"), !restoreMusic() {
            backupMusic()
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                SettingsBackup.shared.debounceFlush()
                SettingsBackup.shared.syncLimits()
            }
        }
    }

    func debounceFlush() {
        if debounce?.isValid == true {
            debounce?.invalidate()
            export()
        }
    }

    func backupMusic() {
        guard !musicBackupRunning, AppData.cloudAvailable,
            FileManager.default.fileExists(atPath: Repo.musicDir.path)
        else { return }
        musicBackupRunning = true
        let destination = AppData.cloudDir.appendingPathComponent("music")
        try? FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/rsync")
        p.arguments = ["-a", Repo.musicDir.path + "/", destination.path + "/"]
        p.qualityOfService = .utility
        p.terminationHandler = { process in
            Task { @MainActor in
                self.musicBackupRunning = false
                if process.terminationStatus == 0 {
                    UserDefaults.standard.set(
                        Date().timeIntervalSince1970, forKey: "lastMusicBackupAt")
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
    func restoreMusic() -> Bool {
        guard AppData.cloudAvailable else { return false }
        let source = AppData.cloudDir.appendingPathComponent("music")
        let fm = FileManager.default
        func hasAudio(_ dir: URL) -> Bool {
            let exts: Set<String> = ["mp3", "m4a", "m4b", "aac", "wav", "aiff", "flac"]
            return ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? [])
                .contains { exts.contains(($0 as NSString).pathExtension.lowercased()) }
        }
        guard hasAudio(source), !hasAudio(Repo.musicDir) else { return false }
        try? fm.createDirectory(at: Repo.musicDir, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/rsync")
        p.arguments = ["-a", "--exclude", ".DS_Store", source.path + "/", Repo.musicDir.path + "/"]
        p.qualityOfService = .utility
        p.terminationHandler = { proc in
            if proc.terminationStatus == 0 {
                NotificationCenter.default.post(name: .musicFolderChanged, object: nil)
            }
        }
        do {
            try p.run()
            return true
        } catch {
            return false
        }
    }

    private func scheduleExport() {
        debounce?.invalidate()
        debounce = Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { _ in
            Task { @MainActor in SettingsBackup.shared.export() }
        }
    }

    private func snapshot() -> Data? {
        var dict: [String: Any] = [:]
        for key in Self.keys {
            if let value = UserDefaults.standard.object(forKey: key) { dict[key] = value }
        }
        return try? JSONSerialization.data(
            withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
    }

    func export() {
        guard let data = snapshot() else { return }
        if (try? Data(contentsOf: localFile)) != data {
            try? data.write(to: localFile)
        }
        guard backupOn, flag("backupSettings") else { return }
        try? FileManager.default.createDirectory(
            at: AppData.cloudDir, withIntermediateDirectories: true)
        if (try? Data(contentsOf: cloudFile)) != data {
            try? data.write(to: cloudFile)
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastBackupAt")
        }
    }

    func syncData() {
        syncLimits()
        syncUsage()
    }

    func syncLimits() {
        guard backupOn, flag("backupLimits") else { return }
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
        if (try? Data(contentsOf: localLimits)) != data { try? data.write(to: localLimits) }
        if (try? Data(contentsOf: cloudLimits)) != data { try? data.write(to: cloudLimits) }
    }

    func syncUsage() {
        guard backupOn, flag("backupUsage") else { return }
        let fm = FileManager.default
        try? fm.createDirectory(
            at: cloudUsage.deletingLastPathComponent(), withIntermediateDirectories: true)
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
        try? fm.createDirectory(
            at: localUsage.deletingLastPathComponent(), withIntermediateDirectories: true)
        if (try? Data(contentsOf: localUsage)) != merged { try? merged.write(to: localUsage) }
        if (try? Data(contentsOf: cloudUsage)) != merged { try? merged.write(to: cloudUsage) }
    }

    private func importFromCloudIfNewer() {
        let fm = FileManager.default
        let firstRun = !fm.fileExists(atPath: localFile.path)
        guard firstRun || UserDefaults.standard.bool(forKey: "icloudBackup") else { return }
        guard
            let cloudDate = (try? fm.attributesOfItem(atPath: cloudFile.path))?[.modificationDate]
                as? Date
        else { return }
        let localDate =
            (try? fm.attributesOfItem(atPath: localFile.path))?[.modificationDate] as? Date
            ?? .distantPast
        guard firstRun || cloudDate > localDate.addingTimeInterval(2) else { return }
        guard let data = try? Data(contentsOf: cloudFile),
            let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            try? fm.startDownloadingUbiquitousItem(at: cloudFile)
            return
        }
        for (key, value) in dict where Self.keys.contains(key) {
            UserDefaults.standard.set(value, forKey: key)
        }
        try? data.write(to: localFile)
        HotKey.register()
    }
}
