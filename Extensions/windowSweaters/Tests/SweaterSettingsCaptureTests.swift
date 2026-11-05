import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI
import Testing

@testable import WindowSweatersExtension

@MainActor @Suite(.serialized) struct SweaterSettingsCaptureTests {
    private struct Failure: LocalizedError {
        var errorDescription: String? { "The Window Sweaters engine stopped responding." }
    }

    private func reset(pattern: String = "by-app") {
        let defaults = SharedDefaults.store
        defaults.set(true, forKey: SweaterState.activeKey)
        defaults.set(pattern, forKey: AppStorageKeys.WindowSweaters.pattern)
    }

    private func page(_ model: ControlPresentation) -> some View {
        ExtensionPageHost {
            ControlSettingsHost(presentation: model) {
                Form { WindowSweatersRows(presentation: model) }.edithForm()
            }
        }
    }

    @Test func notRunningExplainsHowToTurnSweatersOn() async throws {
        reset()
        let model = ControlPresentation(client: nil, defaults: SharedDefaults.store)
        defer { model.stop() }
        #expect(!model.active)
        for variant in SurfaceCapture.variants {
            try await SurfaceCapture.render("sweaters-off", variant: variant) { page(model) }
        }
    }

    @Test func runningShowsPreviewAndLabelledControls() async throws {
        reset(pattern: "none")
        let model = ControlPresentation(client: nil, defaults: SharedDefaults.store) { _, _ in
            Data()
        }
        defer { model.stop() }
        #expect(model.active && model.error == nil)
        for variant in SurfaceCapture.variants {
            try await SurfaceCapture.render("sweaters-running", variant: variant) { page(model) }
        }
    }

    @Test func engineErrorOffersRecovery() async throws {
        reset()
        let model = ControlPresentation(client: nil, defaults: SharedDefaults.store) { _, _ in
            throw Failure()
        }
        defer { model.stop() }
        model.perform("refresh")
        let deadline = ContinuousClock.now + .seconds(3)
        while model.error == nil, ContinuousClock.now < deadline { await Task.yield() }
        #expect(model.error == "The Window Sweaters engine stopped responding.")
        for variant in SurfaceCapture.variants where variant.zoom == 1 && !variant.compact {
            try await SurfaceCapture.render("sweaters-error", variant: variant) { page(model) }
        }
    }
}
