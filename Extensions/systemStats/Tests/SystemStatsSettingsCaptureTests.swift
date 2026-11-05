import AppKit
import EdithExtensionSupport
import EdithExtensionTestSupport
import EdithExtensionUI
import Foundation
import SwiftUI
import Testing

@testable import SystemStatsExtension

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

@MainActor @Suite(.serialized) struct SystemStatsSettingsCaptureTests {
    @Test func settingsRenderEveryStateAtEverySize() async throws {
        try await RenderCapture.withAccessibility {
            let automatic = try await ControlFixture.loaded(
                [AppStorageKeys.MenuBar.statsColorMode: "auto"])
            let custom = try await ControlFixture.loaded([
                AppStorageKeys.MenuBar.statsColorMode: "custom",
                AppStorageKeys.MenuBar.statsColorHex: "4F8EF7",
            ])
            let stale = try await ControlFixture.loaded(
                [AppStorageKeys.MenuBar.statsColorMode: "auto"], failingAfterLoad: true)
            let loading = ControlFixture.loading()
            let failed = await ControlFixture.failed()
            let inactive = ControlFixture.inactive()
            defer { [automatic, custom, stale, loading, failed, inactive].forEach { $0.stop() } }
            #expect(automatic.ready && custom.ready)
            #expect(stale.error != nil && failed.error != nil)
            let off = "Menu Bar Stats is turned off. Turn it on in Extensions to change these."
            let cases: [(String, ControlPresentation, String, String?)] = [
                ("automatic", automatic, "auto", "Color"),
                ("custom", custom, "custom", "Custom color"),
                ("stale", stale, "auto", "Retry"),
                ("loading", loading, "auto", nil),
                ("error", failed, "auto", "Retry"),
                ("inactive", inactive, "auto", off),
            ]
            let defaults = SharedDefaults.store
            for (name, model, mode, label) in cases {
                defaults.set(mode, forKey: AppStorageKeys.MenuBar.statsColorMode)
                defaults.set("4F8EF7", forKey: AppStorageKeys.MenuBar.statsColorHex)
                for variant in RenderCapture.layoutVariants {
                    let rendered = try await RenderCapture.render(
                        "systemStats-settings-\(name)", variant: variant
                    ) {
                        ControlSettingsHost(presentation: model) {
                            Form {
                                SettingsIssueSection()
                                SystemStatsRows(presentation: model, defaults: defaults)
                            }
                            .settingsForm()
                        }
                    }
                    if let label {
                        #expect(
                            RenderCapture.find(rendered.host, label: label) != nil,
                            "\(name) \(variant.name) is missing \(label)")
                    }
                }
            }
        }
    }
}

extension RenderCapture {
    fileprivate static let layoutVariants =
        variants + [Variant(name: "wide-light", width: 1600, height: 900, zoom: 1, scheme: .light)]
}
