import AppKit
import Testing

@testable import GhosttyTerminal

@Suite struct GhosttyThemeTests {
    @Test func launchQuotesEveryShellArgument() {
        let launch = GhosttyLaunch(
            executable: "/usr/bin/ssh",
            arguments: ["win-lan", #"C:\Users\kpulk\Desktop\mono-volt"#, "it's ready"],
            environment: [])

        #expect(
            launch.command
                == #"'/usr/bin/ssh' 'win-lan' 'C:\Users\kpulk\Desktop\mono-volt' 'it'\''s ready'"#)
    }

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
            palette: ["#000000", "#ff0000", "#00ff00"],
            fontSize: 13.4)
        let text = theme.configuration
        #expect(text.contains("background = #101010"))
        #expect(text.contains("foreground = #f0f0f0"))
        #expect(text.contains("cursor-color = #ff8800"))
        #expect(text.contains("selection-background = #333333"))
        #expect(text.contains("selection-foreground = #ffffff"))
        #expect(text.contains("palette = 0=#000000"))
        #expect(text.contains("palette = 1=#ff0000"))
        #expect(text.contains("palette = 2=#00ff00"))
        #expect(text.contains("font-size = 13"))
        #expect(text.contains("copy-on-select = clipboard"))
        #expect(text.contains("mouse-shift-capture = false"))
        #expect(text.contains("font-codepoint-map = U+E000-U+F8FF=Symbols Nerd Font Mono"))
        #expect(text.contains("font-codepoint-map = U+F0000-U+FFFFD=Symbols Nerd Font Mono"))
        #expect(text.contains("font-codepoint-map = U+100000-U+10FFFD=Symbols Nerd Font Mono"))
        #expect(text.contains(#"keybind = shift+enter=text:\x1b\r"#))
    }

    @Test func bundledSymbolsAreAvailableToTerminalRenderers() {
        TerminalFontRegistry.register()
        let font = TerminalFontRegistry.monospacedFont(ofSize: 12.5)
        let cascade = font.fontDescriptor.object(forKey: .cascadeList) as? [NSFontDescriptor]
        #expect(
            cascade?.contains {
                $0.object(forKey: .family) as? String == TerminalFontRegistry.family
            } == true)
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
