import AppKit
import EdithKit
import Foundation

@MainActor
final class TextUtilitiesEngine: FeatureModule {
    private let clipboardPrivacy = TextClipboardPrivacy()
    private var keyboardMonitor: Any?
    private var snippets: [TextSnippet] = []
    private var buffer = ""
    private var expanding = false

    required init() {
        syncSettings()
    }

    func syncSettings() {
        snippets = TextUtilitiesSupport.decode(
            SharedDefaults.store.string(forKey: AppStorageKeys.TextUtilities.snippets))
        let enabled = SharedDefaults.store.bool(
            forKey: AppStorageKeys.TextUtilities.snippetsEnabled)
        if enabled, keyboardMonitor == nil {
            keyboardMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) {
                [weak self] event in
                Task { @MainActor in self?.handle(event) }
            }
        }
        if !enabled, let keyboardMonitor {
            NSEvent.removeMonitor(keyboardMonitor)
            self.keyboardMonitor = nil
            buffer = ""
        }
        clipboardPrivacy.syncSettings()
        TextUtilitiesHotKey.register()
    }

    func shutdown() {
        clipboardPrivacy.shutdown()
        if let keyboardMonitor { NSEvent.removeMonitor(keyboardMonitor) }
        keyboardMonitor = nil
        snippets = []
        buffer = ""
        expanding = false
        TextUtilitiesHotKey.unregister()
    }

    func pastePlainText() -> PlainTextPasteState {
        guard let text = NSPasteboard.general.string(forType: .string) else {
            return .clipboardEmpty
        }
        ClipboardPasteSynth.pasteTemporarily(text)
        return .pasted
    }

    private func handle(_ event: NSEvent) {
        guard !expanding else { return }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers.intersection([.command, .control, .option]).isEmpty else {
            buffer = ""
            return
        }
        if event.keyCode == 51 {
            if !buffer.isEmpty { buffer.removeLast() }
            return
        }
        guard let characters = event.characters, !characters.isEmpty else {
            buffer = ""
            return
        }
        for character in characters.map(String.init) {
            buffer = TextUtilitiesSupport.appending(buffer, character: character)
            let expansion: TextSnippetExpansion =
                TextUtilitiesSupport.isDelimiter(character) ? .afterDelimiter : .immediate
            guard
                let snippet = TextUtilitiesSupport.match(
                    buffer: buffer, expansion: expansion, snippets: snippets)
            else { continue }
            expand(snippet, delimiter: expansion == .afterDelimiter ? character : "")
            break
        }
    }

    private func expand(_ snippet: TextSnippet, delimiter: String) {
        expanding = true
        buffer = ""
        let clipboard = NSPasteboard.general.string(forType: .string)
        let replacement =
            TextUtilitiesSupport.expand(
                snippet.replacement, clipboard: clipboard) + delimiter
        let deletedCharacters = snippet.trigger.count + delimiter.count
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
            ClipboardPasteSynth.synthesizeDeletes(deletedCharacters)
            ClipboardPasteSynth.pasteTemporarily(replacement)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.expanding = false
        }
    }
}

@MainActor
private final class TextClipboardPrivacy {
    private var timer: Timer?
    private var lockObserver: NSObjectProtocol?
    private var unlockObserver: NSObjectProtocol?
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var paused = false
    private var lastChangeCount = NSPasteboard.general.changeCount
    private var observedChangeCount: Int?
    private var changedAt: Date?

    init() {
        let distributed = DistributedNotificationCenter.default()
        lockObserver = distributed.addObserver(
            forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.clearPasteboardIfConfigured(AppStorageKeys.TextUtilities.clearOnLock)
                self?.pause()
            }
        }
        unlockObserver = distributed.addObserver(
            forName: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.resume() }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        sleepObserver = workspace.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.clearPasteboardIfConfigured(AppStorageKeys.TextUtilities.clearOnSleep)
                self?.pause()
            }
        }
        wakeObserver = workspace.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.resume() }
        }
    }

    func syncSettings() {
        let defaults = SharedDefaults.store
        let wantsPolling =
            !paused
            && (defaults.bool(forKey: AppStorageKeys.TextUtilities.cleanCopiedURLs)
                || defaults.bool(forKey: AppStorageKeys.TextUtilities.autoClearEnabled))
        if wantsPolling, timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.poll() }
            }
            timer?.tolerance = 0.1
        } else if !wantsPolling {
            timer?.invalidate()
            timer = nil
        }
    }

    func shutdown() {
        timer?.invalidate()
        timer = nil
        let distributed = DistributedNotificationCenter.default()
        if let lockObserver { distributed.removeObserver(lockObserver) }
        if let unlockObserver { distributed.removeObserver(unlockObserver) }
        let workspace = NSWorkspace.shared.notificationCenter
        if let sleepObserver { workspace.removeObserver(sleepObserver) }
        if let wakeObserver { workspace.removeObserver(wakeObserver) }
        lockObserver = nil
        unlockObserver = nil
        sleepObserver = nil
        wakeObserver = nil
    }

    private func pause() {
        paused = true
        syncSettings()
    }

    private func resume() {
        paused = false
        syncSettings()
    }

    private func poll() {
        let pasteboard = NSPasteboard.general
        if pasteboard.changeCount != lastChangeCount {
            let types = (pasteboard.types ?? []).map(\.rawValue)
            if !ClipboardPasteboardFilter.shouldSkip(types: types) {
                cleanCopiedURLIfNeeded(pasteboard)
                observedChangeCount = pasteboard.changeCount
                changedAt = Date()
            } else {
                observedChangeCount = nil
                changedAt = nil
            }
            lastChangeCount = pasteboard.changeCount
        }
        clearPasteboardAfterDelayIfNeeded(pasteboard)
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

}
