import AppKit
import Testing

@testable import EdithHost

@MainActor @Suite(.serialized) struct HostQuitWaitTests {
    @MainActor private final class Probe {
        var blockers: [[String]]
        var reads = 0
        var presented: HostQuitWaitModel?
        var dismissed = 0
        var terminated = 0
        var concealed = 0
        var shown = 0
        init(_ blockers: [[String]]) { self.blockers = blockers }

        func next() -> [String] {
            defer { reads += 1 }
            return blockers[min(reads, blockers.count - 1)]
        }
    }

    private func delegate(_ probe: Probe) -> HostApplicationDelegate {
        let delegate = HostApplicationDelegate()
        delegate.launchesRuntime = false
        delegate.shutdown = {}
        delegate.quitPollInterval = .milliseconds(1)
        delegate.quitBlockers = { probe.next() }
        delegate.presentQuitWait = { model in
            probe.presented = model
            return { probe.dismissed += 1 }
        }
        delegate.terminate = { probe.terminated += 1 }
        delegate.conceal = { probe.concealed += 1 }
        delegate.activate = {}
        delegate.mainWindow = { nil }
        delegate.openMainWindow = { probe.shown += 1 }
        return delegate
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<500 where !condition() { try? await Task.sleep(for: .milliseconds(2)) }
    }

    @Test func quittingWithNothingRunningTerminatesWithoutShowingAnything() async {
        let probe = Probe([[]])
        let delegate = delegate(probe)
        #expect(delegate.applicationShouldTerminate(NSApp) == .terminateCancel)
        await waitUntil { probe.terminated == 1 }
        #expect(probe.terminated == 1)
        #expect(probe.presented == nil && probe.concealed == 0)
    }

    @Test func quittingWhileWorkRunsShowsWhatItWaitsForAndQuitsWhenDone() async {
        let probe = Probe([["Screen Recorder"], ["Screen Recorder"], ["Screen Recorder", "Studio"], []])
        let delegate = delegate(probe)
        #expect(delegate.applicationShouldTerminate(NSApp) == .terminateCancel)
        await waitUntil { probe.presented != nil }
        #expect(probe.presented?.blockers == ["Screen Recorder"])
        #expect(probe.concealed == 1)
        #expect(delegate.applicationShouldTerminate(NSApp) == .terminateCancel)
        await waitUntil { probe.terminated == 1 }
        #expect(probe.terminated == 1 && probe.dismissed == 1)
        #expect(probe.presented?.blockers == ["Screen Recorder", "Studio"])
    }

    @Test func keepOpenCancelsTheQuitAndBringsTheWindowBack() async {
        let probe = Probe([["Downloads"]])
        let delegate = delegate(probe)
        _ = delegate.applicationShouldTerminate(NSApp)
        await waitUntil { probe.presented != nil }
        probe.presented?.keepOpen()
        await waitUntil { probe.dismissed == 1 }
        await waitUntil { probe.shown == 1 }
        #expect(probe.terminated == 0 && probe.shown == 1)
    }

    @Test func quitNowSkipsTheWait() async {
        let probe = Probe([["Downloads"]])
        let delegate = delegate(probe)
        _ = delegate.applicationShouldTerminate(NSApp)
        await waitUntil { probe.presented != nil }
        probe.presented?.quitNow()
        await waitUntil { probe.terminated == 1 }
        #expect(probe.terminated == 1 && probe.dismissed == 1 && probe.shown == 0)
    }
}
