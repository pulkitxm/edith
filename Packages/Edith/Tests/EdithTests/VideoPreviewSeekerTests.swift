import AVFoundation
import Testing
@testable import Edith

@Suite @MainActor struct VideoPreviewSeekerTests {
    private func waitUntil(_ ready: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !ready(), ContinuousClock.now < deadline { await Task.yield() }
        try #require(ready())
    }

    @Test func rapidScrubbingFinishesAtLatestExactTargetWithOneSeekInFlight() async throws {
        var issued: [CMTime] = []
        var completions: [@Sendable (Bool) -> Void] = []
        let seeker = VideoPreviewSeeker { time, completion in
            issued.append(time)
            completions.append(completion)
        }
        for frame in 0..<1000 {
            seeker.request(CMTime(value: Int64(frame), timescale: 60))
        }
        #expect(issued == [CMTime(value: 0, timescale: 60)])
        #expect(seeker.isSeeking)
        completions[0](true)
        try await waitUntil { issued.count == 2 }
        #expect(issued == [CMTime(value: 0, timescale: 60), CMTime(value: 999, timescale: 60)])
        completions[1](true)
        try await waitUntil { !seeker.isSeeking }
        #expect(issued.count == 2)
    }

    @Test func replacingPlaybackItemIgnoresOldCompletionsAndQueuedTargets() async throws {
        var issued: [CMTime] = []
        var completions: [@Sendable (Bool) -> Void] = []
        let seeker = VideoPreviewSeeker { time, completion in
            issued.append(time)
            completions.append(completion)
        }
        seeker.request(CMTime(value: 10, timescale: 60))
        seeker.request(CMTime(value: 20, timescale: 60))
        seeker.reset()
        seeker.request(CMTime(value: 30, timescale: 60))
        seeker.request(CMTime(value: 40, timescale: 60))
        completions[0](false)
        await Task.yield()
        #expect(issued.count == 2)
        #expect(seeker.isSeeking)
        completions[1](true)
        try await waitUntil { issued.count == 3 }
        #expect(issued.map(\.value) == [10, 30, 40])
        completions[2](true)
        try await waitUntil { !seeker.isSeeking }
    }
}
