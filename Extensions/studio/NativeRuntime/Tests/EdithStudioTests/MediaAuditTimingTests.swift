import CoreGraphics
import Foundation
import Testing

@testable import EdithStudio

@Suite(.enabled(if: MediaFixtures.available)) struct MediaAuditTimingTests {
    static let frame = 0.041

    func moment(_ url: URL, at seconds: Double, in space: Workspace) async throws -> Double {
        MediaAudit.seconds(of: try await MediaAudit.frame(url, at: seconds, in: space))
    }

    func near(_ value: Double?, _ expected: Double, _ tolerance: Double = frame) -> Bool {
        MediaFixtures.near(value, expected, tolerance: tolerance)
    }

    @Test func trimCutsOnTheExactFrames() async throws {
        let space = try Workspace()
        let ramp = space.url("ramp.mp4")
        try await MediaAudit.ramp(at: ramp)
        let url = try await space.auditURL(
            "video.trim", [ramp], ["range": .span(StudioSpan(start: 1, end: 2))])
        let probe = try await MediaAudit.probe(url)
        #expect(near(probe.duration("video"), 1))
        #expect(near(probe.duration("audio"), 1, 0.03))
        #expect(try await MediaAudit.frameCount(url) == 25)
        #expect(near(try await moment(url, at: 0, in: space), 1))
        #expect(near(MediaAudit.seconds(of: try await MediaAudit.lastFrame(url, in: space)), 1.96))

        let tail = try await space.auditURL(
            "video.trim", [ramp], ["range": .span(StudioSpan(start: 2, end: 10))])
        #expect(near(try await MediaAudit.probe(tail).duration("video"), 1))

        let variable = space.url("variable.mp4")
        try await MediaAudit.ramp(at: variable, rate: "30", variable: true)
        let variableProbe = try await MediaAudit.probe(variable)
        let average = try #require(variableProbe.stream("video")?["avg_frame_rate"] as? String)
        #expect(average != "30/1")
        let cut = try await space.auditURL(
            "video.trim", [variable], ["range": .span(StudioSpan(start: 0.5, end: 2.5))])
        #expect(near(try await MediaAudit.probe(cut).info.duration, 2, 0.1))
        #expect(near(try await moment(cut, at: 0, in: space), 0.5))
        #expect(near(try await moment(cut, at: 1.6, in: space), 2.1, 0.1))
    }

    @Test func splitPiecesPickUpWhereThePreviousEnded() async throws {
        let space = try Workspace()
        let ramp = space.url("ramp.mp4")
        try await MediaAudit.ramp(at: ramp)
        let every = try await space.audit("video.split", [ramp], ["seconds": .number(1)])
        let pieces = every.outputs.map(\.url).sorted { $0.lastPathComponent < $1.lastPathComponent }
        #expect(pieces.count == 3)
        for (index, piece) in pieces.enumerated() {
            let probe = try await MediaAudit.probe(piece)
            #expect(near(probe.duration("video"), 1), "\(index)")
            #expect(near(probe.duration("audio"), 1, 0.06), "\(index)")
            #expect(near(try await moment(piece, at: 0, in: space), Double(index)), "\(index)")
        }
        let at = try await space.audit(
            "video.split", [ramp], ["mode": .text("at"), "times": .text("0:01.5")])
        let halves = at.outputs.map(\.url).sorted { $0.lastPathComponent < $1.lastPathComponent }
        #expect(halves.count == 2)
        let second = try #require(halves.last)
        #expect(near(try await MediaAudit.probe(second).duration("video"), 1.48))
        #expect(near(try await moment(second, at: 0, in: space), 1.52))
    }

    @Test func speedScalesTimeAndKeepsTheSoundInStep() async throws {
        let space = try Workspace()
        let ramp = space.url("ramp.mp4")
        try await MediaAudit.ramp(at: ramp)
        let double = try await space.auditURL("video.speed", [ramp], ["speed": .text("2")])
        let doubleProbe = try await MediaAudit.probe(double)
        #expect(near(doubleProbe.duration("video"), 1.5))
        #expect(near(doubleProbe.duration("audio"), 1.5, 0.05))
        #expect(near(try await moment(double, at: 0.5, in: space), 1, 0.08))
        let quadruple = try await space.auditURL("video.speed", [ramp], ["speed": .text("4")])
        let quadrupleProbe = try await MediaAudit.probe(quadruple)
        #expect(near(quadrupleProbe.duration("video"), 0.75, 0.05))
        #expect(try #require(quadrupleProbe.info.frameRate) <= 60.01)
        let slow = try await space.auditURL("video.speed", [ramp], ["speed": .text("0.5")])
        let slowProbe = try await MediaAudit.probe(slow)
        #expect(near(slowProbe.duration("video"), 6, 0.08))
        #expect(near(slowProbe.duration("audio"), 6, 0.05))
        #expect(near(try await moment(slow, at: 4, in: space), 2, 0.08))
    }

    @Test func loopRepeatsTheWholeClip() async throws {
        let space = try Workspace()
        let ramp = space.url("ramp.mp4")
        try await MediaAudit.ramp(at: ramp, seconds: 1)
        let url = try await space.auditURL("video.loop", [ramp], ["times": .number(3)])
        let probe = try await MediaAudit.probe(url)
        #expect(near(probe.duration("video"), 3))
        #expect(near(probe.duration("audio"), 3, 0.06))
        #expect(try await MediaAudit.frameCount(url) == 75)
        #expect(near(try await moment(url, at: 1.5, in: space), 0.5))
        #expect(near(try await moment(url, at: 2.02, in: space), 0))

        let early = space.url("early.mp4")
        try await MediaAudit.video(
            at: early,
            source: MediaAudit.markerSource(width: 160, height: 120, seconds: 2, rate: "25"),
            seconds: 2, sound: "sine=frequency=440:sample_rate=48000:duration=1", shortest: false)
        let twice = try await space.auditURL("video.loop", [early], ["times": .number(2)])
        let twiceProbe = try await MediaAudit.probe(twice)
        #expect(near(twiceProbe.duration("video"), 4))
        #expect(near(twiceProbe.duration("audio"), 4, 0.06))
        #expect(try await MediaAudit.meanVolume(twice, from: 1.2, to: 1.8) < -80)
        #expect(try await MediaAudit.meanVolume(twice, from: 2.2, to: 2.8) > -30)
    }

    @Test func reversePlaysPictureAndSoundBackwards() async throws {
        let space = try Workspace()
        let ramp = space.url("ramp.mp4")
        try await MediaAudit.ramp(
            at: ramp, seconds: 2,
            sound: "aevalsrc='if(lt(t,0.5),0.5*sin(2*PI*440*t),0)':s=48000:d=2")
        let url = try await space.auditURL("video.reverse", [ramp])
        let probe = try await MediaAudit.probe(url)
        #expect(near(probe.duration("video"), 2))
        #expect(near(probe.duration("audio"), 2, 0.05))
        #expect(near(try await moment(url, at: 0, in: space), 1.96))
        #expect(near(try await moment(url, at: 1.5, in: space), 0.46))
        #expect(try await MediaAudit.meanVolume(url, from: 0.1, to: 1.4) < -60)
        #expect(try await MediaAudit.meanVolume(url, from: 1.6, to: 1.95) > -15)
    }

    @Test func reverseSurvivesASoundtrackLongerThanThePicture() async throws {
        let space = try Workspace()
        let clip = space.url("long.mp4")
        try await MediaAudit.video(
            at: clip,
            source: "color=c=black:size=96x64:rate=30:duration=30,format=yuv420p,"
                + "geq=lum='16+T*6':cb=128:cr=128",
            seconds: 30,
            sound: "aevalsrc='if(between(t,29,29.5),0.5*sin(2*PI*440*t),0)':s=48000:d=30.3",
            shortest: false)
        let source = try await MediaAudit.probe(clip)
        #expect(near(source.duration("audio"), 30.3, 0.05))
        let url = try await space.auditURL("video.reverse", [clip])
        let probe = try await MediaAudit.probe(url)
        #expect(near(probe.duration("video"), 30, 0.1))
        #expect(near(probe.duration("audio"), 30, 0.1))
        let quiet = try await MediaAudit.silences(url, minimum: 0.2)
        #expect(near(quiet.first?.end, 0.5, 0.05), "\(quiet)")
        #expect(near(quiet.last?.start, 1, 0.05), "\(quiet)")
        let first = try await MediaAudit.frame(url, at: 0, in: space)
        #expect(abs(Double(first.centerGray) / (6 * 255 / 219) - 29.97) < 0.3)
        let last = try await MediaAudit.lastFrame(url, in: space)
        #expect(Double(last.centerGray) / (6 * 255 / 219) < 0.3)
    }

    @Test func mergeKeepsEveryClipInOrderAndInSync() async throws {
        let space = try Workspace()
        let ramp = space.url("ramp.mp4")
        let plain = space.url("plain.mp4")
        try await MediaAudit.ramp(at: ramp, seconds: 1, audio: nil)
        try await MediaAudit.plain(at: plain, width: 64, height: 48, seconds: 1)
        let url = try await space.auditURL("video.merge", [ramp, plain])
        let probe = try await MediaAudit.probe(url)
        #expect(near(probe.duration("video"), 2))
        #expect(near(probe.duration("audio"), 2, 0.05))
        #expect(near(try await moment(url, at: 0.5, in: space), 0.5))
        let later = try await MediaAudit.frame(url, at: 1.5, in: space)
        #expect(later.pixel(32, 24).b > 120)
        #expect(try await MediaAudit.meanVolume(url, from: 0.05, to: 0.95) < -80)
        #expect(try await MediaAudit.meanVolume(url, from: 1.1, to: 1.9) > -30)
    }

    @Test func frameRateChangesKeepTheLength() async throws {
        let space = try Workspace()
        let ramp = space.url("ramp.mp4")
        try await MediaAudit.ramp(at: ramp, seconds: 2)
        let sixty = try await space.auditURL("video.fps", [ramp], ["fps": .text("60")])
        #expect(near(try await MediaAudit.probe(sixty).duration("video"), 2))
        #expect(abs(try await MediaAudit.frameCount(sixty) - 120) <= 1)
        let fifteen = try await space.auditURL("video.fps", [ramp], ["fps": .text("15")])
        #expect(try await MediaAudit.frameCount(fifteen) == 30)
        #expect(near(try await moment(fifteen, at: 1, in: space), 1, 0.07))
        let variable = space.url("variable.mp4")
        try await MediaAudit.ramp(at: variable, seconds: 2, rate: "30", variable: true)
        let steady = try await MediaAudit.probe(
            try await space.auditURL("video.fps", [variable], ["fps": .text("30")]))
        #expect(steady.stream("video")?["avg_frame_rate"] as? String == "30/1")
        #expect(near(steady.duration("video"), 2, 0.1))
    }

    @Test func intervalFramesAreTakenOnTheInterval() async throws {
        let space = try Workspace()
        let ramp = space.url("ramp.mp4")
        try await MediaAudit.ramp(at: ramp)
        let every = try await space.audit("video.frames", [ramp], ["seconds": .number(1)])
        let seconds = try every.outputs.map(\.url).sorted { $0.path < $1.path }.map {
            MediaAudit.seconds(of: try MediaAudit.image($0))
        }
        #expect(seconds.count == 3)
        for (index, value) in seconds.enumerated() {
            #expect(near(value, Double(index)), "\(index)")
        }
        let half = try await space.audit(
            "video.frames", [ramp], ["seconds": .number(0.5), "format": .text("png")])
        let halfSeconds = try half.outputs.map(\.url).sorted { $0.path < $1.path }.map {
            MediaAudit.seconds(of: try MediaAudit.image($0))
        }
        #expect(halfSeconds.count == 6)
        for (index, value) in halfSeconds.enumerated() {
            #expect(near(value, Double(index) * 0.5), "\(index)")
        }
    }

    @Test func countTimesAndThumbnailFramesMatchTheirTimes() async throws {
        let space = try Workspace()
        let ramp = space.url("ramp.mp4")
        try await MediaAudit.ramp(at: ramp)
        let count = try await space.audit(
            "video.frames", [ramp], ["mode": .text("count"), "count": .number(3)])
        let counted = try count.outputs.map(\.url).sorted { $0.path < $1.path }.map {
            MediaAudit.seconds(of: try MediaAudit.image($0))
        }
        #expect(counted.count == 3)
        for (index, value) in counted.enumerated() {
            #expect(near(value, Double(index) + 0.5), "\(index)")
        }
        let times = try await space.audit(
            "video.frames", [ramp],
            ["mode": .text("times"), "times": .text("0:01, 2.5"), "format": .text("png")])
        let timed = try times.outputs.map(\.url).sorted { $0.path < $1.path }.map {
            MediaAudit.seconds(of: try MediaAudit.image($0))
        }
        #expect(timed.count == 2)
        #expect(near(timed.first, 1) && near(timed.last, 2.5))
        let late = try await space.auditURL(
            "video.frames", [ramp], ["mode": .text("thumbnail"), "at": .number(2.99)])
        #expect(near(MediaAudit.seconds(of: try MediaAudit.image(late)), 2.96))
        let beyond = try await space.auditURL(
            "video.frames", [ramp], ["mode": .text("thumbnail"), "at": .number(30)])
        #expect(near(MediaAudit.seconds(of: try MediaAudit.image(beyond)), 1.5))
    }

    @Test func framesFromAVeryShortClip() async throws {
        let space = try Workspace()
        let ramp = space.url("short.mp4")
        try await MediaAudit.ramp(at: ramp, seconds: 0.2)
        let count = try await space.audit(
            "video.frames", [ramp], ["mode": .text("count"), "count": .number(10)])
        #expect(count.outputs.count == 10)
        #expect(count.notes.isEmpty)
        let every = try await space.audit("video.frames", [ramp], ["seconds": .number(1)])
        #expect(every.outputs.count == 1)
        let thumbnail = try await space.audit("video.frames", [ramp], ["mode": .text("thumbnail")])
        #expect(thumbnail.outputs.count == 1)
        let gif = try await space.auditURL("video.to-gif", [ramp], ["width": .text("original")])
        #expect(try StudioImageIO.frames(gif).count >= 2)
    }

    @Test func veryShortClipsWorkWithEveryTool() async throws {
        let space = try Workspace()
        let blink = space.url("blink.mp4")
        try await MediaAudit.marker(at: blink, width: 160, height: 120, seconds: 0.2)
        let music = space.url("music.m4a")
        try await MediaAudit.tone(at: music, seconds: 1, codec: ["-c:a", "aac"])
        let srt = space.url("captions.srt")
        try "1\n00:00:00,000 --> 00:00:00,100\nHi\n".write(
            to: srt, atomically: true, encoding: .utf8)
        let runs: [(String, [String: StudioValue], Double)] = [
            ("video.compress", [:], 0.2), ("video.compress", ["mode": .text("size")], 0.2),
            ("video.convert", ["format": .text("webm")], 0.2),
            ("video.trim", ["range": .span(StudioSpan(start: 0.04, end: 0.16))], 0.12),
            ("video.speed", [:], 0.1), ("video.speed", ["speed": .text("0.25")], 0.8),
            ("video.reverse", [:], 0.2), ("video.loop", ["times": .number(5)], 1),
            ("video.fade", [:], 0.2), ("video.stabilize", [:], 0.2), ("video.denoise", [:], 0.2),
            ("video.watermark", [:], 0.2), ("video.subtitles", ["subtitles": .text(srt.path)], 0.2),
            ("video.add-audio", ["audio": .text(music.path)], 0.2),
            ("video.social", ["quality": .text("720")], 0.2),
            ("video.fps", ["fps": .text("60")], 0.2),
            ("video.volume", [:], 0.2), ("video.mute", [:], 0.2), ("video.rotate", [:], 0.2),
        ]
        for (id, values, length) in runs {
            let url = try await space.auditURL(id, [blink], values)
            let probe = try await MediaAudit.probe(url)
            #expect(near(probe.duration("video"), length, 0.045), "\(id) \(values)")
        }
        let merged = try await space.auditURL("video.merge", [blink, blink])
        #expect(near(try await MediaAudit.probe(merged).duration("video"), 0.4, 0.045))
        let halves = try await space.audit(
            "video.split", [blink], ["mode": .text("parts"), "parts": .number(2)])
        #expect(halves.outputs.count == 2)
        let sound = try await MediaAudit.probe(
            try await space.auditURL("video.extract-audio", [blink], ["format": .text("wav")]))
        #expect(near(sound.info.duration, 0.2, 0.03))
    }

    @Test func gifHasTheRightFramesSizeAndStart() async throws {
        let space = try Workspace()
        let ramp = space.url("ramp.mp4")
        try await MediaAudit.ramp(at: ramp)
        let url = try await space.auditURL(
            "video.to-gif", [ramp],
            [
                "range": .span(StudioSpan(start: 1, end: 2)), "fps": .number(10),
                "width": .text("original"),
            ])
        let frames = try StudioImageIO.frames(url)
        #expect(frames.count == 10)
        #expect(abs(frames.reduce(0) { $0 + $1.delay } - 1) < 0.05)
        #expect(frames.first.map { $0.image.width } == 64)
        let first = try #require(frames.first?.image)
        #expect(near(MediaAudit.seconds(of: Bitmap(first)), 1, 0.06))

        let phone = space.url("phone.mp4")
        try await MediaAudit.marker(at: phone, width: 180, height: 320, rotation: 90)
        let upright = try await space.auditURL("video.to-gif", [phone])
        let uprightFrame = try #require(try StudioImageIO.frames(upright).first?.image)
        #expect(uprightFrame.width == 180 && uprightFrame.height == 320)
        #expect(Bitmap(uprightFrame).redCorner == .topLeft)

        let odd = space.url("odd.mp4")
        try await MediaAudit.marker(
            at: odd, width: 641, height: 361, seconds: 0.5, codec: MediaAudit.fullChroma)
        let small = try await space.auditURL("video.to-gif", [odd], ["width": .text("320")])
        let smallFrame = try #require(try StudioImageIO.frames(small).first?.image)
        #expect(smallFrame.width == 320 && abs(smallFrame.height - 180) <= 1)

        await #expect(throws: StudioError.self) {
            try await space.audit(
                "video.to-gif", [ramp], ["range": .span(StudioSpan(start: 5, end: nil))])
        }
        #expect(MediaAudit.outputs(space).count == 3)
    }

    @Test func extractAudioMatchesTheSoundtrack() async throws {
        let space = try Workspace()
        let surround = space.url("surround.mp4")
        try await MediaAudit.marker(at: surround, seconds: 2, audio: "5.1", sampleRate: 44100)
        let sourceAudio = try #require(try await MediaAudit.probe(surround).duration("audio"))
        let expectations: [(String, Int, Int)] = [
            ("mp3", 2, 44100), ("m4a", 6, 44100), ("wav", 6, 44100), ("flac", 6, 44100),
            ("opus", 6, 48000),
        ]
        for (format, channels, rate) in expectations {
            let url = try await space.auditURL(
                "video.extract-audio", [surround], ["format": .text(format)])
            let probe = try await MediaAudit.probe(url)
            #expect(!probe.info.hasVideo, "\(format)")
            #expect(probe.info.channels == channels, "\(format)")
            #expect(probe.info.sampleRate == rate, "\(format)")
            #expect(near(probe.info.duration, sourceAudio, 0.06), "\(format)")
        }
        let mono = space.url("mono.mov")
        try await MediaAudit.marker(at: mono, audio: "mono", sampleRate: 22050)
        let voice = try await MediaAudit.probe(
            try await space.auditURL("video.extract-audio", [mono], ["format": .text("wav")]))
        #expect(voice.info.channels == 1 && voice.info.sampleRate == 22050)
        let camera = space.url("camera.mov")
        try await MediaAudit.video(
            at: camera,
            source: MediaAudit.markerSource(width: 160, height: 120, seconds: 1, rate: "25"),
            seconds: 1, extra: ["-c:a", "pcm_s24le"])
        #expect(try await MediaAudit.probe(camera).bitDepth == 24)
        let master = try await MediaAudit.probe(
            try await space.auditURL("video.extract-audio", [camera], ["format": .text("wav")]))
        #expect(master.bitDepth == 24 && master.info.audioCodec == "pcm_s24le")
    }

    @Test func addAudioMixesOrReplacesAndFitsTheVideo() async throws {
        let space = try Workspace()
        let clip = space.url("clip.mp4")
        try await MediaAudit.marker(at: clip, seconds: 3)
        let music = space.url("music.m4a")
        try await MediaAudit.tone(at: music, seconds: 1, frequency: 660, codec: ["-c:a", "aac"])
        let original = try await MediaAudit.meanVolume(clip, from: 0.5, to: 2.5)
        let originalCrossings = try #require(try await MediaAudit.zeroCrossings(clip))

        let replaced = try await space.auditURL(
            "video.add-audio", [clip],
            [
                "audio": .text(music.path), "mode": .text("replace"), "volume": .number(1),
                "fadeOut": .number(0),
            ])
        let replacedProbe = try await MediaAudit.probe(replaced)
        #expect(near(replacedProbe.duration("audio"), 3, 0.05))
        #expect(try await MediaAudit.frameCount(replaced) == 75)
        #expect(try await MediaAudit.meanVolume(replaced, from: 2.2, to: 2.8) > -15)
        let replacedCrossings = try #require(try await MediaAudit.zeroCrossings(replaced))
        #expect(abs(replacedCrossings / originalCrossings - 1.5) < 0.1)

        let once = try await space.auditURL(
            "video.add-audio", [clip],
            [
                "audio": .text(music.path), "mode": .text("replace"), "loop": .bool(false),
                "fadeOut": .number(0),
            ])
        #expect(near(try await MediaAudit.probe(once).duration("audio"), 3, 0.05))
        #expect(try await MediaAudit.meanVolume(once, from: 0.2, to: 0.8) > -20)
        #expect(try await MediaAudit.meanVolume(once, from: 1.2, to: 2.8) < -80)

        let mixed = try await space.auditURL(
            "video.add-audio", [clip], ["audio": .text(music.path), "volume": .number(1)])
        #expect(near(try await MediaAudit.probe(mixed).duration("audio"), 3, 0.05))
        #expect(try await MediaAudit.meanVolume(mixed, from: 0.5, to: 1.0) > original + 2)
        #expect(abs(try await MediaAudit.meanVolume(mixed, from: 2.92, to: 2.98) - original) < 1.5)

        let early = space.url("early.mp4")
        try await MediaAudit.video(
            at: early,
            source: MediaAudit.markerSource(width: 160, height: 120, seconds: 3, rate: "25"),
            seconds: 3, sound: "sine=frequency=440:sample_rate=48000:duration=2", shortest: false)
        let padded = try await space.auditURL(
            "video.add-audio", [early], ["audio": .text(music.path), "fadeOut": .number(0)])
        #expect(near(try await MediaAudit.probe(padded).duration("audio"), 3, 0.05))
        #expect(try await MediaAudit.meanVolume(padded, from: 2.3, to: 2.9) > -20)

        let long = space.url("long.m4a")
        try await MediaAudit.tone(at: long, seconds: 6, frequency: 660, codec: ["-c:a", "aac"])
        let trimmed = try await space.auditURL(
            "video.add-audio", [clip], ["audio": .text(long.path), "mode": .text("replace")])
        #expect(near(try await MediaAudit.probe(trimmed).duration("audio"), 3, 0.05))
    }

    @Test func fadeStartsAndEndsInBlackAndSilence() async throws {
        let space = try Workspace()
        let clip = space.url("clip.mp4")
        try await MediaAudit.marker(at: clip, seconds: 2)
        let url = try await space.auditURL(
            "video.fade", [clip], ["fadeIn": .number(0.5), "fadeOut": .number(0.5)])
        let probe = try await MediaAudit.probe(url)
        #expect(near(probe.duration("video"), 2))
        let first = try await MediaAudit.frame(url, at: 0, in: space)
        #expect(first.pixel(160, 120).b < 30)
        let middle = try await MediaAudit.frame(url, at: 1, in: space)
        #expect(middle.pixel(160, 120).b > 150)
        let last = try await MediaAudit.lastFrame(url, in: space)
        #expect(last.pixel(160, 120).b < 30)
        let original = try await MediaAudit.meanVolume(clip, from: 0.8, to: 1.2)
        #expect(try await MediaAudit.meanVolume(url, from: 0, to: 0.04) < original - 20)
        #expect(abs(try await MediaAudit.meanVolume(url, from: 0.8, to: 1.2) - original) < 1)
        #expect(try await MediaAudit.meanVolume(url, from: 1.96) < original - 20)
    }

    @Test func fadeAndMusicFollowThePictureWhenTheSoundRunsLonger() async throws {
        let space = try Workspace()
        let clip = space.url("clip.mp4")
        try await MediaAudit.video(
            at: clip,
            source: MediaAudit.markerSource(width: 160, height: 120, seconds: 2, rate: "25"),
            seconds: 2, sound: "sine=frequency=440:sample_rate=48000:duration=2.5", shortest: false)
        let faded = try await space.auditURL(
            "video.fade", [clip], ["fadeIn": .number(0), "fadeOut": .number(0.5)])
        let last = try await MediaAudit.lastFrame(faded, in: space)
        #expect(last.pixel(80, 60).b < 30)
        let original = try await MediaAudit.meanVolume(clip, from: 1, to: 1.4)
        #expect(try await MediaAudit.meanVolume(faded, from: 2.45) < original - 20)
        let music = space.url("music.m4a")
        try await MediaAudit.tone(at: music, seconds: 5, frequency: 660, codec: ["-c:a", "aac"])
        let scored = try await MediaAudit.probe(
            try await space.auditURL(
                "video.add-audio", [clip], ["audio": .text(music.path), "mode": .text("replace")]))
        #expect(near(scored.duration("audio"), 2, 0.05))
        #expect(near(scored.info.duration, 2, 0.05))
        let still = try await space.auditURL(
            "video.frames", [clip], ["mode": .text("times"), "times": .text("2.3")])
        #expect(try MediaAudit.image(still).pixel(80, 60).b > 150)
        let merged = try await space.auditURL("video.merge", [clip, clip])
        let mergedProbe = try await MediaAudit.probe(merged)
        #expect(near(mergedProbe.duration("video"), 4))
        #expect(near(mergedProbe.duration("audio"), 4, 0.05))
    }

    @Test func volumeChangesAreMeasurable() async throws {
        let space = try Workspace()
        let clip = space.url("clip.mov")
        try await MediaAudit.video(
            at: clip,
            source: MediaAudit.markerSource(width: 160, height: 120, seconds: 2, rate: "25"),
            seconds: 2, audio: "mono",
            sound: "aevalsrc='0.1*sin(2*PI*440*t)':s=44100:d=2")
        let original = try await MediaAudit.meanVolume(clip)
        let louder = try await space.auditURL(
            "video.volume", [clip], ["mode": .text("adjust"), "gain": .number(6)])
        #expect(abs(try await MediaAudit.meanVolume(louder) - original - 6) < 0.6)
        let louderProbe = try await MediaAudit.probe(louder)
        #expect(louderProbe.info.channels == 1 && louderProbe.info.sampleRate == 44100)
        #expect(try await MediaAudit.frameCount(louder) == 50)
        let quieter = try await space.auditURL(
            "video.volume", [clip], ["mode": .text("adjust"), "gain": .number(-10)])
        #expect(abs(try await MediaAudit.meanVolume(quieter) - original + 10) < 0.6)
        let normalized = try await space.auditURL("video.volume", [clip])
        let loudness = try #require(try await MediaAudit.loudness(normalized))
        #expect(abs(loudness + 16) < 1.5)
        #expect(near(try await MediaAudit.probe(normalized).duration("audio"), 2, 0.05))
    }

    @Test func stabilizeAndDenoiseKeepLengthAndSize() async throws {
        let space = try Workspace()
        let clip = space.url("clip.mp4")
        try await MediaAudit.video(
            at: clip, source: "testsrc2=size=320x240:rate=25:duration=2", seconds: 2,
            filter: "noise=alls=30:allf=t")
        for (id, values) in [
            ("video.stabilize", [:]), ("video.stabilize", ["strength": .text("strong")]),
            ("video.denoise", ["audio": .bool(true)]),
            ("video.denoise", ["strength": .text("strong")]),
        ] as [(String, [String: StudioValue])] {
            let url = try await space.auditURL(id, [clip], values)
            let probe = try await MediaAudit.probe(url)
            #expect(probe.info.width == 320 && probe.info.height == 240, "\(id)")
            #expect(near(probe.duration("video"), 2), "\(id)")
            #expect(near(probe.duration("audio"), 2, 0.05), "\(id)")
            #expect(try await MediaAudit.frameCount(url) == 50, "\(id)")
        }
    }
}

@Suite struct MediaAuditPlanningTests {
    @Test func reverseChunksFitInMemory() {
        let phone = StudioMediaInfo(width: 3840, height: 2160, frameRate: 60)
        #expect(Reverser.chunkLength(for: phone) <= 2)
        var hdr = StudioMediaInfo(width: 3840, height: 2160, frameRate: 30)
        hdr.pixelFormat = "yuv420p10le"
        #expect(Reverser.chunkLength(for: hdr) <= 2)
        let small = StudioMediaInfo(width: 320, height: 240, frameRate: 25)
        #expect(Reverser.chunkLength(for: small) == 10)
    }

    @Test func videoLengthsAreClampedToTheSource() {
        let span = StudioSpan(start: 2, end: 10)
        #expect(VideoInput.length(of: span, within: 3) == 1)
        #expect(VideoInput.length(of: span, within: nil) == 8)
        #expect(VideoInput.length(of: StudioSpan(start: 1, end: nil), within: 3) == 2)
    }
}
