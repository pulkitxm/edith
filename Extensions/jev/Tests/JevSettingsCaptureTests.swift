import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI
import Testing

@testable import JevExtension

@MainActor @Suite(.serialized) struct JevSettingsCaptureTests {
    private struct Failure: LocalizedError {
        var errorDescription: String? { "Jev could not be reached. Check your connection." }
    }

    private func model(_ status: JevStatus?) -> JevSettingsModel {
        let model = JevSettingsModel(read: { _ in status ?? JevStatus(state: .notConfigured) }) {
            _ in status ?? JevStatus(state: .notConfigured)
        }
        model.status = status
        return model
    }

    private func page(_ model: JevSettingsModel) -> some View {
        ExtensionPageHost { JevSettingsPane(model: model) }
    }

    @Test func firstRunExplainsThatJevIsOptional() async throws {
        let model = model(JevStatus(state: .notConfigured))
        #expect(model.status?.hasSavedKey == false)
        for variant in SurfaceCapture.variants {
            try await SurfaceCapture.render("jev-empty", variant: variant) { page(model) }
        }
    }

    @Test func loadingShowsPlaceholdersInsteadOfStatus() async throws {
        let model = model(nil)
        #expect(model.status == nil)
        for variant in SurfaceCapture.variants where variant.zoom == 1 && !variant.compact {
            try await SurfaceCapture.render("jev-loading", variant: variant) { page(model) }
        }
    }

    @Test func configuredKeyShowsActivity() async throws {
        let model = model(
            JevStatus(
                state: .ready, keyHint: "ts_live_...4f2a", models: ["jev-1", "jev-1-mini"],
                decisions: 1284, medianMilliseconds: 96, checkedAt: Date()))
        #expect(model.status?.isConfigured == true)
        for variant in SurfaceCapture.variants {
            try await SurfaceCapture.render("jev-ready", variant: variant) { page(model) }
        }
    }

    @Test func failedCheckOffersRecovery() async throws {
        let model = JevSettingsModel(read: { _ in throw Failure() }) { _ in throw Failure() }
        model.status = JevStatus(
            state: .unreachable, keyHint: "ts_live_...4f2a",
            message: "The last check timed out after 8 seconds.")
        model.load(probe: true)
        let deadline = ContinuousClock.now + .seconds(3)
        while model.phase == .loading, ContinuousClock.now < deadline { await Task.yield() }
        #expect(model.phase == .failed("Jev could not be reached. Check your connection."))
        for variant in SurfaceCapture.variants where variant.zoom == 1 {
            try await SurfaceCapture.render("jev-error", variant: variant) { page(model) }
        }
    }
}
