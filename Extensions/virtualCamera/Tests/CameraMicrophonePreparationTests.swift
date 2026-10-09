import AVFoundation
import Foundation
import Testing
@testable import VirtualCameraExtension

@Suite(.serialized) @MainActor struct CameraMicrophonePreparationTests {
    @Test func deniedPreparationCannotEnableAudioAndRemainsRetryable() async throws {
        var attempts = 0
        let engine = makeEngine {
            attempts += 1
            throw CocoaError(.fileWriteNoPermission)
        }
        for _ in 0..<2 {
            await #expect(throws: (any Error).self) {
                try await engine.performRecording(.audio(.enable(true)))
            }
        }
        #expect(attempts == 2)
        #expect(!engine.snapshot().state.audio.enabled)
        #expect(engine.snapshot().audioStatus?.running == false)
        await engine.finishShutdown()
    }

    @Test func restoredAudioWaitsForPreparationAndPublishesItsFailure() async throws {
        var attempts = 0
        var state = VirtualCameraState(privacy: .stopped)
        state.audio.enabled = true
        let engine = makeEngine(state: state) {
            attempts += 1
            throw CocoaError(.fileWriteNoPermission)
        }
        engine.start()
        try await wait { engine.snapshot().audioStatus?.failure != nil }
        #expect(attempts == 1)
        #expect(engine.snapshot().audioStatus?.running == false)
        #expect(engine.snapshot().state.audio.enabled)
        await engine.finishShutdown()
    }

    @Test func shutdownAwaitsCancelledPreparationAndRejectsLateEnable() async throws {
        var continuation: CheckedContinuation<Void, Error>?
        var entered = false
        let engine = makeEngine {
            entered = true
            try await withCheckedThrowingContinuation { continuation = $0 }
        }
        let command = Task { try await engine.performRecording(.audio(.enable(true))) }
        try await wait { entered }
        var stopped = false
        let shutdown = Task {
            await engine.finishShutdown(); stopped = true
        }
        try await wait { engine.isStopped }
        #expect(!stopped)
        continuation?.resume(); continuation = nil
        await #expect(throws: (any Error).self) { try await command.value }
        await shutdown.value
        #expect(stopped)
        #expect(!engine.snapshot().state.audio.enabled)
        #expect(engine.snapshot().audioStatus?.running == false)
    }

    private func makeEngine(
        state: VirtualCameraState = VirtualCameraState(privacy: .stopped),
        prepare: @escaping @MainActor () async throws -> Void
    ) -> VirtualCameraEngine {
        VirtualCameraEngine(
            edithSink: VirtualCameraSink(deviceUID: "synthetic-missing-camera"),
            obsSink: VirtualCameraSink(deviceUID: "synthetic-missing-obs"), state: state,
            environment: .init(
                authorization: { .denied }, obsRunning: { false },
                frontmostApplication: { nil }, sources: { [] }, prepareMicrophone: prepare))
    }
    private func wait(_ predicate: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !predicate() {
            guard ContinuousClock.now < deadline else { throw CocoaError(.fileReadUnknown) }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}
