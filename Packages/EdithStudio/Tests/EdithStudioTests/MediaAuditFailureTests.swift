import Foundation
import Testing

@testable import EdithStudio

@Suite(.enabled(if: MediaFixtures.available)) struct MediaAuditFailureTests {
    static var mediaTools: [StudioTool] {
        StudioCatalog.tools.filter {
            ($0.id.hasPrefix("video.") || $0.id.hasPrefix("audio.")) && $0.isRunnable
        }
    }

    struct Kit {
        let video: URL
        let silent: URL
        let audio: URL
        let music: URL
        let image: URL
        let subtitles: URL
    }

    func kit(_ space: Workspace) async throws -> Kit {
        let kit = Kit(
            video: space.url("clip.mp4"), silent: space.url("silent.mp4"),
            audio: space.url("tone.wav"), music: space.url("music.m4a"),
            image: space.url("photo.png"), subtitles: space.url("captions.srt"))
        try await MediaAudit.marker(at: kit.video, width: 160, height: 120)
        try await MediaAudit.marker(at: kit.silent, width: 160, height: 120, audio: nil)
        try await MediaAudit.tone(at: kit.audio, seconds: 1)
        try await MediaAudit.tone(at: kit.music, seconds: 1, codec: ["-c:a", "aac"])
        try Fixtures.image(at: kit.image, width: 64, height: 48)
        try "1\n00:00:00,100 --> 00:00:00,900\nHi\n".write(
            to: kit.subtitles, atomically: true, encoding: .utf8)
        return kit
    }

    func settings(for tool: StudioTool, kit: Kit) -> [String: StudioValue] {
        switch tool.id {
        case "video.add-audio": ["audio": .text(kit.music.path)]
        case "video.subtitles": ["subtitles": .text(kit.subtitles.path)]
        case "video.trim", "audio.trim": ["range": .span(StudioSpan(start: 0.1, end: 0.5))]
        default: [:]
        }
    }

    func inputs(for tool: StudioTool, primary: URL, kit: Kit) -> [URL] {
        if tool.id == "video.from-images" { return [kit.image] }
        return tool.arity.minimum > 1 ? [primary, primary] : [primary]
    }

    @Test func everyMediaToolReportsMissingFFmpeg() async throws {
        let space = try Workspace()
        let kit = try await kit(space)
        #expect(Self.mediaTools.count >= 37)
        for tool in Self.mediaTools {
            let primary = tool.id.hasPrefix("audio.") ? kit.audio : kit.video
            let error = await #expect(throws: StudioError.self, "\(tool.id)") {
                try await space.audit(
                    tool.id, inputs(for: tool, primary: primary, kit: kit),
                    settings(for: tool, kit: kit), environment: MediaAudit.bare(space))
            }
            #expect(error == .needsEngine(.ffmpeg), "\(tool.id)")
        }
        #expect(MediaAudit.outputs(space).isEmpty)
    }

    @Test func damagedFilesFailWithAClearErrorAndNoOutput() async throws {
        let space = try Workspace()
        let kit = try await kit(space)
        let empty = space.url("empty.mp4")
        let junk = space.url("junk.mp4")
        FileManager.default.createFile(atPath: empty.path, contents: Data())
        FileManager.default.createFile(
            atPath: junk.path, contents: Data((0..<6000).map { UInt8(($0 * 7919) % 251) }))
        let emptyAudio = space.url("empty.m4a")
        let junkAudio = space.url("junk.wav")
        FileManager.default.createFile(atPath: emptyAudio.path, contents: Data())
        FileManager.default.createFile(
            atPath: junkAudio.path, contents: Data((0..<6000).map { UInt8(($0 * 31) % 253) }))
        for tool in Self.mediaTools where tool.id != "video.from-images" {
            let damaged = tool.id.hasPrefix("audio.") ? [emptyAudio, junkAudio] : [empty, junk]
            for file in damaged {
                let error = await #expect(throws: StudioError.self, "\(tool.id) \(file)") {
                    try await space.audit(
                        tool.id, inputs(for: tool, primary: file, kit: kit),
                        settings(for: tool, kit: kit))
                }
                #expect(error != .cancelled, "\(tool.id)")
            }
        }
        #expect(MediaAudit.outputs(space).isEmpty)
    }

    @Test func truncatedRecordingsAreNotPassedOffAsComplete() async throws {
        let space = try Workspace()
        let whole = space.url("whole.mp4")
        try await MediaAudit.video(
            at: whole, source: "testsrc2=size=320x240:rate=25:duration=3", seconds: 3,
            extra: ["-movflags", "+faststart"])
        let data = try Data(contentsOf: whole)
        let cut = space.url("cut.mp4")
        try data.prefix(data.count / 2).write(to: cut)
        #expect(
            MediaFixtures.near(try await MediaAudit.probe(cut).info.duration, 3, tolerance: 0.1))
        let music = space.url("music.m4a")
        try await MediaAudit.tone(
            at: music, seconds: 3, codec: ["-c:a", "aac", "-movflags", "+faststart"])
        let srt = space.url("captions.srt")
        try "1\n00:00:00,100 --> 00:00:02,900\nHi\n".write(
            to: srt, atomically: true, encoding: .utf8)
        let runs: [(String, [String: StudioValue])] = [
            ("video.compress", [:]), ("video.convert", ["format": .text("mov")]),
            ("video.convert", ["format": .text("webm")]), ("video.mute", [:]),
            ("video.rotate", [:]), ("video.speed", [:]), ("video.loop", [:]),
            ("video.reverse", [:]), ("video.social", ["quality": .text("720")]),
            ("video.extract-audio", [:]), ("video.fade", [:]),
            ("video.volume", ["mode": .text("adjust")]),
            ("video.trim", ["range": .span(StudioSpan(start: 0.5, end: 2.5))]),
            ("video.split", ["mode": .text("parts"), "parts": .number(2)]),
            ("video.watermark", [:]), ("video.stabilize", [:]),
            ("video.subtitles", ["subtitles": .text(srt.path)]),
            ("video.add-audio", ["audio": .text(music.path)]), ("video.merge", [:]),
        ]
        for (id, values) in runs {
            let inputs = id == "video.merge" ? [cut, whole] : [cut]
            let error = await #expect(throws: StudioError.self, "\(id)") {
                try await space.audit(id, inputs, values)
            }
            #expect(error != .cancelled, "\(id)")
        }

        let cutMusic = space.url("cut-music.m4a")
        let fullMusic = try Data(contentsOf: music)
        try fullMusic.prefix(fullMusic.count / 2).write(to: cutMusic)
        for id in ["audio.convert", "audio.trim", "audio.fade", "audio.reverse"] {
            let values: [String: StudioValue] =
                id == "audio.trim" ? ["range": .span(StudioSpan(start: 0.1, end: nil))] : [:]
            await #expect(throws: StudioError.self, "\(id)") {
                try await space.audit(id, [cutMusic], values)
            }
        }
        #expect(MediaAudit.outputs(space).isEmpty)
    }

    @Test func toolsAskForTheStreamTheyNeed() async throws {
        let space = try Workspace()
        let kit = try await kit(space)
        let soundOnly = space.url("sound-only.mp4")
        try await MediaAudit.tone(at: soundOnly, seconds: 1, codec: ["-c:a", "aac"])
        let needsPicture = Self.mediaTools.filter {
            $0.id.hasPrefix("video.") && $0.id != "video.from-images"
                && $0.id != "video.extract-audio"
        }
        for tool in needsPicture {
            let error = await #expect(throws: StudioError.self, "\(tool.id)") {
                try await space.audit(
                    tool.id, inputs(for: tool, primary: soundOnly, kit: kit),
                    settings(for: tool, kit: kit))
            }
            let expected = StudioError.unsupportedInput(soundOnly.lastPathComponent, tool.title)
            #expect(error == expected, "\(tool.id)")
        }
        let extracted = try await MediaAudit.probe(
            try await space.auditURL("video.extract-audio", [soundOnly], ["format": .text("m4a")]))
        #expect(extracted.info.hasAudio && !extracted.info.hasVideo)
        for id in ["video.extract-audio", "video.volume"] {
            await #expect(throws: StudioError.nothingToDo("This video has no sound."), "\(id)") {
                try await space.audit(id, [kit.silent])
            }
        }
        await #expect(throws: StudioError.nothingToDo("This file has no sound.")) {
            try await space.audit("audio.convert", [kit.silent])
        }
        await #expect(
            throws: StudioError.unsupportedInput(kit.silent.lastPathComponent, "Add music")
        ) {
            try await space.audit("video.add-audio", [kit.video], ["audio": .text(kit.silent.path)])
        }
    }

    @Test func cancellingALongReverseStopsFFmpegQuickly() async throws {
        let space = try Workspace()
        let clip = space.url("long-\(UUID().uuidString).mp4")
        try await MediaAudit.video(
            at: clip, source: "testsrc2=size=320x240:rate=30:duration=40", seconds: 40)
        let task = Task { try await space.audit("video.reverse", [clip]) }
        try await Task.sleep(nanoseconds: 800_000_000)
        task.cancel()
        let started = Date()
        await #expect(throws: StudioError.cancelled) { try await task.value }
        #expect(Date().timeIntervalSince(started) < 3)
        try await Task.sleep(nanoseconds: 2_500_000_000)
        let pgrep = URL(fileURLWithPath: "/usr/bin/pgrep")
        let running = try await StudioProcess.run(pgrep, ["-f", clip.lastPathComponent])
        #expect(running.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(MediaAudit.outputs(space).isEmpty)
    }
}
