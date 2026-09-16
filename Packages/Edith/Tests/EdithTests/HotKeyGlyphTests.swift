import Carbon.HIToolbox
import Foundation
import Testing

@testable import EdithKit

@Suite struct HotKeyGlyphTests {
    @Test func spaceGetsAGlyphRatherThanAnInvisibleCharacter() {
        #expect(HotKeyGlyph.key(forKeyCode: kVK_Space, characters: " ") == "\u{2423}")
        #expect(
            HotKeyGlyph.label(modifiers: "\u{2318}", keyCode: kVK_Space, characters: " ")
                == "\u{2318}\u{2423}")
    }

    @Test func everyNamedKeyRendersSomethingVisible() {
        for (code, glyph) in HotKeyGlyph.namedKeys {
            #expect(!glyph.trimmingCharacters(in: .whitespaces).isEmpty)
            #expect(HotKeyGlyph.key(forKeyCode: code, characters: nil) == glyph)
        }
    }

    @Test func functionKeysKeepTheirNames() {
        #expect(HotKeyGlyph.key(forKeyCode: kVK_F5, characters: "\u{F708}") == "F5")
        #expect(HotKeyGlyph.key(forKeyCode: kVK_F12, characters: nil) == "F12")
    }

    @Test func ordinaryKeysAreUppercased() {
        #expect(HotKeyGlyph.key(forKeyCode: kVK_ANSI_E, characters: "e") == "E")
        #expect(HotKeyGlyph.key(forKeyCode: kVK_ANSI_Slash, characters: "/") == "/")
    }

    @Test func aKeyWithNothingPrintableFallsBackToItsCode() {
        #expect(HotKeyGlyph.key(forKeyCode: 200, characters: nil) == "#200")
        #expect(HotKeyGlyph.key(forKeyCode: 201, characters: "  ") == "#201")
        #expect(HotKeyGlyph.key(forKeyCode: 202, characters: "\u{F729}") == "#202")
    }

    @Test func everyCatalogDefaultLabelIsVisible() {
        for binding in HotKeyCatalog.bindings {
            let label = binding.defaultLabel
            #expect(label.trimmingCharacters(in: .whitespaces).count == label.count)
            #expect(!label.isEmpty)
        }
    }
}
