import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI
import Testing

@testable import FocusDimExtension

@MainActor @Suite(.serialized) struct FocusDimCaptureTests {
    private enum Fixture: String, CaseIterable {
        case off, ready, on, error
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
            if fixture == .on {
                defaults.set(true, forKey: FocusDimState.activeKey)
                defaults.set(0.62, forKey: AppStorageKeys.FocusDim.intensity)
            }
            let model = Self.presentation(fixture, defaults: defaults)
            defer { model.stop() }
            if fixture != .off { await model.refresh() }
            #expect(model.active == (fixture != .off))
            #expect((model.error != nil) == (fixture == .error))
            for variant in DeskSettingsCapture.variants {
                let bitmap = try await DeskSettingsCapture.render(
                    "focusdim-\(fixture.rawValue)", variant: variant
                ) {
                    ExtensionPageHost {
                        ControlSettingsHost(presentation: model) {
                            FocusDimSettings(presentation: model)
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
                    domain: "FocusDimCapture", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "The connection to the extension was interrupted."])
            }
        case .ready, .on:
            return ControlPresentation(client: nil, defaults: defaults) { operation, _ in
                guard operation == "focusDim.ui.read" else { return Data() }
                return try await MainActor.run {
                    try ControlPresentationContract.snapshot(
                        defaults: defaults, state: ControlPresentationState())
                }
            }
        }
    }
}
