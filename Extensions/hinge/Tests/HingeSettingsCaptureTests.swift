import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI
import Testing

@testable import HingeExtension

@MainActor @Suite(.serialized) struct HingeSettingsCaptureTests {
    private struct Failure: LocalizedError {
        var errorDescription: String? { "The Hinge engine stopped responding." }
    }

    private let keys = [
        HingeState.activeKey, HingeSettings.effectStrength, HingeSettings.sideFill,
        HingeSettings.cropsTop, HingeSettings.blursByDistance, HingeSettings.openAngle,
        HingeSettings.sensorAvailable, HingeSettings.status,
    ]

    private func reset(sensor: Bool, active: Bool = false, status: String = "") {
        let defaults = SharedDefaults.store
        for key in keys { defaults.removeObject(forKey: key) }
        defaults.set(sensor, forKey: HingeSettings.sensorAvailable)
        defaults.set(active, forKey: HingeState.activeKey)
        if sensor { defaults.set(112.0, forKey: HingeSettings.openAngle) }
        if !status.isEmpty { defaults.set(status, forKey: HingeSettings.status) }
    }

    private func page(_ model: ControlPresentation) -> some View {
        ExtensionPageHost {
            ControlSettingsHost(presentation: model) { HingeRows(presentation: model) }
        }
    }

    private func running() -> ControlPresentation {
        ControlPresentation(client: nil, defaults: SharedDefaults.store) { _, _ in Data() }
    }

    @Test func notRunningExplainsHowToTurnHingeOn() async throws {
        reset(sensor: false)
        let model = ControlPresentation(client: nil, defaults: SharedDefaults.store)
        defer { model.stop() }
        #expect(!model.active)
        for variant in SurfaceCapture.variants {
            try await SurfaceCapture.render("hinge-off", variant: variant) { page(model) }
        }
    }

    @Test func runningWithLidSensorShowsTheFoldControls() async throws {
        reset(sensor: true, active: true)
        let model = running()
        defer { model.stop() }
        #expect(model.active && model.error == nil)
        for variant in SurfaceCapture.variants {
            try await SurfaceCapture.render("hinge-running", variant: variant) { page(model) }
        }
    }

    @Test func runningWithoutSensorExplainsWhatIsMissing() async throws {
        reset(sensor: false, active: false)
        let model = running()
        defer { model.stop() }
        for variant in SurfaceCapture.variants where variant.zoom == 1 {
            try await SurfaceCapture.render("hinge-nosensor", variant: variant) { page(model) }
        }
    }

    @Test func engineErrorOffersRecovery() async throws {
        reset(
            sensor: true, active: true,
            status: "Allow Edith in Screen Recording settings, then turn Hinge on again.")
        let model = ControlPresentation(client: nil, defaults: SharedDefaults.store) { _, _ in
            throw Failure()
        }
        defer { model.stop() }
        model.perform("calibrate")
        let deadline = ContinuousClock.now + .seconds(3)
        while model.error == nil, ContinuousClock.now < deadline { await Task.yield() }
        #expect(model.error == "The Hinge engine stopped responding.")
        for variant in SurfaceCapture.variants where variant.zoom == 1 {
            try await SurfaceCapture.render("hinge-error", variant: variant) { page(model) }
        }
    }
}
