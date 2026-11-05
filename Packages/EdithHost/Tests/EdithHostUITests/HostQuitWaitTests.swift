import AppKit
import SwiftUI
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

    private func render(
        _ model: HostQuitWaitModel, name: String, scheme: ColorScheme
    ) async throws -> CGSize {
        _ = TestWindowHost.application
        let host = NSHostingView(
            rootView: HostQuitWaitView(model: model)
                .environment(\.colorScheme, scheme)
                .environment(\.controlActiveState, .key)
                .transaction { $0.animation = nil })
        host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        let size = host.fittingSize
        host.frame = CGRect(origin: .zero, size: size)
        let window = TestWindowHost.window(contentRect: host.frame)
        window.appearance = host.appearance
        window.contentView = host
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        for _ in 0..<6 {
            window.layoutIfNeeded(); host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(30))
        }
        if let directory = ProcessInfo.processInfo.environment["EDITH_TEST_CAPTURE_SURFACES"] {
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let folder = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            try data.write(
                to: folder.appendingPathComponent(
                    "quit-\(name)-\(scheme == .dark ? "dark" : "light").png"), options: .atomic)
        }
        return size
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
        let probe = Probe([
            ["Screen Recorder"], ["Screen Recorder"], ["Screen Recorder", "Studio"], [],
        ])
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

    @Test func finishedToolsAreCountedAsWorkEnds() {
        let model = HostQuitWaitModel(blockers: ["Downloads"])
        #expect(model.progress == nil)
        model.blockers = ["Downloads", "Studio", "Screen Recorder"]
        #expect(model.progress == "0 of 3 done")
        model.blockers = ["Studio"]
        #expect(model.progress == "2 of 3 done")
        #expect(Set(model.finished) == ["Downloads", "Screen Recorder"])
        model.blockers = ["Studio", "Downloads"]
        #expect(model.finished == ["Screen Recorder"])
        #expect(model.progress == "1 of 3 done")
    }

    @Test func messageAgreesWithHowManyToolsAreStillWorking() {
        #expect(
            HostQuitWaitModel(blockers: ["Studio"]).message
                == "Studio is still working. Edith quits on its own as soon as it finishes.")
        #expect(
            HostQuitWaitModel(blockers: ["Studio", "Downloads"]).message
                == "Studio and Downloads are still working. Edith quits on its own as soon as they finish."
        )
    }

    @Test func finishingBarSweepsAcrossAndClearsBothEdges() {
        let width: CGFloat = 100
        let sweep = width * HostQuitFinishingBar.sweep
        #expect(abs(HostQuitFinishingBar.offset(at: 0, width: width) + sweep) < 0.001)
        let end = HostQuitFinishingBar.offset(
            at: HostQuitFinishingBar.period - 0.0001, width: width)
        #expect(abs(end - width) < 0.1)
        let wrapped = HostQuitFinishingBar.offset(at: HostQuitFinishingBar.period, width: width)
        #expect(abs(wrapped + sweep) < 0.001)
    }

    @Test func waitPanelShowsWhatIsStillFinishing() async throws {
        let single = HostQuitWaitModel(blockers: ["Screen Recorder"])
        let several = HostQuitWaitModel(blockers: ["Downloads", "Studio", "Screen Recorder"])
        several.blockers = ["Studio", "Screen Recorder"]
        for (name, model) in [("single", single), ("several", several)] {
            for scheme in [ColorScheme.light, .dark] {
                let size = try await render(model, name: name, scheme: scheme)
                #expect(size.width == 400)
                #expect(size.height >= (name == "several" ? 260 : 200))
            }
        }
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
