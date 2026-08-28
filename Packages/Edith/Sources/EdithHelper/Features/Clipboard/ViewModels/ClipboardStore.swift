import AppKit
import EdithKit
import Foundation

@MainActor
@Observable
final class ClipboardStore: FeatureModule {
    private(set) var entries: [ClipboardEntry] = []
    private(set) var revision = 0
    private(set) var skippedOversizeAt: Date?
    private(set) var mutationError: String?

    private var loaded = false
    private var timer: DispatchSourceTimer?
    private var lastChangeCount = NSPasteboard.general.changeCount
    private var observedChangeCount: Int?
    private var changedAt: Date?
    private var locked = false
    private var lockObservers: [NSObjectProtocol] = []
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var settingsObserver: NSObjectProtocol?
    private var clipboardChangedObserver: NSObjectProtocol?
    private let clearOperation: @Sendable (ClipboardClearPlan) throws -> ClipboardActions.Outcome

    private static let diskQueue = DispatchQueue(
        label: "com.edith.clipboard.disk", qos: .userInitiated)

    required convenience init() {
        self.init(clearOperation: { try ClipboardOperationExecution.clear($0) })
    }

    init(
        clearOperation: @escaping @Sendable (ClipboardClearPlan) throws -> ClipboardActions.Outcome
    ) {
        self.clearOperation = clearOperation
        reloadFromDisk(initial: true)

        let dnc = DistributedNotificationCenter.default()
        lockObservers = [
            dnc.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) {
                [weak self] _ in
                Task { @MainActor in
                    self?.locked = true
                    self?.clearPasteboardIfConfigured(AppStorageKeys.TextUtilities.clearOnLock)
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
            Task { @MainActor in
                self?.clearPasteboardIfConfigured(AppStorageKeys.TextUtilities.clearOnSleep)
                self?.stopTimer()
            }
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
                Task { @MainActor in self?.reloadFromDisk() }
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

    private func reloadFromDisk(initial: Bool = false) {
        Self.diskQueue.async { [weak self] in
            let loaded = ClipboardRepository.loadEntries()
            Task { @MainActor in
                guard let self else { return }
                if initial { self.loaded = true }
                self.adopt(loaded)
            }
        }
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
        guard loaded else { return }
        let pb = NSPasteboard.general
        if pb.changeCount != lastChangeCount {
            handleChange(in: pb)
            return
        }
        clearPasteboardAfterDelayIfNeeded(pb)
    }

    private func handleChange(in pasteboard: NSPasteboard) {
        lastChangeCount = pasteboard.changeCount
        let types = (pasteboard.types ?? []).map(\.rawValue)
        let textUtilitiesOn = SharedDefaults.store.bool(
            forKey: AppStorageKeys.TextUtilities.enabled)
        if textUtilitiesOn, !ClipboardPasteboardFilter.shouldSkip(types: types) {
            cleanCopiedURLIfNeeded(pasteboard)
            observedChangeCount = pasteboard.changeCount
            changedAt = Date()
        } else {
            observedChangeCount = nil
            changedAt = nil
        }
        lastChangeCount = pasteboard.changeCount
        guard SharedDefaults.store.bool(forKey: AppStorageKeys.Clipboard.enabled) else { return }
        capture(from: pasteboard)
    }

    private func cleanCopiedURLIfNeeded(_ pasteboard: NSPasteboard) {
        guard SharedDefaults.store.bool(forKey: AppStorageKeys.TextUtilities.cleanCopiedURLs),
            let text = pasteboard.string(forType: .string),
            let cleaned = TextUtilitiesSupport.cleanURL(
                text,
                customParameters: TextUtilitiesSupport.customParameters(
                    SharedDefaults.store.string(
                        forKey: AppStorageKeys.TextUtilities.customTrackingParameters) ?? "")),
            cleaned.value != text.trimmingCharacters(in: .whitespacesAndNewlines),
            TextUtilitiesSupport.canRewritePasteboard(
                types: (pasteboard.types ?? []).map(\.rawValue))
        else { return }
        pasteboard.clearContents()
        pasteboard.setString(cleaned.value, forType: .string)
        pasteboard.setString(cleaned.value, forType: .init("public.url"))
    }

    private func clearPasteboardAfterDelayIfNeeded(_ pasteboard: NSPasteboard) {
        guard SharedDefaults.store.bool(forKey: AppStorageKeys.TextUtilities.enabled),
            SharedDefaults.store.bool(forKey: AppStorageKeys.TextUtilities.autoClearEnabled)
        else { return }
        let delay = TextUtilitiesSupport.clampedAutoClearDelay(
            SharedDefaults.store.integer(forKey: AppStorageKeys.TextUtilities.autoClearDelay))
        guard
            TextUtilitiesSupport.shouldAutoClear(
                observedChangeCount: observedChangeCount,
                currentChangeCount: pasteboard.changeCount,
                changedAt: changedAt, now: Date(), delay: TimeInterval(delay))
        else { return }
        clearPasteboard(pasteboard)
    }

    private func clearPasteboardIfConfigured(_ key: String) {
        guard SharedDefaults.store.bool(forKey: AppStorageKeys.TextUtilities.enabled),
            SharedDefaults.store.bool(forKey: key)
        else { return }
        clearPasteboard(.general)
    }

    private func clearPasteboard(_ pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        lastChangeCount = pasteboard.changeCount
        observedChangeCount = nil
        changedAt = nil
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

        let sourceApp = frontApp?.localizedName
        Self.diskQueue.async { [weak self] in
            let sha = ClipboardRepository.sha256Hex(captured.data)
            try? ClipboardRepository.writeBlob(captured.data, sha256: sha, ext: captured.ext)
            Task { @MainActor in
                self?.absorb(
                    captured, sha: sha, sourceApp: sourceApp, sourceBundleID: bundleID)
            }
        }
    }

    private func absorb(
        _ captured: ClipboardPayload, sha: String, sourceApp: String?, sourceBundleID: String?
    ) {
        let existing = entries.first { $0.sha256 == sha && $0.ext == captured.ext }
        if let existing {
            entries.removeAll { $0.id == existing.id }
        }
        let entry = ClipboardEntry(
            id: existing?.id ?? UUID().uuidString,
            sha256: sha, types: captured.types, ext: captured.ext,
            sourceApp: sourceApp, sourceBundleID: sourceBundleID,
            lastCopiedAt: Date(),
            size: captured.data.count, preview: captured.preview,
            pinned: existing?.pinned ?? false)
        adopt(ClipboardActions.arrange(entries + [entry]))
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
        revision += 1
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
        revision += 1
        let removedAny = entries.count != beforeRetention
        let snapshot = entries
        Self.diskQueue.async {
            ClipboardRepository.withIndexLock {
                let appendedFastPath =
                    appended != nil && !removedAny
                    && ClipboardRepository.appendEntry(appended!)
                if !appendedFastPath {
                    try? ClipboardRepository.saveEntries(snapshot)
                }
            }
            if removedAny {
                ClipboardRepository.pruneOrphanBlobs(keeping: snapshot)
            }
        }
        postChanged()
    }

    func togglePin(_ id: String) {
        guard let entry = entries.first(where: { $0.id == id }) else { return }
        mutateOnDisk {
            try ClipboardOperationExecution.perform(entry.pinned ? .unpin : .pin, entry: entry)
        }
    }

    func clear(_ plan: ClipboardClearPlan) {
        let clearOperation = clearOperation
        mutateOnDisk(requireChange: false) { try clearOperation(plan) }
    }

    func dismissMutationError() {
        mutationError = nil
    }

    func delete(_ id: String) {
        guard let entry = entries.first(where: { $0.id == id }) else { return }
        mutateOnDisk(scheduleBackup: false) {
            try ClipboardOperationExecution.perform(.remove, entry: entry)
        }
    }

    private func mutateOnDisk(
        requireChange: Bool = true, scheduleBackup: Bool = true,
        _ action: @escaping @Sendable () throws -> ClipboardActions.Outcome
    ) {
        Self.diskQueue.async { [weak self] in
            let outcome: ClipboardActions.Outcome
            do {
                outcome = try action()
            } catch {
                let message = error.localizedDescription
                Task { @MainActor in self?.mutationError = message }
                return
            }
            guard outcome.changed > 0 || !requireChange else { return }
            Task { @MainActor in
                guard let self else { return }
                self.mutationError = nil
                self.adopt(outcome.entries)
                if scheduleBackup { SettingsBackup.shared.scheduleClipboardBackup() }
                self.postChanged()
            }
        }
    }

    func activate(_ entry: ClipboardEntry, forcePlainText: Bool = false) {
        let plain =
            forcePlainText
            || SharedDefaults.store.bool(forKey: AppStorageKeys.Clipboard.pastePlainText)
        let copiedAt = Date()
        guard
            let outcome = try? ClipboardOperationExecution.perform(
                .copy, entry: entry, asPlainText: plain,
                recordCopy: {
                    ClipboardActions.markingCopied(id: $0, in: entries, at: copiedAt)
                }),
            outcome.changed > 0
        else { return }
        lastChangeCount = NSPasteboard.general.changeCount
        adopt(outcome.entries)
        let id = entry.id
        Self.diskQueue.async { _ = try? ClipboardActions.markCopied(id: id, at: copiedAt) }
        SettingsBackup.shared.scheduleClipboardBackup()
        postChanged()

        let autoPaste =
            SharedDefaults.store.bool(forKey: AppStorageKeys.Clipboard.autoPaste)
            && SharedDefaults.store.bool(forKey: AppStorageKeys.Permissions.accessibilityGranted)
        guard autoPaste else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            ClipboardPasteSynth.synthesizeCommandV()
        }
    }
}
