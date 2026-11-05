import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI
import Testing

@testable import KeystrokeHighlightExtension

@MainActor @Suite(.serialized) struct KeystrokeHighlightCaptureTests {
    private enum Fixture: String, CaseIterable {
        case off, paused, live, permission, error
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
            for variant in DeskSettingsCapture.variants {
                let bitmap = try await DeskSettingsCapture.render(
                    "keystrokes-\(fixture.rawValue)", variant: variant
                ) {
                    ExtensionPageHost {
                        ControlSettingsHost(presentation: model) {
                            Form { KeystrokeHighlightRows(presentation: model) }.deskForm()
                        }
                    }
                }
                #expect(bitmap.pixelsWide >= Int(variant.width))
                #expect(DeskSettingsCapture.distinctColors(bitmap) > 20)
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
                        NSLocalizedDescriptionKey: "The connection to the extension was interrupted."
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
