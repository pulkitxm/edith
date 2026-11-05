import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import SwiftUI
import Testing

@testable import KeepAwakeExtension

@MainActor private final class FailureSwitch {
    var on = false
}

@MainActor @Suite(.serialized) struct KeepAwakeSettingsCaptureTests {
    private struct Unavailable: LocalizedError {
        var errorDescription: String? { "Keep Awake stopped responding." }
    }

    private static func packet(preventSleep: Bool) throws -> Data {
        try JSONEncoder().encode(
            ControlPresentationPacket(
                preferences: ControlPresentationContract.encode([
                    "preventSleep": preventSleep, "keepAwakeEnabled": true,
                ]),
                state: ControlPresentationState()))
    }

    private static func loaded(preventSleep: Bool, failingActions: Bool = false) async throws
        -> ControlPresentation
    {
        let data = try packet(preventSleep: preventSleep)
        let failing = FailureSwitch()
        let model = ControlPresentation(
            client: nil, defaults: SharedDefaults.store,
            invoke: { _, _ in
                if failing.on { throw Unavailable() }
                return data
            })
        await model.refresh()
        if failingActions {
            failing.on = true
            model.perform("refresh")
            while model.error == nil { await Task.yield() }
        }
        return model
    }

    @Test func settingsRenderEveryStateAtEverySize() async throws {
        try await SettingsRenderCapture.withAccessibility {
            let off = try await Self.loaded(preventSleep: false)
            let on = try await Self.loaded(preventSleep: true)
            let stale = try await Self.loaded(preventSleep: true, failingActions: true)
            let loading = ControlPresentation(
                client: nil, defaults: SharedDefaults.store, invoke: { _, _ in Data() })
            let failed = ControlPresentation(
                client: nil, defaults: SharedDefaults.store,
                invoke: { _, _ in throw Unavailable() })
            await failed.refresh()
            defer { [off, on, stale, loading, failed].forEach { $0.stop() } }
            #expect(off.ready && on.ready && stale.ready && !loading.ready && !failed.ready)
            #expect(stale.error == "Keep Awake stopped responding.")
            let cases: [(String, ControlPresentation, Bool, String)] = [
                ("off", off, false, "Keep awake"),
                ("on", on, true, "Keep awake"),
                ("stale", stale, true, "Retry"),
                ("loading", loading, false, "Keep awake"),
                ("error", failed, false, "Retry"),
            ]
            for (name, model, preventSleep, label) in cases {
                SharedDefaults.store.set(preventSleep, forKey: "preventSleep")
                for variant in SettingsRenderCapture.variants {
                    let host = try await SettingsRenderCapture.render(
                        "keepAwake-settings-\(name)", variant: variant
                    ) {
                        ControlSettingsHost(presentation: model) {
                            KeepAwakeSettings(defaults: SharedDefaults.store, synchronize: {})
                        }
                    }
                    if name != "loading" {
                        #expect(
                            SettingsRenderCapture.find(host, label: label) != nil,
                            "\(name) \(variant.name) is missing \(label)")
                    }
                }
            }
            SharedDefaults.store.removeObject(forKey: "preventSleep")
        }
    }
}
