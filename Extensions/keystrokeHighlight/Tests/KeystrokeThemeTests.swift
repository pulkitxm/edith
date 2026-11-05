import AppKit
import EdithExtensionSupport
import EdithExtensionTestSupport
import EdithExtensionUI
import SwiftUI
import Testing

@testable import KeystrokeHighlightExtension

@MainActor @Suite(.serialized) struct KeystrokeThemeTests {
    private static let variant = RenderCapture.Variant(
        name: "theme-dark", width: 640, height: 240, zoom: 1, scheme: .dark)

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

    private func pixels(
        _ bitmap: NSBitmapImageRep, where matches: (NSColor) -> Bool
    ) -> Int {
        var count = 0
        for x in 0..<bitmap.pixelsWide {
            for y in 0..<bitmap.pixelsHigh {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                    matches(color)
                else { continue }
                count += 1
            }
        }
        return count
    }

    @Test func keycapEdgesFollowTheTheme() async throws {
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
        let entries = [
            KeystrokeHighlightEntry(keys: ["⌘", "S"], expiresAt: .distantFuture)
        ]
        let green = { (color: NSColor) in color.greenComponent > color.redComponent + 0.15 }
        let warm = { (color: NSColor) in color.redComponent > color.greenComponent + 0.15 }

        try await apply(.teal)
        let teal = try await RenderCapture.render("keystroke-theme-teal", variant: Self.variant) {
            KeystrokeHighlightStage(entries: entries, position: .bottom)
        }
        #expect(pixels(teal.bitmap, where: green) > 100)
        #expect(pixels(teal.bitmap, where: warm) == 0)

        try await apply(.pink)
        let pink = try await RenderCapture.render("keystroke-theme-pink", variant: Self.variant) {
            KeystrokeHighlightStage(entries: entries, position: .bottom)
        }
        #expect(pixels(pink.bitmap, where: warm) > 100)
        #expect(pixels(pink.bitmap, where: green) == 0)
    }
}
