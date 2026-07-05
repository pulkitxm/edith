import AppKit
import Foundation

enum AppData {
    static let supportDir: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[
            0
        ]
        .appendingPathComponent("Edith")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static let cloudDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/Edith")

    static var cloudAvailable: Bool {
        FileManager.default.fileExists(
            atPath: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs").path)
    }
}

@MainActor
final class SettingsBackup: ObservableObject {
    static let shared = SettingsBackup()

    @Published private(set) var musicBackupRunning = false

    private static let keys = [
        "theme", "tab", "presenterMode", "tabUsageEnabled", "tabMusicEnabled",
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
        if UserDefaults.standard.bool(forKey: "musicBackup") {
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
        guard let localData = try? Data(contentsOf: localUsage) else {
            if fm.fileExists(atPath: cloudUsage.path) {
                if let cloud = try? Data(contentsOf: cloudUsage) {
                    try? fm.createDirectory(
                        at: localUsage.deletingLastPathComponent(),
                        withIntermediateDirectories: true)
                    try? cloud.write(to: localUsage)
                } else {
                    try? fm.startDownloadingUbiquitousItem(at: cloudUsage)
                }
            }
            return
        }
        if (try? Data(contentsOf: cloudUsage)) != localData { try? localData.write(to: cloudUsage) }
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
