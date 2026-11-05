import AppKit
import EdithExtensionSupport
import EdithExtensionTestSupport
import EdithExtensionUI
import SwiftUI
import Testing

@testable import ColorPickerExtension

@MainActor @Suite(.serialized) struct ColorPickerCaptureTests {
    private static let wide = RenderCapture.Variant(
        name: "wide-light", width: 1600, height: 900, zoom: 1, scheme: .light)

    private enum Fixture: String, CaseIterable {
        case off, empty, populated, error
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
            if fixture == .populated || fixture == .off {
                for index in 0..<26 {
                    let hue = Double(index) / 26
                    let color = NSColor(hue: hue, saturation: 0.62, brightness: 0.86, alpha: 1)
                    ColorHistoryStore.add(
                        ColorSwatch(
                            red: color.redComponent, green: color.greenComponent,
                            blue: color.blueComponent, profile: .sRGB),
                        limit: 100, into: defaults)
                }
            }
            let model = Self.presentation(fixture, defaults: defaults)
            defer { model.stop() }
            if fixture != .off { await model.refresh() }
            if fixture == .error {
                model.perform("pick")
                for _ in 0..<200 where model.error == nil { await Task.yield() }
            }
            #expect(model.active == (fixture != .off))
            #expect((model.error != nil) == (fixture == .error))
            #expect(
                ColorHistoryStore.load(from: defaults).isEmpty
                    == (fixture == .empty || fixture == .error))
            for variant in RenderCapture.variants + RenderCapture.sheetVariants + [Self.wide] {
                let rendered = try await RenderCapture.render(
                    "colorpicker-\(fixture.rawValue)", variant: variant
                ) {
                    ExtensionPageHost {
                        ControlSettingsHost(presentation: model) {
                            Form { ColorPickerRows(presentation: model) }.settingsForm()
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
                    domain: "ColorPickerCapture", code: 1,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "The connection to the extension was interrupted."
                    ])
            }
        case .empty, .populated:
            return ControlPresentation(client: nil, defaults: defaults) { operation, _ in
                guard operation == "colorPicker.ui.read" else { return Data() }
                return try await MainActor.run {
                    try ControlPresentationContract.snapshot(
                        defaults: defaults, state: ControlPresentationState())
                }
            }
        }
    }
}
