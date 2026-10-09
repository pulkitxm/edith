import Foundation
import Testing

@testable import EdithStudio

@Suite(.enabled(if: MediaFixtures.available)) struct MediaAudioTests {
    @Test func convertToEveryFormat() async throws {
        let space = try Workspace()
        defer { withExtendedLifetime(space) {} }
        let source = space.url("tone.wav")
        try await MediaFixtures.tone(at: source, seconds: 2)
        let expectations: [(String, String, String)] = [
            ("mp3", "mp3", "mp3"), ("m4a", "m4a", "aac"), ("wav", "wav", "pcm_s16le"),
            ("flac", "flac", "flac"), ("opus", "opus", "opus"), ("ogg", "ogg", "opus"),
            ("aiff", "aiff", "pcm_s16be"), ("alac", "m4a", "alac"),
        ]
        for (format, ext, codec) in expectations {
            let result = try await space.run("audio.convert", [source], ["format": .text(format)])
            let url = try result.url()
            #expect(url.pathExtension == ext, "\(format)")
            let info = try await MediaFixtures.probe(url)
            #expect(info.audioCodec == codec, "\(format)")
            #expect(MediaFixtures.near(info.duration, 2, tolerance: 0.1), "\(format)")
        }
        let same = try await space.run("audio.convert", [source], ["format": .text("wav")])
        #expect(try same.url().lastPathComponent.hasPrefix("tone-converted"))
        let mono = try await space.run("audio.convert", [source], ["mono": .bool(true)])
        #expect(try await MediaFixtures.probe(try mono.url()).channels == 1)
    }

    @Test func convertPullsSoundOutOfVideo() async throws {
        let space = try Workspace()
        defer { withExtendedLifetime(space) {} }
        let clip = space.url("clip.mp4")
        try await MediaFixtures.clip(at: clip, seconds: 2)
        let result = try await space.run("audio.convert", [clip], ["format": .text("m4a")])
        let info = try await MediaFixtures.probe(try result.url())
        #expect(info.audioCodec == "aac" && !info.hasVideo)
    }

    @Test func compressShrinksLosslessAudio() async throws {
        let space = try Workspace()
        defer { withExtendedLifetime(space) {} }
        let source = space.url("voice.wav")
        try await MediaFixtures.tone(at: source, seconds: 3)
        let result = try await space.run("audio.compress", [source])
        let output = try #require(result.outputs.first)
        #expect(output.url.pathExtension == "m4a")
        #expect(output.bytes < StudioRunner.fileSize(source) / 4)
        let mp3 = space.url("song.mp3")
        try await MediaFixtures.tone(
            at: mp3, seconds: 3, codec: ["-c:a", "libmp3lame", "-b:a", "320k"])
        let extreme = try await space.run("audio.compress", [mp3], ["level": .text("extreme")])
        let extremeFile = try #require(extreme.outputs.first)
        #expect(extremeFile.url.pathExtension == "mp3")
        #expect(extremeFile.bytes < StudioRunner.fileSize(mp3))
        #expect(try await MediaFixtures.probe(extremeFile.url).channels == 1)
    }

    @Test func trimWithFades() async throws {
        let space = try Workspace()
        defer { withExtendedLifetime(space) {} }
        let source = space.url("song.mp3")
        try await MediaFixtures.tone(at: source, seconds: 4, codec: ["-c:a", "libmp3lame"])
        let result = try await space.run(
            "audio.trim", [source],
            [
                "range": .span(StudioSpan(start: 1, end: 3)), "fadeIn": .number(0.5),
                "fadeOut": .number(0.5),
            ])
        let url = try result.url()
        #expect(url.lastPathComponent == "song-trimmed.mp3")
        let info = try await MediaFixtures.probe(url)
        #expect(info.audioCodec == "mp3")
        #expect(MediaFixtures.near(info.duration, 2, tolerance: 0.1))
    }

    @Test func mergeWithAndWithoutCrossfade() async throws {
        let space = try Workspace()
        defer { withExtendedLifetime(space) {} }
        let first = space.url("a.m4a")
        let second = space.url("b.wav")
        try await MediaFixtures.tone(at: first, seconds: 2, codec: ["-c:a", "aac"])
        try await MediaFixtures.tone(at: second, seconds: 1.5, frequency: 880)
        let plain = try await space.run("audio.merge", [first, second])
        let plainInfo = try await MediaFixtures.probe(try plain.url())
        #expect(try plain.url().pathExtension == "m4a")
        #expect(MediaFixtures.near(plainInfo.duration, 3.5, tolerance: 0.1))
        let faded = try await space.run(
            "audio.merge", [first, second], ["crossfade": .number(1), "format": .text("wav")])
        let fadedInfo = try await MediaFixtures.probe(try faded.url())
        #expect(fadedInfo.audioCodec == "pcm_s16le")
        #expect(MediaFixtures.near(fadedInfo.duration, 2.5, tolerance: 0.1))
    }

    @Test func volumeSpeedFadeReverseAndDenoise() async throws {
        let space = try Workspace()
        defer { withExtendedLifetime(space) {} }
        let source = space.url("tone.flac")
        try await MediaFixtures.tone(at: source, seconds: 2, codec: ["-c:a", "flac"])
        let normalized = try await MediaFixtures.probe(
            try await space.run("audio.volume", [source]).url())
        #expect(normalized.audioCodec == "flac" && normalized.sampleRate == 48000)
        let louder = try await space.run(
            "audio.volume", [source], ["mode": .text("adjust"), "gain": .number(3)])
        #expect(try await MediaFixtures.probe(try louder.url()).audioCodec == "flac")

        let faster = try await MediaFixtures.probe(
            try await space.run("audio.speed", [source], ["speed": .text("2")]).url())
        #expect(MediaFixtures.near(faster.duration, 1, tolerance: 0.1))
        let chipmunk = try await MediaFixtures.probe(
            try await space.run(
                "audio.speed", [source], ["speed": .text("0.5"), "pitch": .bool(false)]
            ).url())
        #expect(MediaFixtures.near(chipmunk.duration, 4, tolerance: 0.15))

        for id in ["audio.fade", "audio.reverse", "audio.denoise"] {
            let info = try await MediaFixtures.probe(try await space.run(id, [source]).url())
            #expect(MediaFixtures.near(info.duration, 2, tolerance: 0.1), "\(id)")
        }
    }

    @Test func removeSilenceShortensRecordings() async throws {
        let space = try Workspace()
        defer { withExtendedLifetime(space) {} }
        let source = space.url("talk.wav")
        try await MediaFixtures.ffmpeg([
            "-f", "lavfi", "-i", "sine=frequency=300:sample_rate=48000:duration=1",
            "-f", "lavfi", "-i", "anullsrc=channel_layout=mono:sample_rate=48000:duration=2",
            "-f", "lavfi", "-i", "sine=frequency=500:sample_rate=48000:duration=1",
            "-filter_complex", "[0:a][1:a][2:a]concat=n=3:v=0:a=1[a]", "-map", "[a]", source.path,
        ])
        let all = try await MediaFixtures.probe(
            try await space.run("audio.remove-silence", [source]).url())
        #expect(try #require(all.duration) < 3)
        let ends = try await MediaFixtures.probe(
            try await space.run("audio.remove-silence", [source], ["where": .text("ends")]).url())
        #expect(MediaFixtures.near(ends.duration, 4, tolerance: 0.2))
    }

    @Test func audioToVideoWithWaveformOrCover() async throws {
        let space = try Workspace()
        defer { withExtendedLifetime(space) {} }
        let source = space.url("podcast.m4a")
        try await MediaFixtures.tone(at: source, seconds: 2, codec: ["-c:a", "aac"])
        let wave = try await MediaFixtures.probe(
            try await space.run("audio.to-video", [source]).url())
        #expect(wave.width == 1280 && wave.height == 720)
        #expect(wave.hasAudio && wave.videoCodec == "h264")
        #expect(MediaFixtures.near(wave.duration, 2, tolerance: 0.2))
        let cover = space.url("cover.png")
        try Fixtures.image(at: cover, width: 500, height: 500)
        let covered = try await MediaFixtures.probe(
            try await space.run(
                "audio.to-video", [source],
                ["style": .text("cover"), "image": .text(cover.path), "size": .text("1080x1080")]
            ).url())
        #expect(covered.width == 1080 && covered.hasAudio)
        #expect(MediaFixtures.near(covered.duration, 2, tolerance: 0.6))
    }
}

@Suite struct MediaParsingTests {
    @Test func progressLinesBecomeSeconds() {
        #expect(FFmpeg.progressSeconds("out_time_us=1500000") == 1.5)
        #expect(FFmpeg.progressSeconds("out_time_ms=250000") == 0.25)
        #expect(FFmpeg.progressSeconds("out_time_us=N/A") == nil)
        #expect(FFmpeg.progressSeconds("frame=12") == nil)
    }

    @Test func errorSummaryKeepsTheLastLines() {
        let summary = FFmpeg.summary("line one\n\n  line two\nline three\nlast line\n")
        #expect(summary == "line two line three last line")
        #expect(FFmpeg.summary("").contains("without an error"))
    }

    @Test func atempoChainsStayInRange() {
        #expect(MediaEncoding.atempo(2) == "atempo=2.0000")
        #expect(MediaEncoding.atempo(4) == "atempo=2.0,atempo=2.0000")
        #expect(MediaEncoding.atempo(0.25) == "atempo=0.5,atempo=0.5000")
    }

    @Test func cropDetectOutputIsParsed() {
        let log = [
            "frame:0", "lavfi.cropdetect.w=160", "lavfi.cropdetect.h=120", "lavfi.cropdetect.x=0",
            "lavfi.cropdetect.y=40", "frame:1", "lavfi.cropdetect.w=160", "lavfi.cropdetect.h=118",
            "lavfi.cropdetect.x=0", "lavfi.cropdetect.y=42", "lavfi.cropdetect.limit=24.000000",
        ].joined(separator: "\n")
        #expect(CropDetector.parse(log) == CGRect(x: 0, y: 42, width: 160, height: 118))
        #expect(CropDetector.parse("nothing") == nil)
    }

    @Test func probeJSONIsParsed() {
        let info = FFmpeg.parse([
            "format": ["duration": "4.5", "bit_rate": "128000", "format_name": "mov,mp4"],
            "streams": [
                [
                    "codec_type": "video", "codec_name": "h264", "width": 1920, "height": 1080,
                    "avg_frame_rate": "30000/1001", "side_data_list": [["rotation": -90]],
                ],
                [
                    "codec_type": "audio", "codec_name": "aac", "sample_rate": "44100",
                    "channels": 2,
                ],
                ["codec_type": "subtitle", "codec_name": "mov_text"],
            ],
        ])
        #expect(info.duration == 4.5)
        #expect(info.displaySize == CGSize(width: 1080, height: 1920))
        #expect(MediaFixtures.near(info.frameRate, 29.97, tolerance: 0.01))
        #expect(info.sampleRate == 44100 && info.channels == 2)
        #expect(info.subtitleTracks == 1)
    }

    @Test func subtitlesParseFromSRTAndVTT() {
        let srt = SubtitleParser.parse(
            "1\r\n00:00:01,000 --> 00:00:02,500\r\n<b>Hello</b>\r\nworld\r\n\r\n2\r\n00:00:03,000 --> 00:00:04,000\r\n{\\an8}Top\r\n"
        )
        #expect(
            srt == [
                SubtitleCue(start: 1, end: 2.5, text: "Hello\nworld"),
                SubtitleCue(start: 3, end: 4, text: "Top"),
            ])
        let vtt = SubtitleParser.parse(
            "WEBVTT\n\nNOTE a comment\n\n00:01.000 --> 00:02.000 align:start position:10%\nFirst\n\nintro\n01:00:00.000 --> 01:00:01.000\nLate"
        )
        #expect(vtt.map(\.text) == ["First", "Late"])
        #expect(vtt.last?.start == 3600)
    }

    @Test func overlappingCuesShareTheScreen() {
        let timeline = SubtitleParser.timeline(
            [SubtitleCue(start: 1, end: 3, text: "A"), SubtitleCue(start: 2, end: 4, text: "B")],
            duration: 5)
        #expect(timeline.map(\.text) == ["", "A", "A\nB", "B", ""])
        #expect(timeline.map(\.start) == [0, 1, 2, 3, 4])
    }

    @Test func mediaToolsAreRegisteredWithFFmpeg() {
        let ids = [
            "video.edit", "video.compress", "video.convert", "audio.trim", "audio.compress",
            "audio.convert",
        ]
        for id in ids { #expect(StudioCatalog.tool(id) != nil, "\(id)") }
        for tool in StudioCatalog.tools
        where tool.id.hasPrefix("video.") || tool.id.hasPrefix("audio.") {
            if tool.isRunnable {
                #expect(tool.requirements.contains(.engine(.ffmpeg)), "\(tool.id)")
            }
        }
        #expect(StudioCatalog.tool("video.edit")?.style == .editor(.video, pdfMode: nil))
        #expect(StudioCatalog.tool("video.from-images")?.family == .video)
    }
}
