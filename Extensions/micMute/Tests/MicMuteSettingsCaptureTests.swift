import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import SwiftUI
import Testing

@testable import MicMuteExtension

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

@MainActor @Suite(.serialized) struct MicMuteSettingsCaptureTests {
    @Test func settingsRenderEveryStateAtEverySize() async throws {
        try await SettingsRenderCapture.withAccessibility {
            let preferences: [String: Any] = ["micMuteEnabled": true, "micMuteInMenuBar": true]
            let live = try await ControlFixture.loaded(preferences)
            let muted = try await ControlFixture.loaded(
                preferences, state: ControlPresentationState(muted: true))
            let stale = try await ControlFixture.loaded(preferences, failingAfterLoad: true)
            let loading = ControlFixture.loading()
            let failed = await ControlFixture.failed()
            let inactive = ControlFixture.inactive()
            defer { [live, muted, stale, loading, failed, inactive].forEach { $0.stop() } }
            #expect(live.ready)
            #expect(muted.state.muted)
            #expect(stale.error != nil)
            #expect(failed.error != nil)
            let cases: [(String, ControlPresentation, String?)] = [
                ("live", live, "Live"),
                ("muted", muted, "Muted"),
                ("stale", stale, "Retry"),
                ("loading", loading, nil),
                ("error", failed, "Retry"),
                (
                    "inactive", inactive,
                    "Mic Mute is turned off. Turn it on in Extensions to use these controls."
                ),
            ]
            for (name, model, label) in cases {
                for variant in SettingsRenderCapture.variants {
                    let host = try await SettingsRenderCapture.render(
                        "micMute-settings-\(name)", variant: variant
                    ) {
                        ControlSettingsHost(presentation: model) {
                            Form { MicMuteRows(presentation: model) }.edithForm()
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
