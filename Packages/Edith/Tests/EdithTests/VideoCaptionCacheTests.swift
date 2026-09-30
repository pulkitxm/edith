import AVFoundation
import CoreImage
import Darwin
import Foundation
import Testing
@testable import Edith

@Suite struct VideoCaptionCacheTests {
    @Test func cacheBoundsConcurrencyAndStyleReload() async throws {
        var project = VideoProject.create(title: "Synthetic cache isolation")
        for index in 0..<47 { project.addText("SYNTHETIC \(index)", startMs: 0, endMs: 1000) }
        for caption in project.annotations {
            try project.setCaptionStyle(caption.id, style: VideoCaptionStyleTests.styled)
        }
        let cache = VideoCaptionRasterCache(annotations: project.annotations)
        let id = project.annotations[0].id
        let size = CGSize(width: 2160, height: 3840)
        try await withThrowingTaskGroup(of: ObjectIdentifier.self) { group in
            for _ in 0..<16 {
                group.addTask { ObjectIdentifier(try #require(cache.image(for: id, size: size))) }
            }
            var identities = Set<ObjectIdentifier>()
            for try await identity in group { identities.insert(identity) }
            #expect(identities.count == 1)
        }
        #expect(cache.statistics.misses == 1 && cache.statistics.hits == 15)
        for caption in project.annotations {
            _ = try #require(cache.image(for: caption.id, size: size))
            #expect(cache.statistics.entries <= 2)
            #expect(cache.statistics.bytes <= VideoCaptionRasterCache.maximumBytes)
        }
        let small = try #require(cache.image(for: id, size: CGSize(width: 540, height: 960)))
        #expect(small.extent.width == 540)
        var changed = VideoCaptionStyleTests.styled
        changed.fill = .init(green: 1)
        try project.setCaptionStyle(id, style: changed)
        let reloaded = VideoCaptionRasterCache(annotations: project.annotations)
        let green = try #require(reloaded.image(for: id, size: CGSize(width: 540, height: 960)))
        #expect(VideoCaptionStyleTests.pixels(small) != VideoCaptionStyleTests.pixels(green))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["EDITH_CAPTION_BENCHMARK"] == "1"))
    func native4K47CaptionExportAndNextPreview() async throws {
        let (directory, _, initial) = try await VideoOutputCaptionTests.fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        var project = initial
        let source = try #require(project.assets.first)
        project.addAsset(source.url, duration: 1, width: 64, height: 64)
        var settings = project.videoSettings
        settings.width = 2160
        settings.height = 3840
        settings.frameRateNumerator = 60
        settings.frameRateDenominator = 1
        project.videoSettings = settings
        let rate = try VideoCaptionFrameRate(numerator: 60)
        for index in 0..<47 {
            try project.addOutputCaption(
                "SYNTHETIC \(index + 1)\nCAPTION",
                anchor: VideoCaptionAnchor(
                    start: .init(frame: Int64(index * 3), frameRate: rate),
                    end: .init(frame: Int64(index * 3 + 3), frameRate: rate)),
                style: VideoCaptionStyleTests.styled)
        }
        let pipeline = try await VideoRenderPipeline.make(project: project)
        let started = Date.timeIntervalSinceReferenceDate
        let report = try await pipeline.export(
            to: directory.appendingPathComponent("synthetic-47.mp4"))
        #expect(report.frameCount == 150)
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let stats = try #require(pipeline.captionRasterCache?.statistics)
        #expect(
            stats.misses == 47 && stats.hits > 0 && stats.entries <= 2
                && stats.bytes <= VideoCaptionRasterCache.maximumBytes)
        print(
            "caption native 4K export: \(pipeline.duration)s, 47 captions; wall \(Date.timeIntervalSinceReferenceDate - started)s; misses \(stats.misses), hits \(stats.hits); retained \(stats.bytes) bytes; peak RSS \(usage.ru_maxrss) bytes"
        )
        var style = VideoCaptionStyleTests.styled
        style.fill = .init(green: 1)
        try project.setCaptionStyle(project.annotations[0].id, style: style)
        let next = try await VideoRenderPipeline.make(
            project: project, maxDimension: 960, previewOnly: true)
        let generator = AVAssetImageGenerator(asset: next.composition)
        generator.videoComposition = next.videoComposition
        let frame = try await generator.image(at: .zero).image
        #expect(VideoOutputCaptionTests.greenPixels(frame) > 50)
        #expect(next.captionRasterCache !== pipeline.captionRasterCache)
    }
}
