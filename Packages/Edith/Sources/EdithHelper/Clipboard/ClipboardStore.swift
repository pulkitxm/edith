import AppKit
import EdithKit
import Foundation

@MainActor
@Observable
final class ClipboardStore: FeatureModule {
    private(set) var entries: [ClipboardEntry] = []
    private(set) var skippedOversizeAt: Date?

    private var timer: DispatchSourceTimer?
    private var lastChangeCount = NSPasteboard.general.changeCount
    private var locked = false
    private var lockObservers: [NSObjectProtocol] = []
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var settingsObserver: NSObjectProtocol?
    private var clipboardChangedObserver: NSObjectProtocol?

    init() {
        entries = ClipboardRepository.loadEntries()

        let dnc = DistributedNotificationCenter.default()
        lockObservers = [
            dnc.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) {
                [weak self] _ in
                Task { @MainActor in
                    self?.locked = true
                    self?.stopTimer()
                }
            },
            dnc.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main)
            { [weak self] _ in
                Task { @MainActor in
                    self?.locked = false
                    self?.startTimer()
                }
            },
        ]
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.stopTimer() }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.locked else { return }
                self.startTimer()
            }
        }
        settingsObserver = IPC.observe(IPC.Name.settingsChanged) { [weak self] in
            Task { @MainActor in self?.restartTimerIfIntervalChanged() }
        }
        clipboardChangedObserver = IPC.observe(
            IPC.Name.clipboardChanged,
            info: { [weak self] info in
                guard info["sender"] as? String != Self.senderID else { return }
                Task { @MainActor in self?.entries = ClipboardRepository.loadEntries() }
            })

        startTimer()
    }

    func shutdown() {
        stopTimer()
        for token in lockObservers { DistributedNotificationCenter.default().removeObserver(token) }
        lockObservers = []
        if let sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver) }
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        if let settingsObserver { IPC.stopObserving(settingsObserver) }
        if let clipboardChangedObserver { IPC.stopObserving(clipboardChangedObserver) }
        sleepObserver = nil
        wakeObserver = nil
        settingsObserver = nil
        clipboardChangedObserver = nil
    }

    private var interval: Double {
        SharedDefaults.store.object(forKey: AppStorageKeys.Clipboard.checkInterval) as? Double
            ?? ClipboardIndex.defaultCheckInterval
    }

    private func startTimer() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(200))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    private func stopTimer() {
        timer?.cancel()
        timer = nil
    }

    private func restartTimerIfIntervalChanged() {
        guard timer != nil else { return }
        stopTimer()
        startTimer()
    }

    private func tick() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChangeCount else { return }
        lastChangeCount = pb.changeCount
        capture(from: pb)
    }

    private func capture(from pb: NSPasteboard) {
        let rawTypes = (pb.types ?? []).map(\.rawValue)
        guard !ClipboardPasteboardFilter.shouldSkip(types: rawTypes) else { return }

        let frontApp = NSWorkspace.shared.frontmostApplication
        let bundleID = frontApp?.bundleIdentifier
        let ignoreList = ClipboardIgnore.parseUserList(
            SharedDefaults.store.string(forKey: AppStorageKeys.Clipboard.ignoredApps) ?? "")
        guard !ClipboardIgnore.isIgnored(bundleID: bundleID, userList: ignoreList) else { return }

        let defaults = SharedDefaults.store
        let options = ClipboardCaptureOptions(
            saveFiles: defaults.object(forKey: AppStorageKeys.Clipboard.saveFiles) as? Bool ?? true,
            saveImages: defaults.object(forKey: AppStorageKeys.Clipboard.saveImages) as? Bool
                ?? true,
            saveText: defaults.object(forKey: AppStorageKeys.Clipboard.saveText) as? Bool ?? true)
        guard let captured = ClipboardPayloadExtractor.extract(from: pb, options: options) else {
            return
        }

        let maxBytes =
            SharedDefaults.store.object(forKey: AppStorageKeys.Clipboard.maxItemBytes) as? Int
            ?? ClipboardIndex.defaultMaxItemBytes
        guard captured.data.count <= maxBytes else {
            skippedOversizeAt = Date()
            return
        }

        let sha = ClipboardRepository.sha256Hex(captured.data)
        try? ClipboardRepository.writeBlob(captured.data, sha256: sha, ext: captured.ext)

        let existing = entries.first { $0.sha256 == sha && $0.ext == captured.ext }
        if let existing {
            entries.removeAll { $0.id == existing.id }
        }
        let entry = ClipboardEntry(
            id: existing?.id ?? UUID().uuidString,
            sha256: sha, types: captured.types, ext: captured.ext,
            sourceApp: frontApp?.localizedName, sourceBundleID: bundleID,
            lastCopiedAt: Date(),
            size: captured.data.count, preview: captured.preview,
            pinned: existing?.pinned ?? false)
        entries = ClipboardActions.arrange(entries + [entry])
        persistAndTrim(appending: existing == nil ? entry : nil)
        SettingsBackup.shared.scheduleClipboardBackup()
    }

    private static let senderID =
        "clipboardStore-\(ProcessInfo.processInfo.processIdentifier)"

    private func postChanged() {
        IPC.post(IPC.Name.clipboardChanged, userInfo: ["sender": Self.senderID])
    }

    private func adopt(_ updated: [ClipboardEntry]) {
        entries = ClipboardActions.arrange(updated)
    }

    private func persistAndTrim(appending appended: ClipboardEntry? = nil) {
        let beforeRetention = entries.count
        let maxItems =
            SharedDefaults.store.object(forKey: AppStorageKeys.Clipboard.maxItems) as? Int
            ?? ClipboardIndex.defaultMaxItems
        let maxAgeDays =
            SharedDefaults.store.object(forKey: AppStorageKeys.Clipboard.maxAgeDays) as? Int ?? 0
        let maxAge: TimeInterval? = maxAgeDays > 0 ? Double(maxAgeDays) * 86400 : nil
        entries = ClipboardIndex.applyRetention(entries, maxItems: maxItems, maxAge: maxAge)
        let removedAny = entries.count != beforeRetention
        let appendedFastPath =
            appended != nil && !removedAny && ClipboardRepository.appendEntry(appended!)
        if !appendedFastPath {
            try? ClipboardRepository.saveEntries(entries)
        }
        if removedAny {
            ClipboardRepository.pruneOrphanBlobs(keeping: entries)
        }
        postChanged()
    }

    func togglePin(_ id: String) {
        guard let outcome = try? ClipboardActions.togglePin(ids: [id]), outcome.changed > 0 else {
            return
        }
        adopt(outcome.entries)
        SettingsBackup.shared.scheduleClipboardBackup()
        postChanged()
    }

    func clear(includingPinned: Bool = false) {
        guard let outcome = try? ClipboardActions.clear(keepingPinned: !includingPinned) else {
            return
        }
        adopt(outcome.entries)
        SettingsBackup.shared.scheduleClipboardBackup()
        postChanged()
    }

    func delete(_ id: String) {
        guard let outcome = try? ClipboardActions.delete(ids: [id]), outcome.changed > 0 else {
            return
        }
        adopt(outcome.entries)
        postChanged()
    }

    func activate(_ entry: ClipboardEntry, forcePlainText: Bool = false) {
        let plain =
            forcePlainText
            || SharedDefaults.store.bool(forKey: AppStorageKeys.Clipboard.pastePlainText)
        guard let outcome = try? ClipboardActions.copy(entry, asPlainText: plain) else { return }
        lastChangeCount = NSPasteboard.general.changeCount
        if outcome.changed > 0 {
            adopt(outcome.entries)
            SettingsBackup.shared.scheduleClipboardBackup()
            postChanged()
        }

        let autoPaste =
            SharedDefaults.store.bool(forKey: AppStorageKeys.Clipboard.autoPaste)
            && SharedDefaults.store.bool(forKey: AppStorageKeys.Permissions.accessibilityGranted)
        guard autoPaste else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            ClipboardPasteSynth.synthesizeCommandV()
        }
    }
}
