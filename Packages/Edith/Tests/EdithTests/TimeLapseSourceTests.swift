import AppKit
import Testing

@testable import Edith

@Suite struct TimeLapseSourceTests {
    @Test(arguments: [
        (CGSize(width: 3840, height: 2160), 320, 180),
        (CGSize(width: 1000, height: 2000), 90, 180),
        (CGSize(width: 120, height: 80), 120, 80),
        (CGSize.zero, 2, 2),
        (CGSize(width: Double.nan, height: 100), 2, 2),
    ])
    func thumbnailsPreserveAspectRatioWithinSmallBounds(
        size: CGSize, width: Int, height: Int
    ) {
        let result = TimeLapseSources.thumbnailSize(size)
        #expect(result.width == width)
        #expect(result.height == height)
    }

    @Test func thumbnailCapturesRunOneAtATime() async {
        let loader = TimeLapseThumbnailLoader()
        let probe = ThumbnailProbe()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    _ = await loader.load {
                        await probe.start()
                        try? await Task.sleep(for: .milliseconds(5))
                        await probe.finish()
                        return nil
                    }
                }
            }
        }
        #expect(await probe.calls == 20)
        #expect(await probe.maximumActive == 1)
    }

    @Test func canceledThumbnailRequestsDoNotCaptureAndQueueCanResume() async {
        let loader = TimeLapseThumbnailLoader()
        let probe = ThumbnailProbe()
        let started = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let first = Task {
            await loader.load {
                started.continuation.yield(())
                var iterator = release.stream.makeAsyncIterator()
                _ = await iterator.next()
                return nil
            }
        }
        var iterator = started.stream.makeAsyncIterator()
        _ = await iterator.next()
        let canceled = Task {
            await loader.load {
                await probe.start()
                return nil
            }
        }
        canceled.cancel()
        release.continuation.yield(())
        _ = await first.value
        _ = await canceled.value
        #expect(await probe.calls == 0)
        _ = await loader.load {
            await probe.start()
            return nil
        }
        #expect(await probe.calls == 1)
    }
}

private actor ThumbnailProbe {
    private(set) var calls = 0
    private(set) var maximumActive = 0
    private var active = 0

    func start() {
        calls += 1
        active += 1
        maximumActive = max(maximumActive, active)
    }

    func finish() { active -= 1 }
}
