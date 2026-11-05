import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import SwiftUI
import Testing

@testable import LidAwakeExtension

@MainActor @Suite(.serialized) struct LidAwakeSettingsCaptureTests {
    private struct Unavailable: LocalizedError {
        var errorDescription: String? { "The background helper did not answer." }
    }

    private static func snapshot(
        enabled: Bool = true, active: Bool = false, remaining: Double? = nil
    ) -> LidAwakeSnapshot {
        LidAwakeSnapshot(
            extensionEnabled: enabled, active: active, requestedActive: active, applying: false,
            batterySuspended: false, session: remaining == nil ? .indefinite : .oneHour,
            remainingSeconds: remaining, batteryThreshold: 20, restoreOnQuit: true,
            helperStatus: "enabled", appRunning: true)
    }

    private static func model(_ snapshot: LidAwakeSnapshot) async -> LidAwakeOperationModel {
        let model = LidAwakeOperationModel { _ in snapshot }
        await model.refreshStatus()?.value
        return model
    }

    private static func failing() async -> LidAwakeOperationModel {
        let model = LidAwakeOperationModel { _ in throw Unavailable() }
        await model.refreshStatus()?.value
        return model
    }

    private static func applying() async -> LidAwakeOperationModel {
        let model = LidAwakeOperationModel { request in
            if case .status = request { return snapshot() }
            try await Task.sleep(for: .seconds(600))
            return snapshot()
        }
        await model.refreshStatus()?.value
        model.perform(.on(.indefinite))
        return model
    }

    @Test func settingsRenderEveryStateAtEverySize() async throws {
        try await SettingsRenderCapture.withAccessibility {
            let off = await Self.model(Self.snapshot())
            let on = await Self.model(Self.snapshot(active: true, remaining: 2_700))
            let disabled = await Self.model(Self.snapshot(enabled: false))
            let failed = await Self.failing()
            let busy = await Self.applying()
            defer { [off, on, disabled, failed, busy].forEach { $0.cancel() } }
            #expect(off.lastSnapshot?.active == false && on.lastSnapshot?.active == true)
            #expect(failed.errorMessage == "The background helper did not answer.")
            #expect(busy.applying)
            let cases: [(String, LidAwakeOperationModel, String)] = [
                ("off", off, "How long"),
                ("on", on, "How long"),
                (
                    "disabled", disabled,
                    "Lid Awake is turned off. Turn it on in Extensions to use these controls."
                ),
                ("error", failed, "Retry"),
                ("applying", busy, "Applying system sleep state"),
            ]
            for (name, model, label) in cases {
                for variant in SettingsRenderCapture.variants {
                    let host = try await SettingsRenderCapture.render(
                        "lidAwake-settings-\(name)", variant: variant
                    ) {
                        Form { LidAwakeRows(operations: model, chooseSession: { _ in }) }
                            .edithForm()
                    }
                    #expect(
                        SettingsRenderCapture.find(host, label: label) != nil,
                        "\(name) \(variant.name) is missing \(label)")
                }
            }
        }
    }
}
