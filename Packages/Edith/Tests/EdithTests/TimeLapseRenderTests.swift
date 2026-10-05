import AppKit
import EdithCore
import EdithKit
import SwiftUI
import Testing

@testable import Edith

@Suite(.serialized) struct TimeLapseRenderTests {
    @Test @MainActor func rendersSyntheticCaptureControlsAndExportLibrary() async throws {
        guard #available(macOS 15.0, *) else { return }
        _ = TestWindowHost.application
        let recorder = TimeLapseRecorder()
        recorder.sourceMode = "windows"
        recorder.windows = [
            .init(id: 1, application: "Demo Editor", title: "Sample project"),
            .init(id: 2, application: "Demo Browser", title: "Sample dashboard"),
        ]
        recorder.selectedWindows = [1, 2]
        recorder.displays = [.init(id: 1, width: 3840, height: 2160)]
        recorder.microphones = [.init(id: "demo-microphone", name: "Demo microphone")]
        var session = TimeLapseSession(settings: TimeLapseSettings(), width: 3840, height: 2160)
        session.segments = [
            .init(
                file: "video-000000.mov", kind: "video", frames: 3600,
                startedAt: Date(timeIntervalSince1970: 1_700_000_000), duration: 120)
        ]
        session.endedAt = session.startedAt
        let recording = TimeLapseRecording(
            session: session,
            directory: FileManager.default.temporaryDirectory.appendingPathComponent(
                "demo-recording"))
        SharedDefaults.store.set(true, forKey: AppStorageKeys.Tabs.timeLapseEnabled)
        defer { SharedDefaults.store.removeObject(forKey: AppStorageKeys.Tabs.timeLapseEnabled) }
        let host = NSHostingView(
            rootView: TimeLapseControls(
                recorder: recorder,
                recordings: [recording], loadsSources: false
            ).environment(\.colorScheme, .light)
                .frame(width: 1000, height: 980)
                .background(Color.white))
        host.frame = CGRect(x: 0, y: 0, width: 1000, height: 980)
        let window = TestWindowHost.window(contentRect: host.frame)
        window.contentView = host
        window.orderBack(nil)
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        #expect(recorder.windows.map(\.id) == [1, 2])
        #expect(!recorder.busy)
        host.displayIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        #expect(png.count > 10000)
        if let path = ProcessInfo.processInfo.environment["EDITH_TIMELAPSE_EVIDENCE_DIR"] {
            let directory = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            try png.write(to: directory.appendingPathComponent("time-lapse-controls.png"))
        }
        window.orderOut(nil)
    }
}
