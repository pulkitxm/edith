import AppKit
import EdithExtensionSupport
import EdithExtensionTestSupport
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

    @Test func turningItOnAnnouncesTheChangeSoAnIdleExtensionStarts() async throws {
        try await RenderCapture.withAccessibility {
            SharedDefaults.store.removeObject(forKey: "preventSleep")
            defer { SharedDefaults.store.removeObject(forKey: "preventSleep") }
            let received = FailureSwitch()
            let observer = IPC.observe(IPC.Name.settingsChanged) {
                MainActor.assumeIsolated { received.on = true }
            }
            defer { IPC.stopObserving(observer) }
            let rendered = try await RenderCapture.render(
                "keepAwake-toggle", variant: RenderCapture.variants[0]
            ) {
                KeepAwakeSettings(defaults: SharedDefaults.store, synchronize: {})
            }
            let element = try #require(RenderCapture.find(rendered.host, label: "Keep awake"))
            _ = element.perform(NSSelectorFromString("accessibilityPerformPress"))
            let deadline = ContinuousClock.now + .seconds(2)
            while !received.on, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(received.on)
            #expect(SharedDefaults.store.bool(forKey: "preventSleep"))
        }
    }

    @Test func settingsRenderEveryStateAtEverySize() async throws {
        try await RenderCapture.withAccessibility {
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
                for variant in RenderCapture.layoutVariants {
                    let rendered = try await RenderCapture.render(
                        "keepAwake-settings-\(name)", variant: variant
                    ) {
                        ControlSettingsHost(presentation: model) {
                            KeepAwakeSettings(defaults: SharedDefaults.store, synchronize: {})
                        }
                    }
                    if name != "loading" {
                        #expect(
                            RenderCapture.find(rendered.host, label: label) != nil,
                            "\(name) \(variant.name) is missing \(label)")
                    }
                }
            }
            SharedDefaults.store.removeObject(forKey: "preventSleep")
        }
    }
}

extension RenderCapture {
    fileprivate static let layoutVariants =
        variants + [Variant(name: "wide-light", width: 1600, height: 900, zoom: 1, scheme: .light)]
}
