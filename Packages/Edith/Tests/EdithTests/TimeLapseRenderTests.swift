import AppKit
import EdithCore
import EdithKit
import SwiftUI
import Testing

@testable import Edith

@Suite(.serialized) struct TimeLapseRenderTests {
    @Test(arguments: [1000.0, 560.0], ["ready", "recording", "finished", "waiting", "dark"])
    @MainActor
    func rendersSyntheticCaptureControlsAndExportLibrary(width: Double, state: String) async throws
    {
        guard #available(macOS 15.0, *) else { return }
        _ = TestWindowHost.application
        let recorder = TimeLapseRecorder()
        recorder.sourceMode = "windows"
        recorder.windows = [
            .init(id: 1, application: "Demo Editor", title: "Sample project"),
            .init(id: 2, application: "Demo Browser", title: "Sample dashboard"),
        ]
        recorder.selectedWindows = [1, 2]
        recorder.recording = state == "recording" || state == "waiting" || state == "dark"
        recorder.startedAt = Date().addingTimeInterval(-5400)
        recorder.frames = 1080
        recorder.bytes = 24_000_000
        if state == "recording" || state == "finished" || state == "dark" {
            recorder.preview = try preview()
        }
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
            ).environment(\.colorScheme, state == "dark" ? .dark : .light)
                .environment(\.compactLayout, width < 640)
                .frame(width: width, height: state == "finished" ? 1100 : 850)
                .background(state == "dark" ? Color(white: 0.1) : Color.white))
        host.frame = CGRect(x: 0, y: 0, width: width, height: state == "finished" ? 1100 : 850)
        let window = TestWindowHost.window(contentRect: host.frame)
        window.appearance = NSAppearance(named: state == "dark" ? .darkAqua : .aqua)
        host.appearance = window.appearance
        window.contentView = host
        window.orderBack(nil)
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(350))
        host.layoutSubtreeIfNeeded()
        #expect(recorder.windows.map(\.id) == [1, 2])
        #expect(!recorder.busy)
        host.displayIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        #expect(png.count > 10000)
        if recorder.preview != nil {
            var colored = 0
            for y in stride(from: 0, to: bitmap.pixelsHigh, by: 16) {
                for x in stride(from: 0, to: bitmap.pixelsWide, by: 16) {
                    if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                        color.blueComponent > 0.25,
                        color.blueComponent > color.redComponent * 1.5,
                        color.greenComponent > color.redComponent * 1.5
                    {
                        colored += 1
                    }
                }
            }
            #expect(colored > 40)
        }
        if let path = ProcessInfo.processInfo.environment["EDITH_TIMELAPSE_EVIDENCE_DIR"] {
            let directory = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            let name = "time-lapse-\(state)\(width < 640 ? "-narrow" : "").png"
            try png.write(to: directory.appendingPathComponent(name))
        }
        window.orderOut(nil)
    }

    @MainActor private func preview() throws -> CGImage {
        let context = try #require(
            CGContext(
                data: nil, width: 960, height: 540, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor(calibratedWhite: 0.08, alpha: 1).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 960, height: 540))
        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        defer { NSGraphicsContext.restoreGraphicsState() }
        for index in 0..<2 {
            let x = CGFloat(index) * 472 + 16
            context.setFillColor(NSColor(calibratedWhite: 0.16, alpha: 1).cgColor)
            context.fill(CGRect(x: x, y: 28, width: 456, height: 484))
            for (line, text) in [
                index == 0 ? "Sample project" : "Sample dashboard",
                index == 0 ? "Build completed" : "24 tasks completed",
                "Synthetic demonstration data",
            ].enumerated() {
                NSAttributedString(
                    string: text,
                    attributes: [
                        .font: NSFont.systemFont(
                            ofSize: line == 0 ? 24 : 16,
                            weight: line == 0 ? .semibold : .regular),
                        .foregroundColor: NSColor.white,
                    ]
                ).draw(at: CGPoint(x: x + 24, y: 434 - CGFloat(line) * 42))
            }
            for row in 0..<6 {
                context.setFillColor(
                    (index == 0 ? NSColor.systemTeal : NSColor.systemBlue)
                        .withAlphaComponent(0.4 + Double(row) / 12).cgColor)
                context.fill(
                    CGRect(
                        x: x + 24, y: 80 + CGFloat(row) * 34,
                        width: 120 + CGFloat((row + index) % 4) * 64, height: 12))
            }
        }
        return try #require(context.makeImage())
    }

}
