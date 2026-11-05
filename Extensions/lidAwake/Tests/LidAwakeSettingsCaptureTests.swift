import AppKit
import EdithExtensionSupport
import EdithExtensionTestSupport
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
        try await RenderCapture.withAccessibility {
            let off = await Self.model(Self.snapshot())
            let on = await Self.model(Self.snapshot(active: true, remaining: 2_700))
            let disabled = await Self.model(Self.snapshot(enabled: false))
            let failed = await Self.failing()
            let busy = await Self.applying()
            let checking = LidAwakeOperationModel { _ in
                try await Task.sleep(for: .seconds(600))
                return Self.snapshot()
            }
            checking.refreshStatus()
            defer { [off, on, disabled, failed, busy, checking].forEach { $0.cancel() } }
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
                ("checking", checking, "How long"),
                ("applying", busy, "Applying system sleep state"),
            ]
            for (name, model, label) in cases {
                for variant in RenderCapture.layoutVariants {
                    let rendered = try await RenderCapture.render(
                        "lidAwake-settings-\(name)", variant: variant
                    ) {
                        Form { LidAwakeRows(operations: model, chooseSession: { _ in }) }
                            .settingsForm()
                    }
                    #expect(
                        RenderCapture.find(rendered.host, label: label) != nil,
                        "\(name) \(variant.name) is missing \(label)")
                    if name == "error" || name == "checking" {
                        #expect(
                            RenderCapture.find(
                                rendered.host,
                                label:
                                    "Lid Awake is turned off. Turn it on in Extensions to use these controls."
                            ) == nil)
                    }
                }
            }
        }
    }

    @Test func statusDetailNeverClaimsOffBeforeARead() {
        #expect(
            LidAwakeRows.activeDetail(snapshot: nil, failed: true)
                == "Status unknown. Edith could not reach Lid Awake.")
        #expect(
            LidAwakeRows.activeDetail(snapshot: nil, failed: false)
                == "Checking the current state.")
        #expect(
            LidAwakeRows.activeDetail(snapshot: Self.snapshot(), failed: true)
                == "Off. Closing the lid sleeps the Mac, even with Keep Awake on.")
        #expect(
            LidAwakeRows.activeDetail(
                snapshot: Self.snapshot(active: true, remaining: 2_700), failed: false)
                == "On. Turns off in 45 min.")
    }
}

extension RenderCapture {
    fileprivate static let layoutVariants =
        variants + [Variant(name: "wide-light", width: 1600, height: 900, zoom: 1, scheme: .light)]
}
