import AppKit
import Foundation
import Testing
@testable import VirtualCameraExtension

@MainActor private final class CameraThumbnailProbe {
    var continuation: CheckedContinuation<CGImage?, Never>?
    var entered = false
    func suspended() async -> CGImage? {
        entered = true
        return await withCheckedContinuation { continuation = $0 }
    }
}

@Suite(.serialized) @MainActor struct CameraPickerOwnershipTests {
    @Test func shutdownWaitsForOwnedThumbnailCallbackAndRejectsLateImages() async throws {
        let loader = TimeLapseThumbnailLoader()
        let probe = CameraThumbnailProbe()
        let load = Task { await loader.load { await probe.suspended() } }
        for _ in 0..<1000 {
            if probe.entered { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(probe.entered)
        var drained = false
        let stop = Task {
            await loader.shutdown(); drained = true
        }
        try await Task.sleep(for: .milliseconds(5))
        #expect(!drained)
        probe.continuation?.resume(returning: nil); probe.continuation = nil
        await stop.value
        #expect(drained)
        #expect(await load.value == nil)
        #expect(
            await loader.load {
                Issue.record("A stopped picker must not issue screenshot work"); return nil
            } == nil)
    }
    @Test func catalogShutdownIsAwaitableAndIdempotent() async {
        let catalog = ScreenCaptureSourceCatalog()
        await catalog.shutdown(); await catalog.shutdown()
        await catalog.refreshCaptureSources()
        #expect(catalog.displays.isEmpty && catalog.windows.isEmpty)
        #expect(!catalog.sourceLoad.isRunning)
        #expect(await catalog.sourceThumbnail(mode: "windows", id: 1) == nil)
        await ScreenCaptureSourceCatalog.shutdownAll()
    }
}
