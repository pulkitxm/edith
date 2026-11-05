import AVFoundation
import AppKit
import EdithExtensionSupport
import EdithExtensionTestSupport
import EdithExtensionUI
import SwiftUI
import Testing

@testable import NotchShelfExtension

@MainActor @Suite(.serialized) struct NotchSettingsCaptureTests {
    private static let wide = RenderCapture.Variant(
        name: "wide-light", width: 1600, height: 900, zoom: 1, scheme: .light)

    private struct Failure: LocalizedError {
        var errorDescription: String? {
            "Notch Shelf did not answer. Its settings may be out of date."
        }
    }

    private func page(_ model: NotchSettingsModel) -> some View {
        ExtensionPageHost { NotchSettingsPage(model: model) }
    }

    @Test func notRunningLocksSettingsAndSaysWhy() async throws {
        let model = NotchSettingsModel(client: nil)
        #expect(!model.available)
        for variant in [Self.wide] + RenderCapture.variants {
            try await RenderCapture.render("notch-settings-off", variant: variant) { page(model) }
        }
    }

    @Test func runningShowsGroupedSettings() async throws {
        var snapshot = NotchSettingsSnapshot.empty
        snapshot.preferences[AppStorageKeys.Notch.browserEnabled] = "1"
        snapshot.browserProfile = "Work"
        let model = NotchSettingsModel(snapshot: snapshot) { _, _ in
            try JSONEncoder().encode(snapshot)
        }
        #expect(model.available && model.error == nil)
        for variant in [Self.wide] + RenderCapture.variants {
            try await RenderCapture.render("notch-settings-running", variant: variant) {
                page(model)
            }
        }
    }

    @Test func failedReadOffersRecovery() async throws {
        let model = NotchSettingsModel(snapshot: .empty) { _, _ in throw Failure() }
        await model.refresh()
        #expect(model.error == "Notch Shelf did not answer. Its settings may be out of date.")
        for variant in [Self.wide] + RenderCapture.variants
        where variant.zoom == 1 && !variant.compact {
            try await RenderCapture.render("notch-settings-error", variant: variant) {
                page(model)
            }
        }
    }
}

@MainActor @Suite(.serialized) struct NotchCameraCaptureTests {
    @Test func cameraPermissionStatesShowOneClearAction() async throws {
        let notch = RenderCapture.Variant(
            name: "notch", width: 560, height: 260, zoom: 1, scheme: .dark)
        for (name, status) in [
            ("prompt", AVAuthorizationStatus.notDetermined), ("denied", .denied),
        ] {
            let state = NotchCameraState(
                authorization: status.rawValue, devices: [], selectedID: nil, frame: nil,
                error: nil)
            let client = NotchCameraClient(
                namespace: "notch-camera-capture-" + UUID().uuidString, presentationID: UUID()
            ) { _, _ in try JSONEncoder().encode(state) }
            await client.load()
            #expect(client.state?.authorization == status.rawValue)
            try await RenderCapture.render("notch-camera-\(name)", variant: notch) {
                NotchRemoteCameraTab(model: client).background(.black)
            }
            client.stop()
        }
    }
}
