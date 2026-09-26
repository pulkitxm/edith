import CoreGraphics
import Foundation
import Testing

@testable import EdithStudio

@Suite(.enabled(if: MediaFixtures.available)) struct MediaVideoTests {
    @Test func probeReadsDurationSizeAndStreams() async throws {
        let space = try Workspace()
        defer { withExtendedLifetime(space) {} }
        let clip = space.url("clip.mp4")
        try await MediaFixtures.clip(at: clip)
        let info = try await MediaFixtures.probe(clip)
        #expect(MediaFixtures.near(info.duration, 3))
        #expect(info.width == 160 && info.height == 120)
        #expect(info.videoCodec == "h264" && info.audioCodec == "aac")
        #expect(MediaFixtures.near(info.frameRate, 25, tolerance: 0.01))
        let fallback = await StudioMedia.probe(clip, environment: StudioEnvironment())
        #expect(MediaFixtures.near(fallback?.duration, 3))
        #expect(fallback?.width == 160)
    }

    @Test func missingFFmpegIsReportedBeforeRunning() async throws {
        let space = try Workspace()
        defer { withExtendedLifetime(space) {} }
        let clip = space.url("clip.mp4")
        try await MediaFixtures.clip(at: clip, seconds: 1)
        var bare = StudioEnvironment()
        bare.temporaryRoot = space.url("staging")
        await #expect(throws: StudioError.needsEngine(.ffmpeg)) {
            try await space.run("video.compress", [clip], environment: bare)
        }
    }

    @Test func compressByQualityCodecAndTargetSize() async throws {
        let space = try Workspace()
        defer { withExtendedLifetime(space) {} }
        let clip = space.url("big.mp4")
        try await MediaFixtures.clip(at: clip, lossless: true)
        let before = StudioRunner.fileSize(clip)
        let result = try await space.run("video.compress", [clip])
        let output = try #require(result.outputs.first)
        #expect(output.url.lastPathComponent == "big-compressed.mp4")
        #expect(output.bytes < before)
        let info = try await MediaFixtures.probe(output.url)
        #expect(info.videoCodec == "h264" && info.hasAudio)
        #expect(MediaFixtures.near(info.duration, 3))

        let hevc = try await space.run("video.compress", [clip], ["codec": .text("hevc")])
        #expect(try await MediaFixtures.probe(try hevc.url()).videoCodec == "hevc")

        let sized = try await space.run(
            "video.compress", [clip], ["mode": .text("size"), "targetMB": .number(0.08)])
        #expect(try #require(sized.outputs.first).bytes < Int64(0.08 * 1024 * 1024 * 1.35))
    }

    @Test func convertBetweenContainers() async throws {
        let space = try Workspace()
        defer { withExtendedLifetime(space) {} }
        let clip = space.url("clip.mp4")
        try await MediaFixtures.clip(at: clip, seconds: 2)
        let expectations: [(String, String)] = [
            ("mov", "h264"), ("webm", "vp9"), ("mkv", "h264"), ("avi", "mpeg4"), ("gif", "gif"),
            ("m4v", "h264"),
        ]
        for (format, codec) in expectations {
            let result = try await space.run("video.convert", [clip], ["format": .text(format)])
            let url = try result.url()
            #expect(url.pathExtension == format)
            let info = try await MediaFixtures.probe(url)
            #expect(info.videoCodec == codec, "\(format)")
            #expect(MediaFixtures.near(info.duration, 2, tolerance: 0.4), "\(format)")
        }
        let gif = try await space.run("video.convert", [clip], ["format": .text("gif")])
        let back = try await space.run("video.convert", [try gif.url()], ["format": .text("mp4")])
        let info = try await MediaFixtures.probe(try back.url())
        #expect(info.videoCodec == "h264" && info.width == 160)
    }

    @Test func trimExactAndFast() async throws {
        let space = try Workspace()
        defer { withExtendedLifetime(space) {} }
        let clip = space.url("clip.mp4")
        try await MediaFixtures.clip(at: clip)
        let exact = try await space.run(
            "video.trim", [clip], ["range": .span(StudioSpan(start: 0.5, end: 1.5))])
        let info = try await MediaFixtures.probe(try exact.url())
        #expect(MediaFixtures.near(info.duration, 1, tolerance: 0.1))
        #expect(info.hasAudio)
        let fast = try await space.run(
            "video.trim", [clip],
            ["range": .span(StudioSpan(start: 1, end: nil)), "precision": .text("fast")])
        let fastDuration = try #require(try await MediaFixtures.probe(try fast.url()).duration)
        #expect(fastDuration > 1.9 && fastDuration < 3.1)
        await #expect(throws: StudioError.self) { try await space.run("video.trim", [clip]) }
        await #expect(throws: StudioError.self) {
            try await space.run(
                "video.trim", [clip], ["range": .span(StudioSpan(start: 9, end: nil))])
        }
    }

    @Test func splitIntoPieces() async throws {
        let space = try Workspace()
        defer { withExtendedLifetime(space) {} }
        let clip = space.url("long.mp4")
        try await MediaFixtures.clip(at: clip, seconds: 3)
        let every = try await space.run("video.split", [clip], ["seconds": .number(1)])
        #expect(every.outputs.count == 3)
        #expect(every.folders.count == 1)
        #expect(every.outputs.map(\.url.lastPathComponent).sorted().first == "long-part-001.mp4")
        for output in every.outputs {
            #expect(
                MediaFixtures.near(
                    try await MediaFixtures.probe(output.url).duration, 1, tolerance: 0.2))
        }
        let parts = try await space.run(
            "video.split", [clip], ["mode": .text("parts"), "parts": .number(2)])
        #expect(parts.outputs.count == 2)
        let times = try await space.run(
            "video.split", [clip], ["mode": .text("at"), "times": .text("0:02")])
        let durations = try await times.outputs.asyncMap {
            try await MediaFixtures.probe($0.url).duration ?? 0
        }
        #expect(durations.count == 2)
        #expect(MediaFixtures.near(durations.sorted().first, 1, tolerance: 0.2))
    }

    @Test func mergeMatchesSizeAndFillsMissingSound() async throws {
        let space = try Workspace()
        defer { withExtendedLifetime(space) {} }
        let first = space.url("first.mp4")
        let second = space.url("second.mp4")
        try await MediaFixtures.clip(at: first, seconds: 2)
        try await MediaFixtures.clip(at: second, seconds: 1, size: "320x320", audio: false)
        let result = try await space.run("video.merge", [first, second])
        let info = try await MediaFixtures.probe(try result.url())
        #expect(MediaFixtures.near(info.duration, 3, tolerance: 0.2))
        #expect(info.width == 160 && info.height == 120)
        #expect(info.hasAudio)
        let sized = try await space.run("video.merge", [first, second], ["size": .text("720")])
        #expect(try await MediaFixtures.probe(try sized.url()).height == 720)
    }

    @Test func gifFromARange() async throws {
        let space = try Workspace()
        defer { withExtendedLifetime(space) {} }
        let clip = space.url("clip.mp4")
        try await MediaFixtures.clip(at: clip)
        let result = try await space.run(
            "video.to-gif", [clip],
            [
                "range": .span(StudioSpan(start: 1, end: 2)), "width": .text("original"),
                "fps": .number(10),
            ])
        let url = try result.url()
        #expect(url.pathExtension == "gif")
        let info = try await MediaFixtures.probe(url)
        #expect(info.videoCodec == "gif" && info.width == 160)
        #expect(MediaFixtures.near(info.duration, 1, tolerance: 0.25))
        let frames = try StudioImageIO.frames(url)
        #expect((8...12).contains(frames.count))
    }

    @Test func extractAudioAndRefuseSilentVideos() async throws {
        let space = try Workspace()
        defer { withExtendedLifetime(space) {} }
        let clip = space.url("clip.mp4")
        let silent = space.url("silent.mp4")
        try await MediaFixtures.clip(at: clip)
        try await MediaFixtures.clip(at: silent, seconds: 1, audio: false)
        for (format, codec) in [
            ("mp3", "mp3"), ("m4a", "aac"), ("wav", "pcm_s16le"), ("flac", "flac"),
            ("opus", "opus"),
        ] {
            let result = try await space.run(
                "video.extract-audio", [clip], ["format": .text(format)])
            let info = try await MediaFixtures.probe(try result.url())
            #expect(info.audioCodec == codec && !info.hasVideo, "\(format)")
        }
        await #expect(throws: StudioError.nothingToDo("This video has no sound.")) {
            try await space.run("video.extract-audio", [silent])
        }
    }

    @Test func framesByIntervalCountTimesAndThumbnail() async throws {
        let space = try Workspace()
        defer { withExtendedLifetime(space) {} }
        let clip = space.url("clip.mp4")
        try await MediaFixtures.clip(at: clip)
        let interval = try await space.run("video.frames", [clip], ["seconds": .number(1)])
        #expect(interval.outputs.count == 3)
        #expect(interval.outputs.allSatisfy { $0.url.pathExtension == "jpg" })
        let count = try await space.run(
            "video.frames", [clip],
            ["mode": .text("count"), "count": .number(4), "format": .text("png")])
        #expect(count.outputs.count == 4)
        let times = try await space.run(
            "video.frames", [clip], ["mode": .text("times"), "times": .text("0.5, 0:01.5, 9")])
        #expect(times.outputs.count == 2)
        let thumbnail = try await space.run(
            "video.frames", [clip],
            ["mode": .text("thumbnail"), "at": .number(30), "width": .text("320")])
        #expect(thumbnail.outputs.count == 1)
        #expect(try thumbnail.url().lastPathComponent == "clip-thumbnail.jpg")
        #expect(StudioImageIO.info(try thumbnail.url())?.width == 320)
    }

    @Test func muteRotateAndResize() async throws {
        let space = try Workspace()
        defer { withExtendedLifetime(space) {} }
        let clip = space.url("clip.mp4")
        try await MediaFixtures.clip(at: clip, seconds: 1)
        let muted = try await MediaFixtures.probe(try await space.run("video.mute", [clip]).url())
        #expect(muted.hasVideo && !muted.hasAudio)

        let rotated = try await MediaFixtures.probe(
            try await space.run("video.rotate", [clip]).url())
        #expect(rotated.width == 120 && rotated.height == 160 && rotated.hasAudio)
        let mirrored = try await MediaFixtures.probe(
            try await space.run("video.rotate", [clip], ["turn": .text("mirror")]).url())
        #expect(mirrored.width == 160)

        let custom = try await MediaFixtures.probe(
            try await space.run(
                "video.resize", [clip], ["size": .text("custom"), "width": .number(80)]
            ).url())
        #expect(custom.width == 80 && custom.height == 60)
        await #expect(throws: StudioError.self) {
            try await space.run("video.resize", [clip], ["size": .text("720")])
        }
        let bigger = try await MediaFixtures.probe(
            try await space.run(
                "video.resize", [clip], ["size": .text("360"), "upscale": .bool(true)]
            ).url())
        #expect(bigger.height == 360 && bigger.width == 480)
    }

    @Test func cropToShapeAreaAndBlackBars() async throws {
        let space = try Workspace()
        defer { withExtendedLifetime(space) {} }
        let clip = space.url("clip.mp4")
        try await MediaFixtures.clip(at: clip, seconds: 1)
        let square = try await MediaFixtures.probe(try await space.run("video.crop", [clip]).url())
        #expect(square.width == 120 && square.height == 120)
        let vertical = try await MediaFixtures.probe(
            try await space.run("video.crop", [clip], ["aspect": .text("9:16")]).url())
        #expect(vertical.height == 120 && vertical.width == 66)
        let area = try await MediaFixtures.probe(
            try await space.run(
                "video.crop", [clip],
                [
                    "mode": .text("area"),
                    "area": .rect(StudioRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)),
                ]
            ).url())
        #expect(area.width == 80 && area.height == 60)

        let boxed = space.url("boxed.mp4")
        try await MediaFixtures.clip(at: boxed, seconds: 1, videoFilter: "pad=160:200:0:40:black")
        let detected = try await MediaFixtures.probe(
            try await space.run("video.crop", [boxed], ["mode": .text("auto")]).url())
        #expect(detected.width == 160)
        #expect(detected.height == 120)
        await #expect(throws: StudioError.self) {
            try await space.run("video.crop", [clip], ["mode": .text("auto")])
        }
    }

    @Test func speedReverseAndLoop() async throws {
        let space = try Workspace()
        defer { withExtendedLifetime(space) {} }
        let clip = space.url("clip.mp4")
        try await MediaFixtures.clip(at: clip)
        let fast = try await MediaFixtures.probe(try await space.run("video.speed", [clip]).url())
        #expect(MediaFixtures.near(fast.duration, 1.5, tolerance: 0.15) && fast.hasAudio)
        let slow = try await MediaFixtures.probe(
            try await space.run(
                "video.speed", [clip], ["speed": .text("0.25"), "sound": .bool(false)]
            ).url())
        #expect(MediaFixtures.near(slow.duration, 12, tolerance: 0.3) && !slow.hasAudio)

        let reversed = try await MediaFixtures.probe(
            try await space.run("video.reverse", [clip]).url())
        #expect(MediaFixtures.near(reversed.duration, 3, tolerance: 0.15) && reversed.hasAudio)

        let looped = try await MediaFixtures.probe(
            try await space.run("video.loop", [clip], ["times": .number(3)]).url())
        #expect(MediaFixtures.near(looped.duration, 9, tolerance: 0.3))
    }

    @Test func reverseLongVideosInChunks() async throws {
        let space = try Workspace()
        defer { withExtendedLifetime(space) {} }
        let clip = space.url("long.mp4")
        try await MediaFixtures.clip(
            at: clip, seconds: 23, size: "96x64",
            source: "color=c=black:size=96x64:rate=25",
            videoFilter: "geq=lum='min(255,T*10)':cb=128:cr=128")
        let result = try await space.run("video.reverse", [clip])
        let info = try await MediaFixtures.probe(try result.url())
        #expect(MediaFixtures.near(info.duration, 23, tolerance: 0.4))
        #expect(info.hasAudio)
        let start = Fixtures.pixel(
            try await MediaFixtures.frame(try result.url(), at: 0.2, in: space), x: 48, y: 32)
        let middle = Fixtures.pixel(
            try await MediaFixtures.frame(try result.url(), at: 13, in: space), x: 48, y: 32)
        let end = Fixtures.pixel(
            try await MediaFixtures.frame(try result.url(), at: 22.5, in: space), x: 48, y: 32)
        #expect(abs(start.g - 228) < 25)
        #expect(abs(middle.g - 100) < 25)
        #expect(end.g < 25)
    }

    @Test func musicVolumeAndFades() async throws {
        let space = try Workspace()
        defer { withExtendedLifetime(space) {} }
        let clip = space.url("clip.mp4")
        let silent = space.url("silent.mp4")
        let music = space.url("music.m4a")
        try await MediaFixtures.clip(at: clip)
        try await MediaFixtures.clip(at: silent, seconds: 2, audio: false)
        try await MediaFixtures.tone(at: music, seconds: 1, frequency: 660, codec: ["-c:a", "aac"])
        let mixed = try await MediaFixtures.probe(
            try await space.run("video.add-audio", [clip], ["audio": .text(music.path)]).url())
        #expect(MediaFixtures.near(mixed.duration, 3, tolerance: 0.2) && mixed.hasAudio)
        let replaced = try await MediaFixtures.probe(
            try await space.run(
                "video.add-audio", [silent],
                ["audio": .text(music.path), "mode": .text("replace"), "loop": .bool(false)]
            ).url())
        #expect(MediaFixtures.near(replaced.duration, 2, tolerance: 0.2) && replaced.hasAudio)

        let normalized = try await MediaFixtures.probe(
            try await space.run("video.volume", [clip]).url())
        #expect(normalized.hasAudio && normalized.videoCodec == "h264")
        let quieter = try await space.run(
            "video.volume", [clip], ["mode": .text("adjust"), "gain": .number(-10)])
        #expect(try await MediaFixtures.probe(try quieter.url()).hasAudio)
        await #expect(throws: StudioError.self) { try await space.run("video.volume", [silent]) }

        let faded = try await space.run("video.fade", [clip])
        let dark = try await MediaFixtures.frame(try faded.url(), at: 0, in: space)
        let pixel = Fixtures.pixel(dark, x: 80, y: 60)
        #expect(pixel.r + pixel.g + pixel.b < 60)
    }

    @Test func watermarkTextAndTiledImage() async throws {
        let space = try Workspace()
        defer { withExtendedLifetime(space) {} }
        let clip = space.url("blue.mp4")
        try await MediaFixtures.clip(
            at: clip, seconds: 1, size: "320x180", source: "color=c=0x1E3A8A:size=320x180:rate=25")
        let text = try await space.run(
            "video.watermark", [clip],
            [
                "text": .text("STUDIO"), "position": .text("center"), "size": .number(0.6),
                "opacity": .number(1),
            ])
        let frame = try await MediaFixtures.frame(try text.url(), at: 0.5, in: space)
        var bright = 0
        for x in stride(from: 80, to: 240, by: 4) {
            let pixel = Fixtures.pixel(frame, x: x, y: 90)
            if pixel.r > 200 && pixel.g > 200 { bright += 1 }
        }
        #expect(bright > 3)
        let logo = space.url("logo.png")
        try Fixtures.image(at: logo, width: 60, height: 40)
        let tiled = try await space.run(
            "video.watermark", [clip],
            [
                "kind": .text("image"), "image": .text(logo.path), "position": .text("tiled"),
                "opacity": .number(1),
            ])
        let tiledFrame = try await MediaFixtures.frame(try tiled.url(), at: 0.5, in: space)
        var red = 0
        for x in stride(from: 0, to: 320, by: 5) {
            for y in stride(from: 0, to: 180, by: 5) {
                let pixel = Fixtures.pixel(tiledFrame, x: x, y: y)
                if pixel.r > 150 && pixel.b < 100 { red += 1 }
            }
        }
        #expect(red > 10)
    }

    @Test func subtitlesBurnAndTrack() async throws {
        let space = try Workspace()
        defer { withExtendedLifetime(space) {} }
        let clip = space.url("blue.mp4")
        try await MediaFixtures.clip(
            at: clip, seconds: 3, size: "320x180", source: "color=c=0x1E3A8A:size=320x180:rate=25")
        let srt = space.url("captions.srt")
        try """
        1
        00:00:00,500 --> 00:00:01,500
        <i>Hello there</i>

        2
        00:00:02,000 --> 00:00:02,800
        Second line
        """.write(to: srt, atomically: true, encoding: .utf8)
        let burned = try await space.run(
            "video.subtitles", [clip],
            ["subtitles": .text(srt.path), "box": .bool(false), "size": .number(0.12)])
        let url = try burned.url()
        #expect(MediaFixtures.near(try await MediaFixtures.probe(url).duration, 3, tolerance: 0.2))
        func whitePixels(_ image: CGImage) -> Int {
            var count = 0
            for x in stride(from: 0, to: 320, by: 2) {
                for y in stride(from: 120, to: 180, by: 2) {
                    let pixel = Fixtures.pixel(image, x: x, y: y)
                    if pixel.r > 200 && pixel.g > 200 && pixel.b > 200 { count += 1 }
                }
            }
            return count
        }
        let during = whitePixels(try await MediaFixtures.frame(url, at: 1.0, in: space))
        let between = whitePixels(try await MediaFixtures.frame(url, at: 1.75, in: space))
        let second = whitePixels(try await MediaFixtures.frame(url, at: 2.4, in: space))
        #expect(during > 10)
        #expect(between == 0)
        #expect(second > 10)

        let track = try await space.run(
            "video.subtitles", [clip], ["subtitles": .text(srt.path), "mode": .text("track")])
        let trackInfo = try await MediaFixtures.probe(try track.url())
        #expect(trackInfo.subtitleTracks == 1)

        let empty = space.url("empty.srt")
        try "nothing here".write(to: empty, atomically: true, encoding: .utf8)
        await #expect(throws: StudioError.self) {
            try await space.run("video.subtitles", [clip], ["subtitles": .text(empty.path)])
        }
    }

    @Test func frameRateStabilizeDenoiseAndAdjust() async throws {
        let space = try Workspace()
        defer { withExtendedLifetime(space) {} }
        let clip = space.url("clip.mp4")
        try await MediaFixtures.clip(at: clip, seconds: 2)
        let fps = try await MediaFixtures.probe(
            try await space.run("video.fps", [clip], ["fps": .text("15")]).url())
        #expect(MediaFixtures.near(fps.frameRate, 15, tolerance: 0.01))
        for id in ["video.stabilize", "video.denoise", "video.adjust"] {
            let info = try await MediaFixtures.probe(try await space.run(id, [clip]).url())
            #expect(MediaFixtures.near(info.duration, 2, tolerance: 0.2), "\(id)")
            #expect(info.width == 160 && info.hasAudio, "\(id)")
        }
        let cleaned = try await space.run(
            "video.denoise", [clip], ["audio": .bool(true), "strength": .text("strong")])
        #expect(try await MediaFixtures.probe(try cleaned.url()).hasAudio)
    }

    @Test func socialFormats() async throws {
        let space = try Workspace()
        defer { withExtendedLifetime(space) {} }
        let clip = space.url("clip.mp4")
        try await MediaFixtures.clip(at: clip, seconds: 1)
        let expectations: [(String, String, Int, Int)] = [
            ("9:16", "blur", 720, 1280), ("1:1", "bars", 720, 720), ("4:5", "crop", 720, 900),
            ("16:9", "blur", 1280, 720),
        ]
        for (shape, fill, width, height) in expectations {
            let result = try await space.run(
                "video.social", [clip],
                ["shape": .text(shape), "fill": .text(fill), "quality": .text("720")])
            let info = try await MediaFixtures.probe(try result.url())
            #expect(info.width == width && info.height == height, "\(shape) \(fill)")
            #expect(info.hasAudio)
        }
    }

    @Test func slideshowFromImages() async throws {
        let space = try Workspace()
        defer { withExtendedLifetime(space) {} }
        let images = (0..<3).map { space.url("photo-\($0).png") }
        for (index, url) in images.enumerated() {
            try Fixtures.image(at: url, width: 300 + index * 50, height: 200)
        }
        let music = space.url("music.mp3")
        try await MediaFixtures.tone(at: music, seconds: 2, codec: ["-c:a", "libmp3lame"])
        let faded = try await space.run(
            "video.from-images", images,
            ["seconds": .number(1.5), "size": .text("1280x720"), "audio": .text(music.path)])
        let info = try await MediaFixtures.probe(try faded.url())
        #expect(info.width == 1280 && info.height == 720)
        #expect(MediaFixtures.near(info.duration, 3.5, tolerance: 0.2))
        #expect(info.hasAudio)
        let plain = try await space.run(
            "video.from-images", images,
            [
                "seconds": .number(1), "crossfade": .bool(false), "size": .text("1080x1080"),
                "fit": .text("fill"),
            ])
        let plainInfo = try await MediaFixtures.probe(try plain.url())
        #expect(MediaFixtures.near(plainInfo.duration, 3, tolerance: 0.15))
        #expect(plainInfo.width == 1080 && !plainInfo.hasAudio)
        let single = try await space.run("video.from-images", [images[0]], ["seconds": .number(2)])
        #expect(
            MediaFixtures.near(
                try await MediaFixtures.probe(try single.url()).duration, 2, tolerance: 0.15))
    }

    @Test func cancellingStopsFFmpeg() async throws {
        let space = try Workspace()
        defer { withExtendedLifetime(space) {} }
        let clip = space.url("long.mp4")
        try await MediaFixtures.clip(at: clip, seconds: 40, size: "320x240")
        let task = Task {
            try await space.run(
                "video.compress", [clip], ["codec": .text("hevc"), "level": .text("low")])
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        task.cancel()
        let started = Date()
        await #expect(throws: StudioError.cancelled) { try await task.value }
        #expect(Date().timeIntervalSince(started) < 5)
    }
}

extension Array {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var results: [T] = []
        for element in self { results.append(try await transform(element)) }
        return results
    }
}
