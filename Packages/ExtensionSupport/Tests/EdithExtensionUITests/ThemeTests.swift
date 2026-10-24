import AppKit
import EdithExtensionSupport
import SwiftUI
import Testing

@testable import EdithExtensionUI

@Suite(.serialized) struct ThemeTests {
    @Test func brandThemeUsesTheBrandAccentInEachScheme() {
        #expect(rgb(themeColor("accent"), dark: false) == [217, 119, 87])
        #expect(rgb(themeColor("accent"), dark: true) == [224, 138, 106])
    }

    @Test func themeNamesResolveToTheSameAccentAsThePalette() {
        for theme in AppTheme.allCases {
            for dark in [false, true] {
                #expect(
                    rgb(themeColor(theme.rawValue), dark: dark)
                        == rgb(DashSkin.accent(dark, theme: theme)))
            }
        }
    }

    @Test func unknownNameFallsBackToBrandAccent() {
        #expect(rgb(themeColor("chartreuse"), dark: true) == [224, 138, 106])
        #expect(rgb(themeColor(""), dark: false) == [217, 119, 87])
    }

    @Test func paletteNamesAreUnique() {
        let names = themePalette.map(\.name)
        #expect(Set(names).count == names.count)
    }

    @Test func everyStoredThemeResolvesToItself() {
        for theme in AppTheme.allCases {
            #expect(AppTheme(storedName: theme.rawValue) == theme)
        }
    }

    @Test func invalidStoredThemeResolvesToTheBrandTheme() {
        #expect(AppTheme(storedName: "chartreuse") == .accent)
    }

    @MainActor @Test func themeStoreFollowsTheStoredTheme() async throws {
        let suite = "theme-store-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("teal", forKey: AppStorageKeys.General.theme)
        let store = ThemeStore(defaults: defaults)
        #expect(store.theme == .teal)

        defaults.set("pink", forKey: AppStorageKeys.General.theme)
        for _ in 0..<50 where store.theme != .pink {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(store.theme == .pink)
    }

    @Test func paletteSurfacesAdaptToTheAppearance() {
        #expect(rgb(DashSkin.panel, dark: true) == rgb(DashSkin.paper2(true)))
        #expect(rgb(DashSkin.panel, dark: false) == rgb(DashSkin.paper2(false)))
        #expect(rgb(DashSkin.canvas, dark: true) == rgb(DashSkin.paper(true)))
        #expect(rgb(DashSkin.hairline, dark: false) == rgb(DashSkin.line(false)))
    }

    @Test func appSurfacesStayConstantWhileAccentsChange() {
        #expect(rgb(DashSkin.paper(true)) == [24, 24, 26])
        #expect(rgb(DashSkin.paper2(true)) == [36, 36, 38])
        #expect(DashSkin.accent(true, theme: .blue) != DashSkin.accent(true, theme: .orange))
    }

    @Test func heatmapLevelsGetLighterAsActivityRises() {
        for dark in [false, true] {
            let levels = (0...3).map { luminance(DashSkin.heat($0, dark)) }
            #expect(levels == levels.sorted(), "dark=\(dark) \(levels)")
            #expect(Set(levels).count == levels.count, "dark=\(dark) \(levels)")
        }
    }

    private func rgb(_ color: Color, dark: Bool) -> [Int] {
        var channels: [Int] = []
        NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            channels = rgb(color)
        }
        return channels
    }

    private func luminance(_ color: Color) -> Double {
        let channels = rgb(color).map(Double.init)
        return 0.2126 * channels[0] + 0.7152 * channels[1] + 0.0722 * channels[2]
    }

    private func rgb(_ color: Color) -> [Int] {
        let resolved = NSColor(color).usingColorSpace(.sRGB) ?? .black
        return [resolved.redComponent, resolved.greenComponent, resolved.blueComponent].map {
            Int(($0 * 255).rounded())
        }
    }
}
