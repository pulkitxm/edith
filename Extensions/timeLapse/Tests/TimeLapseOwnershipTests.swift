import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import Testing

@testable import TimeLapseExtension

@MainActor
@Suite(.serialized) struct TimeLapseOwnershipTests {
    @Test func newerSourceDiscoveryRejectsLateResults() async {
        guard #available(macOS 15.0, *) else { return }
        let recorder = TimeLapseRecorder()
        let gate = TimeLapseRequestGate()
        let old = Task {
            await recorder.loadSources {
                await gate.wait()
                return (Self.sources("Old window"), [])
            }
        }
        await gate.started()
        await recorder.loadSources { (Self.sources("Current window"), []) }
        await gate.release()
        await old.value
        #expect(recorder.windows.map(\.title) == ["Current window"])
        #expect(recorder.sourceRevision == 1)
        #expect(recorder.sourceLoad.state == .content)
    }

    @Test func cancelledDiscoveryDoesNotPublishAndCanRetry() async {
        guard #available(macOS 15.0, *) else { return }
        let recorder = TimeLapseRecorder()
        let gate = TimeLapseRequestGate()
        let request = Task {
            await recorder.loadSources {
                await gate.wait()
                return (Self.sources("Cancelled window"), [])
            }
        }
        await gate.started()
        request.cancel()
        await gate.release()
        await request.value
        #expect(recorder.windows.isEmpty)
        #expect(recorder.sourceLoad.state == .cancelled)
        #expect(!recorder.sourceLoad.isRunning)
        await recorder.loadSources { (Self.sources("Recovered window"), []) }
        #expect(recorder.windows.map(\.title) == ["Recovered window"])
    }

    @Test func sourceRefreshFailureRetainsSelectionAndExposesRecovery() async {
        guard #available(macOS 15.0, *) else { return }
        let recorder = TimeLapseRecorder()
        await recorder.loadSources { (Self.sources("Available window"), []) }
        recorder.selectedWindows = [1]
        await recorder.loadSources { throw URLError(.notConnectedToInternet) }
        #expect(recorder.windows.map(\.title) == ["Available window"])
        #expect(recorder.selectedWindows == [1])
        #expect(recorder.sourceLoad.state == .content)
        #expect(recorder.sourceLoad.errorMessage != nil)
        #expect(recorder.sourceRevision == 1)
    }

    @Test func previewVisibilityBelongsToEachWindow() {
        guard #available(macOS 15.0, *) else { return }
        let recorder = TimeLapseRecorder()
        let first = UUID()
        let second = UUID()
        recorder.showPreview(true, consumer: first)
        recorder.showPreview(true, consumer: second)
        recorder.showPreview(false, consumer: first)
        #expect(recorder.previewVisible)
        recorder.showPreview(false, consumer: second)
        #expect(!recorder.previewVisible)
        recorder.showPreview(true, consumer: second)
        #expect(recorder.previewVisible)
    }

    @Test func cancelledLibraryRefreshRetainsRecordings() async {
        guard #available(macOS 15.0, *) else { return }
        let recording = Self.recording()
        let gate = TimeLapseRequestGate()
        let model = TimeLapseLibraryModel(
            recordings: [recording],
            read: { _ in
                await gate.wait()
                return []
            })
        let request = Task { await model.refresh() }
        await gate.started()
        request.cancel()
        await gate.release()
        await request.value
        #expect(model.recordings.map(\.id) == [recording.id])
        #expect(model.loading.state == .content)
        #expect(!model.loading.isRunning)
    }

    @Test func libraryRefreshExcludesTheActiveSessionAndRetainsFailureContent() async {
        guard #available(macOS 15.0, *) else { return }
        let recording = Self.recording()
        let model = TimeLapseLibraryModel(read: { _ in [recording] })
        await model.refresh(excluding: recording.directory)
        #expect(model.recordings.isEmpty)
        #expect(model.loading.state == .content)
        await model.refresh()
        #expect(model.recordings.map(\.id) == [recording.id])
        let failing = TimeLapseLibraryModel(
            recordings: [recording],
            read: { _ in
                throw URLError(.cannotOpenFile)
            })
        await failing.refresh()
        #expect(failing.recordings.map(\.id) == [recording.id])
        #expect(failing.loading.errorMessage != nil)
        #expect(failing.loading.state == .content)
    }

    @Test func exportOutlivesItsCallerAndRejectsDuplicateStarts() async {
        guard #available(macOS 15.0, *) else { return }
        let gate = TimeLapseRequestGate()
        let model = TimeLapseLibraryModel(write: { _, _, _ in await gate.wait() })
        let destination = URL(fileURLWithPath: "/synthetic/recording.mp4")
        let caller = Task { model.export(Self.recording(), quality: .high, to: destination) }
        await caller.value
        await gate.started()
        model.export(Self.recording(), quality: .high, to: destination)
        #expect(model.exporting)
        #expect(await gate.calls == 1)
        await gate.release()
        await model.finishExport()
        #expect(!model.exporting)
        #expect(model.message == "Saved recording.mp4.")
    }

    @Test func exportCancellationAndFailureAllowRecovery() async {
        guard #available(macOS 15.0, *) else { return }
        let gate = TimeLapseRequestGate()
        let model = TimeLapseLibraryModel(write: { _, _, _ in await gate.wait() })
        let destination = URL(fileURLWithPath: "/synthetic/recording.mp4")
        model.export(Self.recording(), quality: .high, to: destination)
        await gate.started()
        model.cancelExport()
        await gate.release()
        await model.finishExport()
        #expect(!model.exporting)
        #expect(model.message == "Export cancelled.")
        let failing = TimeLapseLibraryModel(write: { _, _, _ in throw TimeLapseError.empty })
        failing.export(Self.recording(), quality: .high, to: destination)
        await failing.finishExport()
        #expect(!failing.exporting)
        #expect(failing.message == TimeLapseError.empty.localizedDescription)
        failing.export(Self.recording(), quality: .high, to: destination)
        await failing.finishExport()
        #expect(!failing.exporting)
    }

    @Test func disablingRejectsLateDiscoveryAndNewPreviewConsumers() async {
        guard #available(macOS 15.0, *) else { return }
        let recorder = TimeLapseRecorder()
        let gate = TimeLapseRequestGate()
        let discovery = Task {
            await recorder.loadSources {
                await gate.wait()
                return (Self.sources("Late fixture"), [])
            }
        }
        await gate.started()
        await recorder.shutdown()
        await gate.release()
        await discovery.value
        await recorder.loadSources {
            Issue.record("A disabled recorder must not discover sources.")
            return (Self.sources("Disabled"), [])
        }
        recorder.showPreview(true, consumer: UUID())
        #expect(recorder.windows.isEmpty)
        #expect(!recorder.previewVisible)
        #expect(!recorder.canStart)
        #expect(!recorder.sourceLoad.isRunning)
    }

    @Test func disablingLibraryRejectsLateReadsAndCancelsOwnedExports() async {
        guard #available(macOS 15.0, *) else { return }
        let readGate = TimeLapseRequestGate()
        let model = TimeLapseLibraryModel(read: { _ in
            await readGate.wait()
            return [Self.recording()]
        })
        let refresh = Task { await model.refresh() }
        await readGate.started()
        await model.shutdown()
        await readGate.release()
        await refresh.value
        #expect(model.recordings.isEmpty)
        #expect(!model.loading.isRunning)
        let exportGate = TimeLapseRequestGate()
        let exporting = TimeLapseLibraryModel(write: { _, _, _ in await exportGate.wait() })
        exporting.export(
            Self.recording(), quality: .high, to: URL(fileURLWithPath: "/synthetic/result.mp4"))
        await exportGate.started()
        let shutdown = Task { await exporting.shutdown() }
        await Task.yield()
        await exportGate.release()
        await shutdown.value
        #expect(!exporting.exporting)
        #expect(exporting.message == nil)
        exporting.export(
            Self.recording(), quality: .high, to: URL(fileURLWithPath: "/synthetic/disabled.mp4"))
        #expect(await exportGate.calls == 1)
    }

    nonisolated private static func sources(_ title: String) -> TimeLapseSources {
        TimeLapseSources(
            displays: [], windows: [], displayChoices: [],
            windowChoices: [.init(id: 1, application: "Sample app", title: title)])
    }

    nonisolated private static func recording() -> TimeLapseRecording {
        .init(
            session: TimeLapseSession(settings: TimeLapseSettings(), width: 64, height: 64),
            directory: URL(fileURLWithPath: "/synthetic/session"))
    }
}

private actor TimeLapseRequestGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private let signal = AsyncStream<Void>.makeStream()
    private(set) var calls = 0

    func wait() async {
        calls += 1
        await withCheckedContinuation {
            continuation = $0
            signal.continuation.yield(())
        }
    }

    func started() async {
        var iterator = signal.stream.makeAsyncIterator()
        _ = await iterator.next()
    }

    func release() { continuation?.resume(); continuation = nil }
}
