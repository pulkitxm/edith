import AVFoundation
import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI
import Testing

@testable import NotchShelfExtension

@MainActor @Suite(.serialized) struct NotchSettingsCaptureTests {
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
        for variant in SurfaceCapture.variants {
            try await SurfaceCapture.render("notch-settings-off", variant: variant) { page(model) }
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
        for variant in SurfaceCapture.variants {
            try await SurfaceCapture.render("notch-settings-running", variant: variant) {
                page(model)
            }
        }
    }

    @Test func failedReadOffersRecovery() async throws {
        let model = NotchSettingsModel(snapshot: .empty) { _, _ in throw Failure() }
        await model.refresh()
        #expect(model.error == "Notch Shelf did not answer. Its settings may be out of date.")
        for variant in SurfaceCapture.variants where variant.zoom == 1 && !variant.compact {
            try await SurfaceCapture.render("notch-settings-error", variant: variant) {
                page(model)
            }
        }
    }
}

@MainActor @Suite(.serialized) struct NotchCameraCaptureTests {
    @Test func cameraPermissionStatesShowOneClearAction() async throws {
        let notch = SurfaceCapture.Variant(
            name: "notch", size: CGSize(width: 560, height: 260), scheme: .dark, zoom: 1)
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
            try await SurfaceCapture.render("notch-camera-\(name)", variant: notch) {
                NotchRemoteCameraTab(model: client).background(.black)
            }
            client.stop()
        }
    }
}
