import AppKit
import EdithExtensionSupport
import EdithExtensionTestSupport
import EdithExtensionUI
import SwiftUI
import Testing

@testable import WindowSweatersExtension

@MainActor @Suite(.serialized) struct SweaterSettingsCaptureTests {
    private static let wide = RenderCapture.Variant(
        name: "wide-light", width: 1600, height: 900, zoom: 1, scheme: .light)

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
                Form { WindowSweatersRows(presentation: model) }.settingsForm()
            }
        }
    }

    @Test func idlePageKeepsEveryControlUsable() async throws {
        reset()
        SharedDefaults.store.set(false, forKey: SweaterState.activeKey)
        let model = ControlPresentation(client: nil, defaults: SharedDefaults.store)
        defer { model.stop() }
        #expect(!model.active)
        for variant in RenderCapture.variants + [Self.wide] {
            try await RenderCapture.render("sweaters-idle", variant: variant) { page(model) }
        }
        try await RenderCapture.withAccessibility {
            let rendered = try await RenderCapture.render(
                "sweaters-idle-usable", variant: RenderCapture.variants[0]
            ) { page(model) }
            let toggle = try #require(
                RenderCapture.find(
                    rendered.host,
                    label:
                        "Sweaters on, Shows or hides the knitting on every window. Your colours are kept."
                ))
            #expect((toggle as AnyObject).isAccessibilityEnabled?() == true)
        }
    }

    @Test func sweatersTurnedOnWhileIdleSayWhenTheyStart() async throws {
        reset()
        let model = ControlPresentation(client: nil, defaults: SharedDefaults.store)
        defer { model.stop() }
        try await RenderCapture.withAccessibility {
            for variant in (RenderCapture.variants + [Self.wide]) where variant.zoom == 1 {
                let rendered = try await RenderCapture.render(
                    "sweaters-idle-on", variant: variant
                ) { page(model) }
                #expect(
                    RenderCapture.find(
                        rendered.host,
                        label: "Your choice is saved, so there is nothing else to do.") != nil)
            }
        }
    }

    @Test func runningShowsPreviewAndLabelledControls() async throws {
        reset(pattern: "none")
        let model = ControlPresentation(client: nil, defaults: SharedDefaults.store) { _, _ in
            Data()
        }
        defer { model.stop() }
        #expect(model.active && model.error == nil)
        for variant in RenderCapture.variants + [Self.wide] {
            try await RenderCapture.render("sweaters-running", variant: variant) { page(model) }
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
        for variant in RenderCapture.variants + [Self.wide]
        where variant.zoom == 1 && !variant.compact {
            try await RenderCapture.render("sweaters-error", variant: variant) { page(model) }
        }
    }
}
