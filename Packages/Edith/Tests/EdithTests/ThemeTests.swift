import EdithKit
import SwiftUI
import Testing

@Suite struct ThemeTests {
    @Test func accentNameReturnsBrandAccent() {
        #expect(themeColor("accent") == brandAccent)
    }

    @Test func paletteNamesResolveToTheirColors() {
        for entry in themePalette {
            #expect(themeColor(entry.name) == entry.color)
        }
    }

    @Test func unknownNameFallsBackToBrandAccent() {
        #expect(themeColor("chartreuse") == brandAccent)
        #expect(themeColor("") == brandAccent)
    }

    @Test func paletteNamesAreUnique() {
        let names = themePalette.map(\.name)
        #expect(Set(names).count == names.count)
    }

    @Test func everyStoredThemeResolvesToItsOwnAccent() {
        for theme in AppTheme.allCases {
            #expect(AppTheme(storedName: theme.rawValue) == theme)
            #expect(themeColor(theme.rawValue) == theme.color)
        }
    }

    @Test func invalidStoredThemeResolvesToTheBrandTheme() {
        #expect(AppTheme(storedName: "chartreuse") == .accent)
    }
}
