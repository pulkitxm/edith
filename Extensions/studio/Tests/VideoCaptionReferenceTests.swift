import EdithExtensionUI
import EdithExtensionSupport
import CoreImage
import Darwin
import Foundation
import Testing
@testable import StudioExtension

@Suite struct VideoCaptionReferenceTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["EDITH_CAPTION_BENCHMARK"] == "1"))
    func repeated4KCaptionRasterBenchmark() throws {
        var project = VideoProject.create(title: "Synthetic raster benchmark")
        for index in 0..<47 {
            project.addText("SYNTHETIC \(index + 1)\nCAPTION", startMs: 0, endMs: 1000)
        }
        var style = VideoCaptionStyleTests.styled
        style.metrics = .fontBounds
        let context = CIContext(options: [.cacheIntermediates: false])
        let size = CGSize(width: 2160, height: 3840)
        let started = Date.timeIntervalSinceReferenceDate
        for caption in project.annotations {
            for _ in 0..<3 {
                try autoreleasepool {
                    let image = try #require(
                        VideoStyledCaptionImage.make(caption, style: style, size: size))
                    _ = try #require(context.createCGImage(image, from: image.extent))
                }
            }
        }
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        print(
            "caption uncached: 47 captions, 141 frames, \((Date.timeIntervalSinceReferenceDate - started) * 1000 / 141) ms/frame, peak RSS \(usage.ru_maxrss) bytes"
        )
        for caption in project.annotations { try project.setCaptionStyle(caption.id, style: style) }
        let cache = VideoCaptionRasterCache(annotations: project.annotations)
        let cachedStart = Date.timeIntervalSinceReferenceDate
        for caption in project.annotations {
            for _ in 0..<3 {
                try autoreleasepool { _ = try #require(cache.image(for: caption.id, size: size)) }
            }
        }
        let elapsed = Date.timeIntervalSinceReferenceDate - cachedStart
        let warmStart = Date.timeIntervalSinceReferenceDate
        for _ in 0..<120 {
            _ = try #require(cache.image(for: project.annotations.last!.id, size: size))
        }
        getrusage(RUSAGE_SELF, &usage)
        #expect(cache.statistics.misses == 47 && cache.statistics.hits == 214)
        print(
            "caption cached: 47 captions, 141 frames, \(elapsed * 1000 / 141) ms/frame; warm \((Date.timeIntervalSinceReferenceDate - warmStart) * 1000 / 120) ms/frame; retained \(cache.statistics.bytes) bytes; peak RSS \(usage.ru_maxrss) bytes"
        )
    }

    @Test func integerFontBoundsMatchIndependentPillowMasks() throws {
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../scripts/fixtures/caption-reference")
        var negativeControls = 0
        for size in [104.0, 112.0] {
            for (name, text) in [
                ("one", "fj"), ("two", "SYNTHETIC\nCAPTION"), ("pairs", "AVATAR fj"),
                ("long", "firm little rivers drift far"),
                ("mixed", "minimum rhythm from afar"),
                ("prefix", "little firm rivers drift far from terrain"),
                ("long-two", "fifty little letters form\ntrim rivers from firm terrain"),
            ] {
                var project = VideoProject.create(title: "Synthetic font reference")
                project.addText(text, startMs: 0, endMs: 1000)
                let caption = try #require(project.annotations.first)
                var style = VideoCaptionStyle()
                style.fontSize = size
                style.metrics = .fontBounds
                let reference = try #require(
                    CIImage(contentsOf: fixtures.appendingPathComponent("\(name)-\(Int(size)).png"))
                )
                let referenceMask = mask(reference)
                let native = try #require(
                    VideoStyledCaptionImage.make(
                        caption, style: style, size: CGSize(width: 2160, height: 3840)))
                let nativeMask = mask(native)
                let delta = distance(bounds(nativeMask), bounds(referenceMask))
                let intersection = nativeMask.intersection(referenceMask).count
                let union = nativeMask.union(referenceMask).count
                let overlap = Double(intersection) / Double(union)
                let nativeCoverage = coverage(nativeMask, within: referenceMask)
                let referenceCoverage = coverage(referenceMask, within: nativeMask)
                #expect(delta <= 1, "\(name) \(size): bounds delta \(delta)")
                #expect(
                    nativeCoverage >= 0.9999 && referenceCoverage >= 0.9999,
                    "\(name) \(size): two-pixel coverage \(nativeCoverage), \(referenceCoverage)")
                #expect(coverage(nativeMask, within: referenceMask, radius: 3) == 1)
                #expect(coverage(referenceMask, within: nativeMask, radius: 3) == 1)
                style.metrics = .typographic
                let old = try #require(
                    VideoStyledCaptionImage.make(
                        caption, style: style, size: CGSize(width: 2160, height: 3840)))
                if distance(bounds(mask(old)), bounds(referenceMask)) > 2 { negativeControls += 1 }
                print(
                    "caption mask \(name) \(Int(size)): bounds delta=\(delta)px, overlap=\(overlap), two-pixel coverage=\(nativeCoverage),\(referenceCoverage)"
                )
            }
        }
        #expect(negativeControls >= 2)
    }

    @Test func independentShadowStrokeChangesActualBlurredPixels() throws {
        var project = VideoProject.create(title: "Synthetic independent shadow")
        project.addText("SYNTHETIC", startMs: 0, endMs: 1000)
        let caption = try #require(project.annotations.first)
        var style = VideoCaptionStyle()
        style.canvasWidth = 800
        style.canvasHeight = 400
        style.width = 780
        style.x = 400
        style.y = 80
        style.fill.alpha = 0
        style.shadow = .init(
            x: 3, y: 7, blur: 0, strokeWidth: 7,
            color: .init(alpha: 230.0 / 255), strokeColor: .init(alpha: 150.0 / 255))
        let size = CGSize(width: 800, height: 400)
        let sharp = try #require(VideoStyledCaptionImage.make(caption, style: style, size: size))
        let alpha = VideoCaptionStyleTests.pixels(sharp).enumerated().filter { $0.offset % 4 == 3 }
            .map(\.element)
        #expect(alpha.filter { $0 == 230 }.count > 1000)
        #expect(alpha.filter { $0 == 150 }.count > 1000)
        #expect(alpha.max() == 230)
        style.shadow?.blur = 9
        let independent = try #require(
            VideoStyledCaptionImage.make(caption, style: style, size: size))
        style.shadow?.strokeColor = nil
        let uniform = try #require(VideoStyledCaptionImage.make(caption, style: style, size: size))
        let a = VideoCaptionStyleTests.pixels(independent)
        let b = VideoCaptionStyleTests.pixels(uniform)
        let differences = stride(from: 3, to: a.count, by: 4).map { Int(b[$0]) - Int(a[$0]) }
        #expect(differences.filter { $0 >= 10 }.count > 1000)
        #expect(differences.min()! >= 0)
        var invalid = style
        invalid.shadow?.strokeColor = .init(alpha: 1.1)
        #expect(throws: (any Error).self) { try invalid.validate() }
        #expect(throws: (any Error).self) {
            try VideoStyledCaptionImage.layout("SYNTHETIC 🦊", style: style)
        }
    }

    private func mask(_ image: CIImage) -> Set<Int> {
        let bytes = VideoCaptionStyleTests.pixels(image)
        return Set(
            stride(from: 0, to: bytes.count, by: 4).filter { bytes[$0] >= 128 }.map { $0 / 4 })
    }

    private func coverage(_ pixels: Set<Int>, within reference: Set<Int>, radius: Int = 2) -> Double
    {
        let neighbors = (-radius...radius).flatMap { y in
            (-radius...radius).map { x in y * 2160 + x }
        }
        return Double(
            pixels.filter { pixel in neighbors.contains { reference.contains(pixel + $0) } }.count)
            / Double(pixels.count)
    }

    private func bounds(_ mask: Set<Int>) -> [Int] {
        let x = mask.map { $0 % 2160 }
        let y = mask.map { $0 / 2160 }
        return [x.min()!, y.min()!, x.max()!, y.max()!]
    }

    private func distance(_ a: [Int], _ b: [Int]) -> Int {
        zip(a, b).map { abs($0 - $1) }.max()!
    }
}
