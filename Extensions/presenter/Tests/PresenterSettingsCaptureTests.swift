import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import SwiftUI
import Testing

@testable import PresenterExtension

@MainActor private final class FailureSwitch {
    var on = false
}

private struct Unavailable: LocalizedError {
    var errorDescription: String? { "The extension stopped responding." }
}

@MainActor private enum ControlFixture {
    static func packet(_ preferences: [String: Any], state: ControlPresentationState) throws
        -> Data
    {
        try JSONEncoder().encode(
            ControlPresentationPacket(
                preferences: ControlPresentationContract.encode(preferences), state: state))
    }

    static func loaded(
        _ preferences: [String: Any], state: ControlPresentationState = .init(),
        failingAfterLoad: Bool = false
    ) async throws -> ControlPresentation {
        let data = try packet(preferences, state: state)
        let failing = FailureSwitch()
        let model = ControlPresentation(
            client: nil, defaults: SharedDefaults.store,
            invoke: { _, _ in
                if failing.on { throw Unavailable() }
                return data
            })
        await model.refresh()
        if failingAfterLoad {
            failing.on = true
            model.perform("refresh")
            while model.error == nil { await Task.yield() }
        }
        return model
    }

    static func loading() -> ControlPresentation {
        ControlPresentation(client: nil, defaults: SharedDefaults.store, invoke: { _, _ in Data() })
    }

    static func failed() async -> ControlPresentation {
        let model = ControlPresentation(
            client: nil, defaults: SharedDefaults.store, invoke: { _, _ in throw Unavailable() })
        await model.refresh()
        return model
    }

    static func inactive() -> ControlPresentation {
        ControlPresentation(client: nil, defaults: SharedDefaults.store)
    }
}

@MainActor @Suite(.serialized) struct PresenterSettingsCaptureTests {
    @Test func settingsRenderEveryStateAtEverySize() async throws {
        try await SettingsRenderCapture.withAccessibility {
            let preferences: [String: Any] = [
                "presenterEnabled": true, "presenterMode": false, "presenterAutoEnabled": true,
            ]
            let ready = try await ControlFixture.loaded(
                preferences, state: ControlPresentationState(jevConfigured: true))
            let manual = try await ControlFixture.loaded(
                preferences.merging(["presenterMode": true, "presenterAutoEnabled": false]) {
                    $1
                })
            let stale = try await ControlFixture.loaded(preferences, failingAfterLoad: true)
            let loading = ControlFixture.loading()
            let failed = await ControlFixture.failed()
            defer { [ready, manual, stale, loading, failed].forEach { $0.stop() } }
            #expect(ready.ready && manual.ready && stale.error != nil && failed.error != nil)
            let cases: [(String, ControlPresentation, Bool, Bool, String?)] = [
                ("auto", ready, false, true, "Shortcut"),
                ("manual", manual, true, false, "Shortcut"),
                ("stale", stale, false, true, "Retry"),
                ("loading", loading, false, false, nil),
                ("error", failed, false, false, "Retry"),
            ]
            let defaults = SharedDefaults.store
            for (name, model, mode, auto, label) in cases {
                defaults.set(mode, forKey: AppStorageKeys.Presenter.mode)
                defaults.set(auto, forKey: AppStorageKeys.Presenter.autoEnabled)
                for variant in SettingsRenderCapture.variants {
                    let host = try await SettingsRenderCapture.render(
                        "presenter-settings-\(name)", variant: variant
                    ) {
                        ControlSettingsHost(presentation: model) {
                            Form { PresenterRows(presentation: model) }.edithForm()
                        }
                    }
                    if let label {
                        #expect(
                            SettingsRenderCapture.find(host, label: label) != nil,
                            "\(name) \(variant.name) is missing \(label)")
                    }
                }
            }
        }
    }
}
