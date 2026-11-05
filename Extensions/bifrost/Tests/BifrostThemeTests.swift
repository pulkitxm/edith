import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI
import Testing

@testable import BifrostExtension

@MainActor @Suite(.serialized) struct BifrostThemeTests {
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

    @Test func selectedRowsFollowTheThemeInsteadOfStayingWhite() async throws {
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
        for theme in [AppTheme.teal, .pink, .accent] {
            try await apply(theme)
            let expected = components(DashSkin.accent(true, theme: theme))
            for (actual, wanted) in zip(components(BifrostPanelMetrics.selection), expected) {
                #expect(abs(actual - wanted) < 0.02)
            }
        }
    }
}
