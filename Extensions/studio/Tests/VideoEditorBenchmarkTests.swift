import EdithExtensionUI
import EdithExtensionSupport
import AVFoundation
import Darwin
import Foundation
import Testing
@testable import StudioExtension

@Suite @MainActor struct VideoEditorBenchmarkTests {
    private func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15
    }

    private func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
    }

    private func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    private func waitUntil(_ ready: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while !ready(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        try #require(ready())
    }

    @Test(
        .enabled(if: ProcessInfo.processInfo.environment["EDITH_EDITOR_BENCHMARK_PROJECT"] != nil))
    func nativePlaybackAndScrubbing() async throws {
        let environment = ProcessInfo.processInfo.environment
        let projectURL = URL(
            fileURLWithPath: try #require(environment["EDITH_EDITOR_BENCHMARK_PROJECT"]))
        let outputURL = URL(
            fileURLWithPath: try #require(environment["EDITH_EDITOR_BENCHMARK_OUTPUT"]))
        let dimension = Int(environment["EDITH_EDITOR_BENCHMARK_DIMENSION"] ?? "1280") ?? 1280
        let project = try VideoProject.open(projectURL)
        let model = VideoEditorModel {
            try await VideoRenderPipeline.make(
                project: $0, maxDimension: dimension, previewOnly: true)
        }
        defer { model.close() }
        let buildStart = ContinuousClock.now
        model.project = project
        model.rebuild()
        try await waitUntil { model.player.currentItem?.status == .readyToPlay }
        let buildMS = milliseconds(buildStart.duration(to: .now))
        let item = try #require(model.player.currentItem)
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        item.add(output)
        var latencies: [Double] = []
        for index in 0..<20 {
            let target = model.duration * Double((index * 7) % 20) / 20
            let start = ContinuousClock.now
            model.seek(to: target)
            try await waitUntil {
                abs(model.player.currentTime().seconds - target) < project.frameDuration.seconds
                    && output.copyPixelBuffer(
                        forItemTime: model.player.currentTime(), itemTimeForDisplay: nil) != nil
            }
            latencies.append(milliseconds(start.duration(to: .now)))
        }
        model.seek(to: 0)
        try await waitUntil { model.player.currentTime().seconds < 0.02 }
        model.player.play()
        try await Task.sleep(for: .seconds(1))
        let playStart = model.player.currentTime().seconds
        let cpuStart = cpuSeconds()
        let start = ContinuousClock.now
        var frames = Set<Double>()
        var maximumFootprint = footprint()
        while start.duration(to: .now) < .seconds(8) {
            let time = model.player.currentTime()
            if output.hasNewPixelBuffer(forItemTime: time) {
                var displayed = CMTime.zero
                if output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: &displayed) != nil
                {
                    frames.insert(displayed.seconds)
                }
            }
            maximumFootprint = max(maximumFootprint, footprint())
            try await Task.sleep(for: .milliseconds(4))
        }
        model.player.pause()
        let wallSeconds = milliseconds(start.duration(to: .now)) / 1000
        let cpu = cpuSeconds() - cpuStart
        let advanced = model.player.currentTime().seconds - playStart
        #expect(advanced > 6)
        #expect(frames.count > 100)
        let sorted = latencies.sorted()
        let access = item.accessLog()?.events.last
        let result: [String: Any] = [
            "synthetic": true,
            "clips": project.clips.count,
            "projectCanvas": [project.videoSettings.width, project.videoSettings.height],
            "previewCanvas": [
                Int(model.pipeline?.canvas.width ?? 0), Int(model.pipeline?.canvas.height ?? 0),
            ],
            "buildMilliseconds": buildMS,
            "scrubMedianMilliseconds": sorted[sorted.count / 2],
            "scrubP95Milliseconds": sorted[Int(Double(sorted.count - 1) * 0.95)],
            "playbackWallSeconds": wallSeconds,
            "playbackAdvancedSeconds": advanced,
            "observedRenderedFrames": frames.count,
            "observedFramesPerSecond": Double(frames.count) / wallSeconds,
            "cpuSeconds": cpu,
            "cpuPercentOfOneCore": cpu / wallSeconds * 100,
            "peakProcessFootprintBytes": maximumFootprint,
            "reportedDroppedFrames": access.map { $0.numberOfDroppedVideoFrames as Any }
                ?? NSNull(),
            "measurementScope":
                "Native AVPlayer video-output decoding and composition, process CPU and physical footprint; excludes UI presentation and GPU counters.",
        ]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            .write(to: outputURL, options: .atomic)
        print(String(data: try Data(contentsOf: outputURL), encoding: .utf8) ?? "")
    }
}
