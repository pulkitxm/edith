import AppKit
import EdithExtensionSupport
import EdithExtensionTestSupport
import EdithExtensionUI
import SwiftUI
import Testing

@testable import HingeExtension

@MainActor @Suite(.serialized) struct HingeSettingsCaptureTests {
    private static let wide = RenderCapture.Variant(
        name: "wide-light", width: 1600, height: 900, zoom: 1, scheme: .light)

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

    private func expectUsable(_ label: String, in host: NSView) throws {
        let control = try #require(RenderCapture.find(host, label: label))
        #expect((control as AnyObject).isAccessibilityEnabled?() == true)
    }

    @Test func idlePageKeepsEveryControlUsable() async throws {
        reset(sensor: false)
        let model = ControlPresentation(client: nil, defaults: SharedDefaults.store)
        defer { model.stop() }
        #expect(!model.active)
        for variant in RenderCapture.variants + [Self.wide] {
            try await RenderCapture.render("hinge-idle", variant: variant) { page(model) }
        }
        try await RenderCapture.withAccessibility {
            let rendered = try await RenderCapture.render(
                "hinge-idle-usable", variant: RenderCapture.variants[0]
            ) { page(model) }
            try expectUsable(
                "Fold the desktop, Turning it off puts the screen straight back to normal.",
                in: rendered.host)
            try expectUsable(
                "Crop the top, Trims the top edge as it bends so the picture does not stretch.",
                in: rendered.host)
            let calibrate = try #require(
                RenderCapture.find(rendered.host, label: "Use current angle"))
            #expect((calibrate as AnyObject).isAccessibilityEnabled?() == false)
        }
    }

    @Test func foldTurnedOnWhileIdleSaysWhenItStarts() async throws {
        reset(sensor: false, active: true)
        let model = ControlPresentation(client: nil, defaults: SharedDefaults.store)
        defer { model.stop() }
        try await RenderCapture.withAccessibility {
            for variant in (RenderCapture.variants + [Self.wide]) where variant.zoom == 1 {
                let rendered = try await RenderCapture.render(
                    "hinge-idle-on", variant: variant
                ) { page(model) }
                #expect(
                    RenderCapture.find(
                        rendered.host,
                        label: "Your choice is saved and takes effect as soon as it runs.") != nil)
            }
        }
    }

    @Test func runningWithLidSensorShowsTheFoldControls() async throws {
        reset(sensor: true, active: true)
        let model = running()
        defer { model.stop() }
        #expect(model.active && model.error == nil)
        for variant in RenderCapture.variants + [Self.wide] {
            try await RenderCapture.render("hinge-running", variant: variant) { page(model) }
        }
    }

    @Test func runningWithoutSensorExplainsWhatIsMissing() async throws {
        reset(sensor: false, active: false)
        let model = running()
        defer { model.stop() }
        for variant in (RenderCapture.variants + [Self.wide]) where variant.zoom == 1 {
            try await RenderCapture.render("hinge-nosensor", variant: variant) { page(model) }
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
        for variant in (RenderCapture.variants + [Self.wide]) where variant.zoom == 1 {
            try await RenderCapture.render("hinge-error", variant: variant) { page(model) }
        }
    }
}
