import EdithExtensionSupport
import Foundation
import Testing

@testable import ClipboardExtension

@Suite(.serialized) struct ClipboardCaptureGateTests {
    @MainActor @Test func runningStoreCapturesWithoutSeparateSwitchAndKeepsPollingWhilePaused()
        async throws
    {
        let defaults = SharedDefaults.store
        let previousEnabled = defaults.object(forKey: AppStorageKeys.Clipboard.enabled)
        let previousPaused = defaults.object(forKey: AppStorageKeys.Clipboard.capturePaused)
        defer {
            defaults.set(previousEnabled, forKey: AppStorageKeys.Clipboard.enabled)
            defaults.set(previousPaused, forKey: AppStorageKeys.Clipboard.capturePaused)
        }
        defaults.removeObject(forKey: AppStorageKeys.Clipboard.enabled)
        defaults.set(true, forKey: AppStorageKeys.Clipboard.capturePaused)
        let store = ClipboardStore(
            client: .init(send: { _, _ in Data("[]".utf8) }), capturesPasteboard: true)
        defer { store.shutdown() }
        #expect(store.isCapturing)
    }
}
