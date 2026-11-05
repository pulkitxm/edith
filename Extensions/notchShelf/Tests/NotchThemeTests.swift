import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI
import Testing

@testable import NotchShelfExtension

@MainActor @Suite(.serialized) struct NotchThemeTests {
    private func components(_ color: Color) -> [CGFloat] {
        let resolved = NSColor(color).usingColorSpace(.sRGB) ?? .black
        return [resolved.redComponent, resolved.greenComponent, resolved.blueComponent]
    }

    private func apply(_ theme: AppTheme) async throws {
        ExtensionScope.process.defaults().set(
            theme.rawValue, forKey: AppStorageKeys.General.theme)
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(2)
        while ThemeStore.current != theme, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(ThemeStore.current == theme)
    }

    @Test func profilesWithoutAChromeColorUseTheThemeAndKeepTheirOwnOtherwise() async throws {
        let defaults = ExtensionScope.process.defaults()
        let stored = defaults.string(forKey: AppStorageKeys.General.theme)
        _ = ThemeStore.current
        defer {
            if let stored {
                defaults.set(stored, forKey: AppStorageKeys.General.theme)
            } else {
                defaults.removeObject(forKey: AppStorageKeys.General.theme)
            }
        }
        let plain = ChromeProfile(
            directory: "Default", name: "Ada", email: nil, pictureURL: nil, colorARGB: nil)
        let colored = ChromeProfile(
            directory: "Profile 1", name: "Grace", email: nil, pictureURL: nil,
            colorARGB: 0xFF10_2030)
        for theme in [AppTheme.teal, .pink] {
            try await apply(theme)
            let expected = components(DashSkin.accent(true, theme: theme))
            for (actual, wanted) in zip(
                components(ChromeProfileAvatar.tint(for: plain)), expected)
            {
                #expect(abs(actual - wanted) < 0.02)
            }
            let own = components(ChromeProfileAvatar.tint(for: colored))
            #expect(abs(own[0] - 0x10 / 255.0) < 0.02)
        }
    }
}
