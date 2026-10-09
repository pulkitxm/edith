import Foundation
import Testing

@testable import EdithStudio

@Suite(.enabled(if: MediaFixtures.available)) struct MediaAuditAudioTests {
    static let island = "if(between(t,1,2),0.5*sin(2*PI*440*t),0)"

    func near(_ value: Double?, _ expected: Double, _ tolerance: Double) -> Bool {
        MediaFixtures.near(value, expected, tolerance: tolerance)
    }

    @Test func trimCutsAudioAtTheExactTimes() async throws {
        let space = try Workspace()
        let formats: [(String, [String], Double)] = [
            ("wav", [], 0.01), ("mp3", ["-c:a", "libmp3lame", "-b:a", "192k"], 0.04),
            ("m4a", ["-c:a", "aac"], 0.04), ("flac", ["-c:a", "flac"], 0.01),
        ]
        for (ext, codec, tolerance) in formats {
            let source = space.url("island.\(ext)")
            try await MediaAudit.sound(
                at: source, expression: Self.island, seconds: 3, codec: codec)
            let url = try await space.auditURL(
                "audio.trim", [source], ["range": .span(StudioSpan(start: 0.5, end: 2.5))])
            #expect(url.pathExtension == ext)
            let probe = try await MediaAudit.probe(url)
            #expect(near(probe.info.duration, 2, tolerance), "\(ext)")
            let silences = try await MediaAudit.silences(url)
            #expect(silences.count == 2, "\(ext)")
            #expect(near(silences.first?.end, 0.5, tolerance), "\(ext) \(silences)")
            #expect(near(silences.last?.start, 1.5, tolerance), "\(ext) \(silences)")
        }
    }

    @Test func trimFadesOutEvenWhenTheRangeRunsPastTheEnd() async throws {
        let space = try Workspace()
        let source = space.url("tone.wav")
        try await MediaAudit.tone(at: source, seconds: 3)
        let url = try await space.auditURL(
            "audio.trim", [source],
            [
                "range": .span(StudioSpan(start: 1, end: 10)), "fadeIn": .number(0.5),
                "fadeOut": .number(1),
            ])
        #expect(near(try await MediaAudit.probe(url).info.duration, 2, 0.01))
        let body = try await MediaAudit.meanVolume(url, from: 0.7, to: 0.9)
        #expect(try await MediaAudit.meanVolume(url, from: 0, to: 0.03) < body - 20)
        #expect(try await MediaAudit.meanVolume(url, from: 1.97) < body - 20)
    }

    @Test func fadeSilencesTheEdges() async throws {
        let space = try Workspace()
        for (ext, codec) in [("wav", [String]()), ("m4a", ["-c:a", "aac"])] {
            let source = space.url("tone.\(ext)")
            try await MediaAudit.tone(at: source, seconds: 3, codec: codec)
            let url = try await space.auditURL(
                "audio.fade", [source], ["fadeIn": .number(1), "fadeOut": .number(1)])
            #expect(near(try await MediaAudit.probe(url).info.duration, 3, 0.03), "\(ext)")
            let body = try await MediaAudit.meanVolume(source, from: 1.4, to: 1.6)
            #expect(abs(try await MediaAudit.meanVolume(url, from: 1.4, to: 1.6) - body) < 0.5)
            #expect(try await MediaAudit.meanVolume(url, from: 0, to: 0.05) < body - 20, "\(ext)")
            #expect(try await MediaAudit.meanVolume(url, from: 2.95) < body - 20, "\(ext)")
        }
    }

    @Test func volumeGainIsExactAndKeepsTheFormat() async throws {
        let space = try Workspace()
        let source = space.url("quiet.wav")
        try await MediaAudit.tone(
            at: source, seconds: 2, amplitude: 0.05, sampleRate: 44100, channels: 1,
            codec: ["-c:a", "pcm_s24le"])
        let original = try await MediaAudit.meanVolume(source)
        let louder = try await space.auditURL(
            "audio.volume", [source], ["mode": .text("adjust"), "gain": .number(6)])
        #expect(abs(try await MediaAudit.meanVolume(louder) - original - 6) < 0.3)
        let quieter = try await space.auditURL(
            "audio.volume", [source], ["mode": .text("adjust"), "gain": .number(-12)])
        #expect(abs(try await MediaAudit.meanVolume(quieter) - original + 12) < 0.3)
        let normalized = try await space.auditURL("audio.volume", [source])
        let loudness = try #require(try await MediaAudit.loudness(normalized))
        #expect(abs(loudness + 16) < 1.5)
        for url in [louder, normalized] {
            let probe = try await MediaAudit.probe(url)
            #expect(probe.info.sampleRate == 44100 && probe.info.channels == 1)
            #expect(probe.bitDepth == 24)
            #expect(near(probe.info.duration, 2, 0.01))
        }
    }

    @Test func speedKeepsOrShiftsThePitch() async throws {
        let space = try Workspace()
        let source = space.url("tone.wav")
        try await MediaAudit.tone(at: source, seconds: 2, sampleRate: 44100)
        let original = try #require(try await MediaAudit.zeroCrossings(source))
        let kept = try await space.auditURL("audio.speed", [source], ["speed": .text("2")])
        let keptProbe = try await MediaAudit.probe(kept)
        #expect(near(keptProbe.info.duration, 1, 0.02))
        #expect(keptProbe.info.sampleRate == 44100)
        let keptCrossings = try #require(try await MediaAudit.zeroCrossings(kept))
        #expect(abs(keptCrossings / original - 1) < 0.05)
        let shifted = try await space.auditURL(
            "audio.speed", [source], ["speed": .text("2"), "pitch": .bool(false)])
        #expect(near(try await MediaAudit.probe(shifted).info.duration, 1, 0.02))
        let shiftedCrossings = try #require(try await MediaAudit.zeroCrossings(shifted))
        #expect(abs(shiftedCrossings / original - 2) < 0.1)
        let slow = try await space.auditURL("audio.speed", [source], ["speed": .text("0.5")])
        #expect(near(try await MediaAudit.probe(slow).info.duration, 4, 0.03))
    }

    @Test func reverseMovesTheSoundToTheOtherEnd() async throws {
        let space = try Workspace()
        let source = space.url("blip.m4a")
        try await MediaAudit.sound(
            at: source, expression: "if(lt(t,0.5),0.5*sin(2*PI*440*t),0)", seconds: 2,
            codec: ["-c:a", "aac"])
        let url = try await space.auditURL("audio.reverse", [source])
        #expect(near(try await MediaAudit.probe(url).info.duration, 2, 0.05))
        #expect(try await MediaAudit.meanVolume(url, from: 0.1, to: 1.4) < -60)
        #expect(try await MediaAudit.meanVolume(url, from: 1.6, to: 1.9) > -15)
    }

    @Test func removeSilenceCutsOnlyTheLongPauses() async throws {
        let space = try Workspace()
        let source = space.url("talk.wav")
        let expression =
            "if(between(t,0.5,1.5)+between(t,1.9,2.9)+between(t,4.9,5.9),"
            + "0.5*sin(2*PI*300*t),0)"
        try await MediaAudit.sound(at: source, expression: expression, seconds: 6.5)
        let all = try await space.auditURL("audio.remove-silence", [source])
        let allDuration = try #require(try await MediaAudit.probe(all).info.duration)
        let pauses = try await MediaAudit.silences(all, minimum: 0.2)
        let silent = pauses.reduce(0) { $0 + min($1.end, allDuration) - $1.start }
        #expect(near(allDuration - silent, 3, 0.1), "\(pauses)")
        #expect((pauses.first?.start ?? 0) > 0.5, "\(pauses)")
        #expect(pauses.contains { abs($0.end - $0.start - 0.4) < 0.05 }, "\(pauses)")
        #expect(pauses.allSatisfy { min($0.end, allDuration) - $0.start < 0.9 }, "\(pauses)")
        #expect(allDuration < 5, "\(allDuration)")

        let ends = try await space.auditURL(
            "audio.remove-silence", [source], ["where": .text("ends")])
        #expect(near(try await MediaAudit.probe(ends).info.duration, 5.4, 0.05))
        let inside = try await MediaAudit.silences(ends, minimum: 0.2)
        #expect(inside.count == 2, "\(inside)")
        #expect(inside.contains { abs($0.end - $0.start - 2) < 0.05 }, "\(inside)")
    }

    @Test func denoiseLowersTheNoiseFloorAndKeepsTheLength() async throws {
        let space = try Workspace()
        let source = space.url("hiss.wav")
        try await MediaAudit.ffmpeg([
            "-f", "lavfi", "-i", "anoisesrc=a=0.05:c=white:s=48000:d=2", "-ac", "2", source.path,
        ])
        let before = try await MediaAudit.meanVolume(source)
        let url = try await space.auditURL(
            "audio.denoise", [source], ["strength": .text("strong")])
        #expect(near(try await MediaAudit.probe(url).info.duration, 2, 0.01))
        #expect(try await MediaAudit.meanVolume(url, from: 0.5, to: 1.5) < before - 6)
    }

    @Test func mergeJoinsMixedFormatsBackToBack() async throws {
        let space = try Workspace()
        let first = space.url("a.mp3")
        let second = space.url("b.wav")
        let third = space.url("c.m4a")
        try await MediaAudit.tone(
            at: first, seconds: 1, frequency: 300, sampleRate: 22050, channels: 1,
            codec: ["-c:a", "libmp3lame"])
        try await MediaAudit.sound(
            at: second, expression: "0", seconds: 1.5, sampleRate: 44100, channels: 2)
        try await MediaAudit.tone(
            at: third, seconds: 1, sampleRate: 48000, channels: 6, codec: ["-c:a", "aac"])
        let plain = try await space.auditURL(
            "audio.merge", [first, second, third], ["format": .text("wav")])
        let probe = try await MediaAudit.probe(plain)
        #expect(near(probe.info.duration, 3.5, 0.06))
        #expect(probe.info.channels == 2 && probe.info.sampleRate == 48000)
        let gaps = try await MediaAudit.silences(plain, minimum: 0.5)
        #expect(gaps.count == 1)
        #expect(near(gaps.first?.start, 1, 0.06) && near(gaps.first?.end, 2.5, 0.06))

        let blended = try await space.auditURL(
            "audio.merge", [first, third], ["crossfade": .number(0.5), "format": .text("wav")])
        #expect(near(try await MediaAudit.probe(blended).info.duration, 1.5, 0.06))
        let long = try await space.audit(
            "audio.merge", [first, third], ["crossfade": .number(10), "format": .text("wav")])
        let longDuration = try #require(try await MediaAudit.probe(try long.url()).info.duration)
        #expect(near(longDuration, 1.2, 0.06), "\(longDuration)")
        #expect(long.notes.contains { $0.contains("shortened") })
        #expect(try await MediaAudit.meanVolume(try long.url(), from: longDuration - 0.15) > -20)
        let chain = try await space.auditURL(
            "audio.merge", [third, first, third],
            ["crossfade": .number(10), "format": .text("wav")])
        #expect(near(try await MediaAudit.probe(chain).info.duration, 2, 0.06))
    }

    @Test func convertKeepsChannelsRatesAndBitDepth() async throws {
        let space = try Workspace()
        let surround = space.url("surround.m4a")
        try await MediaAudit.tone(at: surround, seconds: 2, channels: 6, codec: ["-c:a", "aac"])
        for (format, channels) in [("mp3", 2), ("flac", 6), ("wav", 6), ("opus", 6)] {
            let probe = try await MediaAudit.probe(
                try await space.auditURL("audio.convert", [surround], ["format": .text(format)]))
            #expect(probe.info.channels == channels, "\(format)")
            #expect(near(probe.info.duration, 2, 0.06), "\(format)")
        }
        let mono = try await MediaAudit.probe(
            try await space.auditURL("audio.convert", [surround], ["mono": .bool(true)]))
        #expect(mono.info.channels == 1)

        let voice = space.url("voice.wav")
        try await MediaAudit.tone(at: voice, seconds: 1, sampleRate: 22050, channels: 1)
        for format in ["m4a", "mp3", "flac"] {
            let probe = try await MediaAudit.probe(
                try await space.auditURL("audio.convert", [voice], ["format": .text(format)]))
            #expect(probe.info.sampleRate == 22050 && probe.info.channels == 1, "\(format)")
        }

        let master = space.url("master.wav")
        try await MediaAudit.tone(at: master, seconds: 1, codec: ["-c:a", "pcm_s24le"])
        for format in ["flac", "wav", "aiff", "alac"] {
            let url = try await space.auditURL("audio.convert", [master], ["format": .text(format)])
            let probe = try await MediaAudit.probe(url)
            #expect(probe.bitDepth == 24, "\(format)")
            #expect(near(probe.info.duration, 1, 0.01), "\(format)")
        }
        let cd = space.url("cd.wav")
        try await MediaAudit.tone(at: cd, seconds: 1)
        let cdCopy = try await space.auditURL("audio.convert", [cd], ["format": .text("aiff")])
        #expect(try await MediaAudit.probe(cdCopy).bitDepth == 16)
    }

    @Test func compressShrinksAndKeepsTheLength() async throws {
        let space = try Workspace()
        let source = space.url("voice.wav")
        try await MediaAudit.tone(at: source, seconds: 3, sampleRate: 44100)
        let url = try await space.auditURL("audio.compress", [source])
        let probe = try await MediaAudit.probe(url)
        #expect(url.pathExtension == "m4a")
        #expect(near(probe.info.duration, 3, 0.05))
        #expect(StudioRunner.fileSize(url) < StudioRunner.fileSize(source) / 5)
        let extreme = try await MediaAudit.probe(
            try await space.auditURL("audio.compress", [source], ["level": .text("extreme")]))
        #expect(extreme.info.channels == 1 && near(extreme.info.duration, 3, 0.05))
        let rich = space.url("rich.m4a")
        try await MediaAudit.tone(at: rich, seconds: 3, codec: ["-c:a", "aac", "-b:a", "256k"])
        let smaller = try await space.auditURL("audio.compress", [rich])
        #expect(StudioRunner.fileSize(smaller) < StudioRunner.fileSize(rich))
    }

    @Test func toVideoCoversTheWholeSoundtrack() async throws {
        let space = try Workspace()
        let source = space.url("voice.m4a")
        try await MediaAudit.tone(
            at: source, seconds: 2.3, sampleRate: 22050, channels: 1, codec: ["-c:a", "aac"])
        let audioLength = try #require(try await MediaAudit.probe(source).info.duration)
        let wave = try await MediaAudit.probe(try await space.auditURL("audio.to-video", [source]))
        #expect(wave.info.width == 1280 && wave.info.height == 720)
        #expect(near(wave.duration("audio"), audioLength, 0.05))
        #expect(near(wave.duration("video"), audioLength, 0.08))
        let cover = space.url("cover.png")
        try Fixtures.image(at: cover, width: 400, height: 300)
        for size in ["1080x1080", "1080x1920"] {
            let probe = try await MediaAudit.probe(
                try await space.auditURL(
                    "audio.to-video", [source],
                    ["style": .text("cover"), "image": .text(cover.path), "size": .text(size)]))
            let parts = size.split(separator: "x").compactMap { Int($0) }
            #expect(probe.info.width == parts[0] && probe.info.height == parts[1])
            #expect(near(probe.duration("audio"), audioLength, 0.05), "\(size)")
            #expect(near(probe.duration("video"), audioLength, 0.5), "\(size)")
        }
    }
}
