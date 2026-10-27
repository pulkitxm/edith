import AppKit
import Foundation
import Testing

@testable import ColorPickerExtension

@MainActor @Suite(.serialized) struct ColorPickerStopTests {
    @Test func stoppingWhileTheSamplerIsStillOpenDoesNotWaitForTheUser() async {
        let store = ColorPickerStore()
        store.showSampler = { _ in }
        store.pick()
        var stopped = false
        Task { @MainActor in
            await store.stopAndWait()
            stopped = true
        }
        for _ in 0..<200 where !stopped { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(stopped)
    }
}
