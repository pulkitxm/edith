import AppKit
import EdithKit
import Foundation

@MainActor
final class ClipboardStore: ObservableObject, FeatureModule {
    @Published private(set) var entries: [ClipboardEntry] = []
    @Published private(set) var skippedOversizeAt: Date?

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
        SharedDefaults.store.object(forKey: "clipboardCheckInterval") as? Double ?? 0.5
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

    private struct Captured {
        let data: Data
        let types: [String]
        let ext: String
        let preview: String?
    }

    private func capture(from pb: NSPasteboard) {
        let rawTypes = (pb.types ?? []).map(\.rawValue)
        guard !ClipboardPasteboardFilter.shouldSkip(types: rawTypes) else { return }
        guard !ClipboardPasteboardFilter.capturableTypes(from: rawTypes).isEmpty else { return }

        let frontApp = NSWorkspace.shared.frontmostApplication
        let bundleID = frontApp?.bundleIdentifier
        let ignoreList = ClipboardIgnore.parseUserList(
            SharedDefaults.store.string(forKey: "clipboardIgnoredApps") ?? "")
        guard !ClipboardIgnore.isIgnored(bundleID: bundleID, userList: ignoreList) else { return }

        guard let captured = Self.extractPayload(pb) else { return }

        let maxBytes =
            SharedDefaults.store.object(forKey: "clipboardMaxItemBytes") as? Int
            ?? 10_000_000
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
            size: captured.data.count, preview: captured.preview,
            pinned: existing?.pinned ?? false)
        entries.append(entry)
        persistAndTrim(appending: existing == nil ? entry : nil)
        SettingsBackup.shared.scheduleClipboardBackup()
    }

    private static func extractPayload(_ pb: NSPasteboard) -> Captured? {
        let defaults = SharedDefaults.store
        let saveFiles = defaults.object(forKey: "clipboardSaveFiles") as? Bool ?? true
        let saveImages = defaults.object(forKey: "clipboardSaveImages") as? Bool ?? true
        let saveText = defaults.object(forKey: "clipboardSaveText") as? Bool ?? true

        if saveFiles, let string = pb.string(forType: .fileURL),
            let data = string.data(using: .utf8)
        {
            let name = (string as NSString).lastPathComponent.removingPercentEncoding ?? string
            return Captured(
                data: data, types: [NSPasteboard.PasteboardType.fileURL.rawValue], ext: "url",
                preview: name)
        }
        if saveImages {
            if let data = pb.data(forType: .png) {
                return Captured(
                    data: data, types: [NSPasteboard.PasteboardType.png.rawValue], ext: "png",
                    preview: "Image")
            }
            if let data = pb.data(forType: .tiff) {
                return Captured(
                    data: data, types: [NSPasteboard.PasteboardType.tiff.rawValue], ext: "tiff",
                    preview: "Image")
            }
        }
        guard saveText else { return nil }
        if let data = pb.data(forType: .rtf) {
            let plain = NSAttributedString(rtf: data, documentAttributes: nil)?.string
            if hasVisibleText(plain) {
                return Captured(
                    data: data, types: [NSPasteboard.PasteboardType.rtf.rawValue], ext: "rtf",
                    preview: plain)
            }
        }
        if let data = pb.data(forType: .html) {
            let plain = NSAttributedString(html: data, documentAttributes: nil)?.string
            if hasVisibleText(plain) {
                return Captured(
                    data: data, types: [NSPasteboard.PasteboardType.html.rawValue], ext: "html",
                    preview: plain)
            }
        }
        if let string = pb.string(forType: .string), hasVisibleText(string) {
            return Captured(
                data: Data(string.utf8), types: [NSPasteboard.PasteboardType.string.rawValue],
                ext: "txt", preview: string)
        }
        return nil
    }

    private static func hasVisibleText(_ text: String?) -> Bool {
        guard let text else { return false }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static let senderID =
        "clipboardStore-\(ProcessInfo.processInfo.processIdentifier)"

    private func postChanged() {
        IPC.post(IPC.Name.clipboardChanged, userInfo: ["sender": Self.senderID])
    }

    private func persistAndTrim(appending appended: ClipboardEntry? = nil) {
        let beforeRetention = entries.count
        let maxItems = SharedDefaults.store.object(forKey: "clipboardMaxItems") as? Int ?? 200
        let maxAgeDays = SharedDefaults.store.object(forKey: "clipboardMaxAgeDays") as? Int ?? 0
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
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].pinned.toggle()
        try? ClipboardRepository.saveEntries(entries)
        SettingsBackup.shared.scheduleClipboardBackup()
        postChanged()
    }

    func clear(includingPinned: Bool = false) {
        entries = includingPinned ? [] : entries.filter(\.pinned)
        try? ClipboardRepository.saveEntries(entries)
        ClipboardRepository.pruneOrphanBlobs(keeping: entries)
        SettingsBackup.shared.scheduleClipboardBackup()
        postChanged()
    }

    func delete(_ id: String) {
        entries.removeAll { $0.id == id }
        try? ClipboardRepository.saveEntries(entries)
        ClipboardRepository.pruneOrphanBlobs(keeping: entries)
        postChanged()
    }

    func activate(_ entry: ClipboardEntry, forcePlainText: Bool = false) {
        let plain = forcePlainText || SharedDefaults.store.bool(forKey: "clipboardPastePlainText")
        guard ClipboardRepository.copyToPasteboard(entry, asPlainText: plain) else { return }
        lastChangeCount = NSPasteboard.general.changeCount

        let autoPaste =
            SharedDefaults.store.bool(forKey: "clipboardAutoPaste")
            && SharedDefaults.store.bool(forKey: "permAccessibilityGranted")
        guard autoPaste else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            ClipboardPasteSynth.synthesizeCommandV()
        }
    }
}
