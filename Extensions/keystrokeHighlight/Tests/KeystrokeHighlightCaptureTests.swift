import AppKit
import EdithExtensionSupport
import EdithExtensionTestSupport
import EdithExtensionUI
import SwiftUI
import Testing

@testable import KeystrokeHighlightExtension

@MainActor @Suite(.serialized) struct KeystrokeHighlightCaptureTests {
    private static let wide = RenderCapture.Variant(
        name: "wide-light", width: 1600, height: 900, zoom: 1, scheme: .light)

    private enum Fixture: String, CaseIterable {
        case off, paused, live, permission, error
    }

    @Test func overlayStaysLegibleAndOnScreen() async throws {
        let typing = [["S"], ["H"], ["I"], ["P"], ["⌘", "S"], ["⇧", "⌘", "P"]]
        let chords = Array(repeating: ["⌃", "⌥", "⇧", "⌘", "Page ↓"], count: 6)
        for (name, keys, position) in [
            ("typing", typing, KeystrokeHighlightPosition.bottom), ("top", typing, .top),
            ("chords", chords, .bottom),
        ] {
            let entries = keys.map {
                KeystrokeHighlightEntry(keys: $0, expiresAt: .distantFuture)
            }
            for variant in [
                RenderCapture.Variant(
                    name: "laptop-dark", width: 1280, height: 400, zoom: 1, scheme: .dark),
                RenderCapture.Variant(
                    name: "laptop-light", width: 1280, height: 400, zoom: 1, scheme: .light),
            ] {
                let rendered = try await RenderCapture.render(
                    "keystroke-overlay-\(name)", variant: variant
                ) {
                    KeystrokeHighlightStage(entries: entries, position: position)
                        .environment(\.colorScheme, .dark)
                }
                #expect(RenderCapture.distinctColors(rendered.bitmap) > 4)
                #expect(Self.edgesAreClear(rendered.bitmap))
            }
        }
    }

    @Test func keysDrawOneCleanGlyphWithoutAnAccentGhost() async throws {
        func render(_ key: String) async throws -> NSBitmapImageRep {
            let entries = [KeystrokeHighlightEntry(keys: [key], expiresAt: .distantFuture)]
            return try await RenderCapture.render(
                "keystroke-glyph",
                variant: RenderCapture.Variant(
                    name: "glyph-dark", width: 400, height: 240, zoom: 1, scheme: .dark)
            ) {
                KeystrokeHighlightStage(entries: entries, position: .bottom)
                    .environment(\.colorScheme, .dark)
            }.bitmap
        }
        let glyph = try await render("4")
        let blank = try await render(" ")
        var changed = 0
        var tinted = 0
        for y in 0..<glyph.pixelsHigh {
            for x in 0..<glyph.pixelsWide {
                guard let color = glyph.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                    let empty = blank.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
                else { continue }
                let channels = [color.redComponent, color.greenComponent, color.blueComponent]
                let base = [empty.redComponent, empty.greenComponent, empty.blueComponent]
                guard zip(channels, base).contains(where: { abs($0 - $1) > 0.03 }) else {
                    continue
                }
                changed += 1
                if (channels.max() ?? 0) - (channels.min() ?? 0) > 0.2 { tinted += 1 }
            }
        }
        #expect(changed > 0)
        #expect(tinted == 0)
    }

    private static func edgesAreClear(_ bitmap: NSBitmapImageRep) -> Bool {
        let inset = 16 * bitmap.pixelsWide / Int(bitmap.size.width)
        let background = bitmap.colorAt(x: 0, y: 0)
        return stride(from: 0, to: bitmap.pixelsHigh, by: 4).allSatisfy { y in
            [inset, bitmap.pixelsWide - inset].allSatisfy {
                bitmap.colorAt(x: $0, y: y) == background
            }
        }
    }

    @Test func settingsRenderEveryStateAtEverySize() async throws {
        let defaults = SharedDefaults.store
        let keys = ControlPresentationContract.readable
        let stored = ControlPresentationContract.values(from: defaults, keys: keys)
        defer {
            for key in keys { defaults.removeObject(forKey: key) }
            for (key, value) in stored { defaults.set(value, forKey: key) }
        }
        for fixture in Fixture.allCases {
            for key in keys { defaults.removeObject(forKey: key) }
            if fixture == .live || fixture == .permission {
                defaults.set(true, forKey: AppStorageKeys.KeystrokeHighlight.active)
            }
            if fixture == .live {
                defaults.set(true, forKey: AppStorageKeys.KeystrokeHighlight.runtimeActive)
            }
            if fixture == .permission {
                defaults.set(
                    "Input Monitoring is required before key presses can be shown.",
                    forKey: AppStorageKeys.KeystrokeHighlight.runtimeError)
            }
            let model = Self.presentation(fixture, defaults: defaults)
            defer { model.stop() }
            if fixture != .off { await model.refresh() }
            #expect(model.active == (fixture != .off))
            #expect((model.error != nil) == (fixture == .error))
            for variant in RenderCapture.variants + RenderCapture.sheetVariants + [Self.wide] {
                let rendered = try await RenderCapture.render(
                    "keystrokes-\(fixture.rawValue)", variant: variant
                ) {
                    ExtensionPageHost {
                        ControlSettingsHost(presentation: model) {
                            Form { KeystrokeHighlightRows(presentation: model) }.settingsForm()
                        }
                    }
                }
                #expect(rendered.bitmap.pixelsWide >= Int(variant.width))
                #expect(RenderCapture.distinctColors(rendered.bitmap) > 20)
            }
        }
    }

    private static func presentation(_ fixture: Fixture, defaults: UserDefaults)
        -> ControlPresentation
    {
        switch fixture {
        case .off:
            return ControlPresentation(client: nil, defaults: defaults)
        case .error:
            return ControlPresentation(client: nil, defaults: defaults) { _, _ in
                throw NSError(
                    domain: "KeystrokeHighlightCapture", code: 1,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "The connection to the extension was interrupted."
                    ])
            }
        case .paused, .live, .permission:
            return ControlPresentation(client: nil, defaults: defaults) { operation, _ in
                guard operation == "keystrokeHighlight.ui.read" else { return Data() }
                return try await MainActor.run {
                    try ControlPresentationContract.snapshot(
                        defaults: defaults, state: ControlPresentationState())
                }
            }
        }
    }
}
