import Carbon.HIToolbox
import EdithKit
import Testing
@testable import EdithHelper

@Suite(.serialized) struct HotKeyDefaultsTests {
    private func withCleanKeys(_ prefix: String, _ body: () -> Void) {
        let keys = ["Code", "Mods", "Label"].map { prefix + $0 }
        let saved = keys.map { ($0, SharedDefaults.store.object(forKey: $0)) }
        defer {
            for (key, value) in saved {
                if let value {
                    SharedDefaults.store.set(value, forKey: key)
                } else {
                    SharedDefaults.store.removeObject(forKey: key)
                }
            }
        }
        keys.forEach { SharedDefaults.store.removeObject(forKey: $0) }
        body()
    }

    @Test func panelHotKeyDefaults() {
        withCleanKeys("hotKey") {
            #expect(HotKey.code == kVK_ANSI_E)
            #expect(HotKey.mods == cmdKey | optionKey)
            #expect(HotKey.label == "⌥⌘E")
        }
    }

    @Test func clipboardHotKeyDefaults() {
        withCleanKeys("clipboardHotKey") {
            #expect(ClipboardHotKey.code == kVK_ANSI_C)
            #expect(ClipboardHotKey.mods == controlKey | shiftKey)
            #expect(ClipboardHotKey.label == "⌃⇧C")
        }
    }

    @Test func focusDimHotKeyDefaults() {
        withCleanKeys("focusDimHotKey") {
            #expect(FocusDimHotKey.code == kVK_ANSI_F)
            #expect(FocusDimHotKey.mods == cmdKey | optionKey)
            #expect(FocusDimHotKey.label == "⌥⌘F")
        }
    }

    @Test func presenterHotKeyDefaults() {
        withCleanKeys("presenterHotKey") {
            #expect(PresenterHotKey.code == kVK_ANSI_P)
            #expect(PresenterHotKey.mods == cmdKey | optionKey | shiftKey)
            #expect(PresenterHotKey.label == "⇧⌥⌘P")
        }
    }

    @Test func panelHotKeySaveRoundTrips() {
        withCleanKeys("hotKey") {
            HotKey.save(code: kVK_ANSI_J, mods: cmdKey | shiftKey, label: "⇧⌘J")
            #expect(HotKey.code == kVK_ANSI_J)
            #expect(HotKey.mods == cmdKey | shiftKey)
            #expect(HotKey.label == "⇧⌘J")
        }
    }

    @Test func clipboardHotKeySaveRoundTrips() {
        withCleanKeys("clipboardHotKey") {
            ClipboardHotKey.save(code: kVK_ANSI_V, mods: controlKey | optionKey, label: "⌃⌥V")
            #expect(ClipboardHotKey.code == kVK_ANSI_V)
            #expect(ClipboardHotKey.mods == controlKey | optionKey)
            #expect(ClipboardHotKey.label == "⌃⌥V")
        }
    }
}
