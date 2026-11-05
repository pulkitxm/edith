import AppKit
import EdithExtensionUI
import Foundation
import SwiftUI
import Testing
import Vision

@testable import TimeLapseExtension

@MainActor
enum TimeLapseCapture {
    struct Variant {
        let name: String
        let size: CGSize
        let dark: Bool
        let scale: Double

        static let matrix = [
            Variant(
                name: "regular-light", size: CGSize(width: 1100, height: 760), dark: false, scale: 1
            ),
            Variant(
                name: "regular-dark", size: CGSize(width: 1100, height: 760), dark: true, scale: 1),
            Variant(
                name: "compact-light", size: CGSize(width: 640, height: 700), dark: false, scale: 1),
            Variant(
                name: "compact-dark", size: CGSize(width: 640, height: 700), dark: true, scale: 1),
            Variant(
                name: "zoom-light", size: CGSize(width: 1100, height: 760), dark: false, scale: 1.6),
        ]

        static var all: [Variant] {
            ProcessInfo.processInfo.environment["EDITH_TEST_CAPTURE_SURFACES"] == nil
                ? matrix.filter { $0.name == "compact-light" } : matrix
        }
    }

    static var directory: URL? {
        ProcessInfo.processInfo.environment["EDITH_TEST_CAPTURE_SURFACES"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        }
    }

    nonisolated static func recognizedText(in image: CGImage) async throws -> String {
        try await Task.detached(priority: .utility) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            try VNImageRequestHandler(cgImage: image).perform([request])
            return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: "\n")
        }.value
    }

    static func render(
        _ name: String, variant: Variant, expecting labels: [String], view: some View
    ) async throws {
        let previous = UIScale.current
        UIScale.apply(variant.scale)
        defer { UIScale.apply(previous) }
        let compact = variant.size.width / variant.scale < 720
        let host = NSHostingView(
            rootView: AnyView(
                view
                    .environment(\.compactLayout, compact)
                    .environment(\.colorScheme, variant.dark ? .dark : .light)
                    .environment(\.automaticViewActionsEnabled, false)
                    .environment(\.windowVisible, false)
                    .environment(\.controlActiveState, .key)
                    .controlSize(UIScale.controlSize)
                    .transaction { $0.animation = nil }
                    .frame(width: variant.size.width, height: variant.size.height)))
        let window = TestWindowHost.window(contentRect: CGRect(origin: .zero, size: variant.size))
        window.appearance = NSAppearance(named: variant.dark ? .darkAqua : .aqua)
        window.contentView = host
        host.frame = CGRect(origin: .zero, size: variant.size)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(450))
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        #expect(!TestWindowHost.isExposedOnDesktop(window))
        if let directory {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(
                to: directory.appendingPathComponent("timelapse-\(name)-\(variant.name).png"))
        }
        window.contentView = nil
        let text = try await recognizedText(in: try #require(bitmap.cgImage))
        for label in labels {
            #expect(text.contains(label), "\(name) \(variant.name) is missing \(label)")
        }
    }
}

@MainActor @Suite(.serialized) struct TimeLapseCaptureTests {
    @Test func screenRecorderStatesRenderCleanlyAtEveryVariant() async throws {
        guard #available(macOS 15.0, *) else { return }
        try await captureEveryState()
    }

    private static func recording(
        mode: ScreenRecordingMode, seconds: Double, interrupted: Bool = false
    ) -> TimeLapseRecording {
        var settings = TimeLapseSettings()
        settings.mode = mode
        var session = TimeLapseSession(settings: settings, width: 1920, height: 1080)
        session.segments = [
            .init(
                file: "video.mp4", kind: "video", frames: Int(seconds * 30),
                startedAt: session.startedAt, duration: seconds)
        ]
        if !interrupted { session.endedAt = session.startedAt.addingTimeInterval(seconds) }
        return TimeLapseRecording(
            session: session,
            directory: URL(fileURLWithPath: "/synthetic/recordings/\(session.id.uuidString)"))
    }

    @available(macOS 15.0, *)
    private static func readyRecorder() -> TimeLapseRecorder {
        let recorder = TimeLapseRecorder()
        recorder.displays = [
            TimeLapseDisplayChoice(id: 1, width: 5120, height: 2880)
        ]
        recorder.selectedDisplays = [1]
        recorder.sourceLoad.setContent()
        return recorder
    }

    @available(macOS 15.0, *)
    private func captureEveryState() async throws {
        let recordings = [
            Self.recording(mode: .timeLapse, seconds: 42),
            Self.recording(mode: .standard, seconds: 754),
            Self.recording(mode: .standard, seconds: 12, interrupted: true),
        ]
        for variant in TimeLapseCapture.Variant.all {
            let denied = TimeLapseRecorder()
            let request = denied.sourceLoad.begin()
            denied.sourceLoad.fail(
                request, message: TimeLapseError.screenRecordingDenied.errorDescription ?? "")
            #expect(denied.screenRecordingDenied)
            try await TimeLapseCapture.render(
                "permission", variant: variant,
                expecting: ["Allow Screen Recording", "Open System Settings"],
                view: TimeLapseControls(recorder: denied, recordings: [], loadsSources: true))

            let loading = TimeLapseRecorder()
            _ = loading.sourceLoad.begin()
            try await TimeLapseCapture.render(
                "loading", variant: variant, expecting: ["Source", "Looking for displays"],
                view: TimeLapseControls(recorder: loading, recordings: [], loadsSources: true))

            let empty = Self.readyRecorder()
            #expect(empty.canStart)
            try await TimeLapseCapture.render(
                "empty", variant: variant, expecting: ["Frame rate", "Record"],
                view: TimeLapseControls(recorder: empty, recordings: [], loadsSources: false))

            let populated = Self.readyRecorder()
            populated.settings.mode = .timeLapse
            try await TimeLapseCapture.render(
                "populated", variant: variant, expecting: ["Time-lapse speed", "Record"],
                view: TimeLapseControls(
                    recorder: populated, recordings: recordings, loadsSources: false))

            let active = Self.readyRecorder()
            active.recording = true
            active.startedAt = Date()
            active.frames = 1_240
            active.bytes = 48_200_000
            active.playbackSeconds = 41
            try await TimeLapseCapture.render(
                "recording", variant: variant, expecting: ["Stop recording", "Elapsed"],
                view: TimeLapseControls(
                    recorder: active, recordings: recordings, loadsSources: false))

            let disabled = Self.readyRecorder()
            try await TimeLapseCapture.render(
                "disabled", variant: variant, expecting: ["Screen Recorder is turned off"],
                view: TimeLapseControls(
                    recorder: disabled, recordings: [], loadsSources: false, enabled: false))
        }
    }
}
