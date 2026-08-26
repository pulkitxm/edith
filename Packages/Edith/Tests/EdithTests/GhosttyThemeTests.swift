import AppKit
import Testing

@testable import GhosttyTerminal

@Suite struct GhosttyThemeTests {
    @Test func coloursBecomeHexTheConfigUnderstands() {
        let theme = GhosttyTheme(
            background: NSColor(srgbRed: 0x17 / 255, green: 0x14 / 255, blue: 0x12 / 255, alpha: 1),
            foreground: NSColor(srgbRed: 0xeb / 255, green: 0xe6 / 255, blue: 0xdb / 255, alpha: 1),
            cursor: NSColor(srgbRed: 0xd7 / 255, green: 0xa6 / 255, blue: 0x5c / 255, alpha: 1))
        #expect(theme.background == "#171412")
        #expect(theme.foreground == "#ebe6db")
        #expect(theme.cursor == "#d7a65c")
    }

    @Test func theConfigCarriesEveryColourItWasGiven() {
        let theme = GhosttyTheme(
            background: "#101010", foreground: "#f0f0f0", cursor: "#ff8800",
            selectionBackground: "#333333", selectionForeground: "#ffffff",
            fontSize: 13.4)
        let text = theme.configuration
        #expect(text.contains("background = #101010"))
        #expect(text.contains("foreground = #f0f0f0"))
        #expect(text.contains("cursor-color = #ff8800"))
        #expect(text.contains("selection-background = #333333"))
        #expect(text.contains("selection-foreground = #ffffff"))
        #expect(text.contains("font-size = 13"))
        #expect(text.contains("copy-on-select = clipboard"))
    }

    @Test func anUnsetSelectionIsLeftOutEntirely() {
        let theme = GhosttyTheme(background: "#000000", foreground: "#ffffff", cursor: "#ffffff")
        let text = theme.configuration
        #expect(!text.contains("selection-background"))
        #expect(!text.contains("font-size"))
        #expect(!text.contains("font-family"))
    }

    @Test func twoThemesThatDifferAreNotEqual() {
        let one = GhosttyTheme(background: "#000000", foreground: "#ffffff", cursor: "#ffffff")
        var two = one
        #expect(one == two)
        two.background = "#111111"
        #expect(one != two)
    }
}
