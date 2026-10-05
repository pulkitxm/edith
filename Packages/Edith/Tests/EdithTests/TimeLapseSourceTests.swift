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

    @Test func selectionPreservesEachSourceTypeAndEnforcesTheLimit() {
        var selection = TimeLapseSourceSelection(
            mode: "windows", displays: [99], windows: [], systemAudio: false)
        for id in UInt32(1)...20 { selection.toggle(id) }
        #expect(selection.windows == Set(UInt32(1)...16))
        selection.toggle(5)
        selection.toggle(20)
        #expect(selection.windows.count == 16)
        #expect(selection.windows.contains(20))
        #expect(!selection.windows.contains(5))
        selection.mode = "displays"
        #expect(selection.selected == [99])
        selection.toggle(100)
        #expect(selection.displays == [99, 100])
        #expect(selection.windows.count == 16)
    }

    @Test func refreshingSourcesRemovesMissingSelections() {
        var selection = TimeLapseSourceSelection(
            mode: "windows", displays: [1, 2], windows: [3, 4], systemAudio: true)
        selection.reconcile(displays: [2], windows: [4])
        #expect(selection.displays == [2])
        #expect(selection.windows == [4])
        selection.reconcile(displays: [], windows: [])
        #expect(selection.selected.isEmpty)
    }

    @Test @MainActor func draftChangesAreAppliedOnlyWhenConfirmed() {
        guard #available(macOS 15.0, *) else { return }
        let recorder = TimeLapseRecorder()
        recorder.selectedDisplays = [1]
        var selection = TimeLapseSourceSelection(
            mode: recorder.sourceMode, displays: recorder.selectedDisplays,
            windows: recorder.selectedWindows, systemAudio: recorder.settings.systemAudio)
        selection.mode = "windows"
        selection.toggle(7)
        selection.systemAudio = true
        #expect(recorder.sourceMode == "displays")
        #expect(recorder.selectedWindows.isEmpty)
        #expect(!recorder.settings.systemAudio)
        selection.apply(to: recorder)
        #expect(recorder.sourceMode == "windows")
        #expect(recorder.selectedDisplays == [1])
        #expect(recorder.selectedWindows == [7])
        #expect(recorder.settings.systemAudio)
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
