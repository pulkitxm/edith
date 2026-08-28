import AppKit
import EdithKit
import Foundation

@MainActor
final class TextUtilitiesEngine: FeatureModule {
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
        TextUtilitiesHotKey.register()
    }

    func shutdown() {
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
