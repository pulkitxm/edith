import CoreGraphics
import Foundation
import Testing

@testable import EdithStudio

@Suite(.enabled(if: MediaFixtures.available)) struct MediaAuditOrientationTests {
    @Test func phoneFixturesDisplayUpright() async throws {
        let space = try Workspace()
        for rotation in [90, 270] {
            let clip = space.url("phone-\(rotation).mp4")
            try await MediaAudit.marker(at: clip, width: 180, height: 320, rotation: rotation)
            let probe = try await MediaAudit.probe(clip)
            #expect(probe.info.width == 320 && probe.info.height == 180)
            #expect(probe.displayWidth == 180 && probe.displayHeight == 320)
            let frame = try await MediaAudit.frame(clip, at: 0.5, in: space)
            #expect(frame.redCorner == .topLeft && frame.greenCorner == .bottomRight)
        }
    }

    @Test func reencodingToolsKeepAPhoneClipUpright() async throws {
        let space = try Workspace()
        let clip = space.url("phone.mp4")
        try await MediaAudit.marker(at: clip, width: 180, height: 320, rotation: 90)
        let runs: [(String, [String: StudioValue])] = [
            ("video.compress", [:]), ("video.compress", ["codec": .text("hevc")]),
            ("video.compress", ["mode": .text("size"), "targetMB": .number(0.2)]),
            ("video.trim", ["range": .span(StudioSpan(start: 0.2, end: 0.8))]),
            ("video.convert", ["format": .text("avi")]),
            ("video.convert", ["format": .text("mp4"), "fast": .bool(false)]),
            ("video.fps", ["fps": .text("15")]), ("video.adjust", [:]), ("video.denoise", [:]),
            ("video.stabilize", [:]),
            ("video.fade", ["fadeIn": .number(0), "fadeOut": .number(0.2)]),
            ("video.loop", ["times": .number(2)]), ("video.speed", [:]), ("video.reverse", [:]),
            ("video.split", ["mode": .text("parts"), "parts": .number(2)]),
        ]
        for (id, values) in runs {
            let result = try await space.audit(id, [clip], values)
            for output in result.outputs {
                let probe = try await MediaAudit.probe(output.url)
                let copied = id == "video.compress" && result.notes.count == 1
                #expect(probe.info.rotation == 0 || copied, "\(id) \(values)")
                #expect(probe.displayWidth == 180 && probe.displayHeight == 320, "\(id) \(values)")
                let frame = try await MediaAudit.frame(output.url, at: 0.3, in: space)
                #expect(frame.redCorner == .topLeft, "\(id) \(values)")
                #expect(frame.greenCorner == .bottomRight, "\(id) \(values)")
            }
        }
    }

    @Test func streamCopyToolsKeepTheRotationFlag() async throws {
        let space = try Workspace()
        let music = space.url("music.m4a")
        try await MediaAudit.tone(at: music, seconds: 1, codec: ["-c:a", "aac"])
        let srt = space.url("captions.srt")
        try "1\n00:00:00,100 --> 00:00:00,900\nHi\n".write(
            to: srt, atomically: true, encoding: .utf8)
        for ext in ["mp4", "mov"] {
            let clip = space.url("phone-\(ext).\(ext)")
            try await MediaAudit.marker(at: clip, width: 180, height: 320, rotation: 270)
            let runs: [(String, [String: StudioValue])] = [
                ("video.mute", [:]),
                (
                    "video.trim",
                    ["range": .span(StudioSpan(start: 0, end: 0.6)), "precision": .text("fast")]
                ),
                ("video.convert", ["format": .text(ext == "mp4" ? "mov" : "mp4")]),
                ("video.convert", ["format": .text("mkv")]),
                ("video.volume", ["mode": .text("adjust"), "gain": .number(-3)]),
                ("video.add-audio", ["audio": .text(music.path)]),
                ("video.subtitles", ["subtitles": .text(srt.path), "mode": .text("track")]),
            ]
            for (id, values) in runs {
                let url = try await space.auditURL(id, [clip], values)
                let probe = try await MediaAudit.probe(url)
                #expect(probe.info.videoCodec == "h264", "\(id) \(ext)")
                #expect(probe.displayWidth == 180 && probe.displayHeight == 320, "\(id) \(ext)")
                let frame = try await MediaAudit.frame(url, at: 0.3, in: space)
                #expect(frame.redCorner == .topLeft, "\(id) \(ext)")
            }
        }
    }

    @Test func framesGifsAndSmallerCopiesOfAPhoneClipStayUpright() async throws {
        let space = try Workspace()
        let phone = space.url("phone.mp4")
        try await MediaAudit.marker(at: phone, width: 480, height: 640, rotation: 90)
        for format in ["jpg", "png"] {
            let still = try await space.auditURL(
                "video.frames", [phone], ["mode": .text("thumbnail"), "format": .text(format)])
            let image = try MediaAudit.image(still)
            #expect(image.width == 480 && image.height == 640, "\(format)")
            #expect(image.redCorner == .topLeft && image.greenCorner == .bottomRight, "\(format)")
        }
        let narrow = try await space.audit(
            "video.frames", [phone], ["seconds": .number(0.5), "width": .text("320")])
        for output in narrow.outputs {
            let image = try MediaAudit.image(output.url)
            #expect(image.width == 320 && abs(image.height - 427) <= 1)
            #expect(image.redCorner == .topLeft)
        }
        let smaller = try await space.auditURL(
            "video.compress", [phone], ["maxHeight": .text("360")])
        let smallerProbe = try await MediaAudit.probe(smaller)
        #expect(smallerProbe.displayWidth == 360 && smallerProbe.displayHeight == 480)
        #expect(try await MediaAudit.frame(smaller, at: 0.5, in: space).redCorner == .topLeft)
        let gif = try await space.auditURL("video.convert", [phone], ["format": .text("gif")])
        let gifFrame = try #require(try StudioImageIO.frames(gif).first?.image)
        #expect(gifFrame.width == 480 && gifFrame.height == 640)
        #expect(Bitmap(gifFrame).redCorner == .topLeft)
    }

    @Test func rotateTurnsThePictureAsDisplayed() async throws {
        let space = try Workspace()
        let upright = space.url("upright.mp4")
        let phone = space.url("phone.mp4")
        try await MediaAudit.marker(at: upright, width: 320, height: 240)
        try await MediaAudit.marker(at: phone, width: 180, height: 320, rotation: 90)
        let turns: [(String, Bool, Corner, Corner)] = [
            ("right", true, .topRight, .bottomLeft), ("left", true, .bottomLeft, .topRight),
            ("180", false, .bottomRight, .topLeft), ("mirror", false, .topRight, .bottomLeft),
            ("flip", false, .bottomLeft, .topRight),
        ]
        for (clip, width, height) in [(upright, 320, 240), (phone, 180, 320)] {
            for (turn, swapped, red, green) in turns {
                let url = try await space.auditURL("video.rotate", [clip], ["turn": .text(turn)])
                let probe = try await MediaAudit.probe(url)
                #expect(probe.info.rotation == 0, "\(turn)")
                #expect(probe.displayWidth == (swapped ? height : width), "\(turn) \(width)")
                #expect(probe.displayHeight == (swapped ? width : height), "\(turn) \(width)")
                let frame = try await MediaAudit.frame(url, at: 0.5, in: space)
                #expect(frame.redCorner == red, "\(turn) \(width)")
                #expect(frame.greenCorner == green, "\(turn) \(width)")
            }
        }
    }

    @Test func cropPicksTheRegionYouSee() async throws {
        let space = try Workspace()
        let phone = space.url("phone.mp4")
        try await MediaAudit.marker(at: phone, width: 180, height: 320, rotation: 90)
        let topLeft = try await space.auditURL(
            "video.crop", [phone],
            ["mode": .text("area"), "area": .rect(StudioRect(x: 0, y: 0, width: 0.5, height: 0.5))])
        let topProbe = try await MediaAudit.probe(topLeft)
        #expect(topProbe.displayWidth == 90 && topProbe.displayHeight == 160)
        let top = try await MediaAudit.frame(topLeft, at: 0.5, in: space)
        #expect(top.fraction(x: 0...0.45, y: 0...0.45, where: MediaAudit.isRed) > 0.9)
        #expect(top.fraction(x: 0.55...1, y: 0.55...1, where: MediaAudit.isRed) == 0)

        let bottomRight = try await space.auditURL(
            "video.crop", [phone],
            [
                "mode": .text("area"),
                "area": .rect(StudioRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)),
            ])
        let bottom = try await MediaAudit.frame(bottomRight, at: 0.5, in: space)
        #expect(bottom.fraction(x: 0.55...1, y: 0.55...1, where: MediaAudit.isGreen) > 0.9)
        #expect(bottom.fraction(x: 0...1, y: 0...1, where: MediaAudit.isRed) == 0)

        let square = try await MediaAudit.probe(
            try await space.auditURL("video.crop", [phone], ["aspect": .text("1:1")]))
        #expect(square.displayWidth == 180 && square.displayHeight == 180)
        let wide = try await MediaAudit.probe(
            try await space.auditURL("video.crop", [phone], ["aspect": .text("16:9")]))
        #expect(wide.displayWidth == 180 && wide.displayHeight == 100)

        let boxed = space.url("boxed.mp4")
        try await MediaAudit.video(
            at: boxed,
            source: MediaAudit.markerSource(width: 180, height: 240, seconds: 1, rate: "25"),
            seconds: 1, filter: "pad=180:320:0:40:black", rotation: 90)
        let unboxed = try await space.auditURL("video.crop", [boxed], ["mode": .text("auto")])
        let unboxedProbe = try await MediaAudit.probe(unboxed)
        #expect(unboxedProbe.displayWidth == 180 && unboxedProbe.displayHeight == 240)
        let unboxedFrame = try await MediaAudit.frame(unboxed, at: 0.5, in: space)
        #expect(unboxedFrame.redCorner == .topLeft && unboxedFrame.greenCorner == .bottomRight)
    }

    @Test func resizeFollowsTheDisplayedOrientation() async throws {
        let space = try Workspace()
        let phone = space.url("phone.mp4")
        try await MediaAudit.marker(at: phone, width: 180, height: 320, rotation: 270)
        let narrow = try await space.auditURL(
            "video.resize", [phone], ["size": .text("custom"), "width": .number(90)])
        let narrowProbe = try await MediaAudit.probe(narrow)
        #expect(narrowProbe.displayWidth == 90 && narrowProbe.displayHeight == 160)
        #expect(try await MediaAudit.frame(narrow, at: 0.5, in: space).redCorner == .topLeft)
        let bigger = try await space.auditURL(
            "video.resize", [phone], ["size": .text("360"), "upscale": .bool(true)])
        let biggerProbe = try await MediaAudit.probe(bigger)
        #expect(biggerProbe.displayWidth == 360 && biggerProbe.displayHeight == 640)
        #expect(try await MediaAudit.frame(bigger, at: 0.5, in: space).redCorner == .topLeft)
        await #expect(throws: StudioError.self) {
            try await space.audit("video.resize", [phone], ["size": .text("360")])
        }
    }

    @Test func watermarkLandsAtTheChosenAnchor() async throws {
        let space = try Workspace()
        let logo = space.url("logo.png")
        try MediaAudit.solidPNG(at: logo, width: 40, height: 40, red: 1, green: 0, blue: 0)
        let landscape = space.url("landscape.mp4")
        let phone = space.url("phone.mp4")
        try await MediaAudit.plain(at: landscape, width: 320, height: 180)
        try await MediaAudit.plain(at: phone, width: 180, height: 320, rotation: 90)
        for (clip, width) in [(landscape, 320), (phone, 180)] {
            for anchor in ["top-left", "bottom-right", "top-right"] {
                let url = try await space.auditURL(
                    "video.watermark", [clip],
                    [
                        "kind": .text("image"), "image": .text(logo.path),
                        "position": .text(anchor), "size": .number(0.25), "opacity": .number(1),
                    ])
                let opening = try await MediaAudit.frame(url, at: 0, in: space)
                let closing = try await MediaAudit.lastFrame(url, in: space)
                #expect(opening.bounds(where: MediaAudit.isRed) != nil, "\(anchor)")
                #expect(closing.bounds(where: MediaAudit.isRed) != nil, "\(anchor)")
                let frame = try await MediaAudit.frame(url, at: 0.5, in: space)
                #expect(frame.width == width)
                let box = try #require(frame.bounds(where: MediaAudit.isRed), "\(anchor)")
                #expect(abs(box.width - Double(width) * 0.25) <= 3, "\(anchor) \(box)")
                let margin = Double(min(frame.width, frame.height)) * 0.04
                let left = box.minX <= margin + 2
                let right = box.maxX >= Double(frame.width) - margin - 2
                let top = box.minY <= margin + 2
                let bottom = box.maxY >= Double(frame.height) - margin - 2
                switch anchor {
                case "top-left": #expect(left && top && !right && !bottom, "\(width) \(box)")
                case "top-right": #expect(right && top && !left && !bottom, "\(width) \(box)")
                default: #expect(right && bottom && !left && !top, "\(width) \(box)")
                }
            }
        }
        let text = try await space.auditURL(
            "video.watermark", [phone],
            ["text": .text("EDITH"), "position": .text("top-right"), "opacity": .number(1)])
        let frame = try await MediaAudit.frame(text, at: 0.5, in: space)
        let white = try #require(frame.bounds(where: MediaAudit.isWhite))
        #expect(white.minX > Double(frame.width) * 0.5 && white.maxY < Double(frame.height) * 0.3)
    }

    @Test func burnedCaptionsFollowTheDisplayedFrame() async throws {
        let space = try Workspace()
        let phone = space.url("phone.mp4")
        try await MediaAudit.plain(at: phone, width: 180, height: 320, seconds: 2, rotation: 270)
        let srt = space.url("captions.srt")
        try "1\n00:00:00,500 --> 00:00:01,500\nHello there\n".write(
            to: srt, atomically: true, encoding: .utf8)
        for place in ["bottom", "top"] {
            let url = try await space.auditURL(
                "video.subtitles", [phone],
                ["subtitles": .text(srt.path), "place": .text(place), "box": .bool(false)])
            let probe = try await MediaAudit.probe(url)
            #expect(probe.displayWidth == 180 && probe.displayHeight == 320)
            #expect(MediaFixtures.near(probe.info.duration, 2, tolerance: 0.05))
            let during = try await MediaAudit.frame(url, at: 1.0, in: space)
            let near = place == "bottom" ? 0.75...1.0 : 0.0...0.25
            let far = place == "bottom" ? 0.0...0.6 : 0.4...1.0
            #expect(
                during.fraction(x: 0...1, y: near, where: MediaAudit.isWhite) > 0.01, "\(place)")
            #expect(during.fraction(x: 0...1, y: far, where: MediaAudit.isWhite) == 0, "\(place)")
            let after = try await MediaAudit.frame(url, at: 1.8, in: space)
            #expect(after.fraction(x: 0...1, y: 0...1, where: MediaAudit.isWhite) == 0, "\(place)")
        }
    }

    @Test func subtitleFilesInLegacyEncodingsWork() async throws {
        let space = try Workspace()
        let clip = space.url("clip.mp4")
        try await MediaAudit.plain(at: clip, width: 320, height: 180, seconds: 2)
        let srt = space.url("legacy.srt")
        var bytes = Data("1\r\n00:00:00,500 --> 00:00:01,500\r\nCaf".utf8)
        bytes += Data([0xE9, 0x20, 0x93]) + Data("quoted".utf8) + Data([0x94, 0x0D, 0x0A])
        try bytes.write(to: srt)
        let tracked = try await space.auditURL(
            "video.subtitles", [clip], ["subtitles": .text(srt.path), "mode": .text("track")])
        #expect(try await MediaAudit.probe(tracked).count("subtitle") == 1)
        let extracted = space.url("extracted.srt")
        try await MediaAudit.ffmpeg(["-i", tracked.path, "-map", "0:s:0", extracted.path])
        let text = try String(contentsOf: extracted, encoding: .utf8)
        #expect(text.contains("Café \u{201C}quoted\u{201D}"), "\(text)")
        let burned = try await space.auditURL(
            "video.subtitles", [clip],
            ["subtitles": .text(srt.path), "box": .bool(false), "size": .number(0.12)])
        let frame = try await MediaAudit.frame(burned, at: 1, in: space)
        #expect(frame.fraction(x: 0...1, y: 0.7...1, where: MediaAudit.isWhite) > 0.01)

        let webm = space.url("clip.webm")
        try await MediaAudit.marker(at: webm, width: 160, height: 90, codec: MediaAudit.vp9)
        let vtt = space.url("captions.vtt")
        try "WEBVTT\n\n00:00.200 --> 00:00.800\nHello\n".write(
            to: vtt, atomically: true, encoding: .utf8)
        let mkv = try await space.auditURL(
            "video.subtitles", [webm], ["subtitles": .text(vtt.path), "mode": .text("track")])
        #expect(mkv.pathExtension == "mkv")
        let mkvProbe = try await MediaAudit.probe(mkv)
        #expect(mkvProbe.count("subtitle") == 1 && mkvProbe.info.hasAudio)
    }

    @Test func slideshowKeepsPhotoOrientation() async throws {
        let space = try Workspace()
        let photo = space.url("portrait.jpg")
        try Fixtures.image(at: photo, width: 400, height: 300, format: .jpeg, orientation: 6)
        let url = try await space.auditURL(
            "video.from-images", [photo], ["seconds": .number(1), "size": .text("1280x720")])
        let frame = try await MediaAudit.frame(url, at: 0.5, in: space)
        #expect(frame.pixel(250, 360).r < 20 && frame.pixel(250, 360).g < 20)
        #expect(frame.pixel(640, 360).r > 100)
        let content = try #require(frame.bounds(where: { $0.r > 60 || $0.g > 60 }))
        #expect(abs(content.width - 540) <= 4 && abs(content.height - 720) <= 4, "\(content)")
    }

    @Test func socialPresetsHaveExactShapesWithoutDistortion() async throws {
        let space = try Workspace()
        let square = "drawbox=x=(iw-60)/2:y=(ih-60)/2:w=60:h=60:color=red:t=fill"
        let landscape = space.url("landscape.mp4")
        let phone = space.url("phone.mp4")
        try await MediaAudit.video(
            at: landscape,
            source: "color=c=\(MediaAudit.blue):size=320x180:rate=25:duration=1", seconds: 1,
            filter: square)
        try await MediaAudit.video(
            at: phone, source: "color=c=\(MediaAudit.blue):size=180x320:rate=25:duration=1",
            seconds: 1, filter: square, rotation: 90)
        let runs: [(URL, String, String, Int, Int)] = [
            (landscape, "9:16", "blur", 720, 1280), (landscape, "1:1", "bars", 720, 720),
            (landscape, "4:5", "crop", 720, 900), (landscape, "16:9", "blur", 1280, 720),
            (landscape, "9:16", "crop", 720, 1280), (phone, "16:9", "bars", 1280, 720),
            (phone, "9:16", "blur", 720, 1280), (phone, "1:1", "crop", 720, 720),
            (phone, "4:5", "blur", 720, 900),
        ]
        for (clip, shape, fill, width, height) in runs {
            let url = try await space.auditURL(
                "video.social", [clip],
                ["shape": .text(shape), "fill": .text(fill), "quality": .text("720")])
            let probe = try await MediaAudit.probe(url)
            let label = "\(clip.lastPathComponent) \(shape) \(fill)"
            #expect(probe.displayWidth == width && probe.displayHeight == height, "\(label)")
            #expect(probe.info.hasAudio, "\(label)")
            let frame = try await MediaAudit.frame(url, at: 0.5, in: space)
            let span = frame.span(through: width / 2, height / 2, where: MediaAudit.isRed)
            #expect(span.horizontal > 20, "\(label)")
            let ratio = Double(span.horizontal) / Double(max(span.vertical, 1))
            #expect(abs(ratio - 1) < 0.06, "\(label) \(span)")
        }
    }

    @Test func oddSizedVideosComeOutEvenAndUpright() async throws {
        let space = try Workspace()
        let odd = space.url("odd.mp4")
        try await MediaAudit.marker(
            at: odd, width: 641, height: 361, codec: MediaAudit.fullChroma)
        let srt = space.url("captions.srt")
        try "1\n00:00:00,100 --> 00:00:00,900\nHi\n".write(
            to: srt, atomically: true, encoding: .utf8)
        let runs: [(String, [String: StudioValue], Corner)] = [
            ("video.compress", [:], .topLeft),
            ("video.compress", ["codec": .text("hevc")], .topLeft),
            ("video.trim", ["range": .span(StudioSpan(start: 0.1, end: 0.9))], .topLeft),
            ("video.rotate", [:], .topRight), ("video.watermark", [:], .topLeft),
            ("video.subtitles", ["subtitles": .text(srt.path)], .topLeft),
            ("video.speed", [:], .topLeft), ("video.fps", ["fps": .text("24")], .topLeft),
            ("video.adjust", ["saturation": .number(1)], .topLeft), ("video.loop", [:], .topLeft),
            ("video.reverse", [:], .topLeft),
            ("video.convert", ["format": .text("webm")], .topLeft),
            ("video.resize", ["size": .text("custom"), "width": .number(321)], .topLeft),
            (
                "video.social",
                ["quality": .text("720"), "fill": .text("bars"), "shape": .text("16:9")], .topLeft
            ),
            ("video.stabilize", [:], .topLeft), ("video.denoise", [:], .topLeft),
            ("video.fade", ["fadeIn": .number(0)], .topLeft),
        ]
        for (id, values, corner) in runs {
            let url = try await space.auditURL(id, [odd], values)
            let probe = try await MediaAudit.probe(url)
            let width = try #require(probe.info.width, "\(id)")
            let height = try #require(probe.info.height, "\(id)")
            #expect(width % 2 == 0 && height % 2 == 0, "\(id) \(width)x\(height)")
            let frame = try await MediaAudit.frame(url, at: 0.3, in: space)
            #expect(frame.redCorner == corner, "\(id)")
        }
        let merged = try await MediaAudit.probe(
            try await space.auditURL("video.merge", [odd, odd]))
        #expect(merged.info.width == 640 && merged.info.height == 360)
        let cropped = try await MediaAudit.probe(try await space.auditURL("video.crop", [odd]))
        #expect(cropped.info.width == 360 && cropped.info.height == 360)
    }

    @Test func hevcProResAndWebMInputs() async throws {
        let space = try Workspace()
        let hevc = space.url("iphone.mov")
        try await MediaAudit.marker(
            at: hevc, width: 180, height: 320, codec: MediaAudit.hevc, rotation: 270)
        let converted = try await space.auditURL("video.convert", [hevc], ["format": .text("mp4")])
        let convertedProbe = try await MediaAudit.probe(converted)
        #expect(convertedProbe.info.videoCodec == "hevc")
        #expect(convertedProbe.stream("video")?["codec_tag_string"] as? String == "hvc1")
        #expect(convertedProbe.displayWidth == 180 && convertedProbe.displayHeight == 320)
        #expect(try await MediaAudit.frame(converted, at: 0.5, in: space).redCorner == .topLeft)
        let trimmed = try await space.auditURL(
            "video.trim", [hevc], ["range": .span(StudioSpan(start: 0.2, end: 0.8))])
        #expect(trimmed.pathExtension == "mov")
        let trimmedProbe = try await MediaAudit.probe(trimmed)
        #expect(trimmedProbe.displayWidth == 180 && trimmedProbe.displayHeight == 320)
        #expect(MediaFixtures.near(trimmedProbe.info.duration, 0.6, tolerance: 0.05))
        #expect(try await MediaAudit.frame(trimmed, at: 0.3, in: space).redCorner == .topLeft)

        let prores = space.url("master.mov")
        try await MediaAudit.marker(
            at: prores, codec: ["-c:v", "prores_ks", "-profile:v", "0", "-pix_fmt", "yuv422p10le"])
        let fromProRes = try await space.auditURL(
            "video.convert", [prores], ["format": .text("mp4")])
        let proresProbe = try await MediaAudit.probe(fromProRes)
        #expect(proresProbe.info.videoCodec == "h264" && proresProbe.info.hasAudio)
        #expect(try await MediaAudit.frame(fromProRes, at: 0.5, in: space).redCorner == .topLeft)

        let webm = space.url("clip.webm")
        try await MediaAudit.marker(at: webm, codec: MediaAudit.vp9)
        let webmTrim = try await space.auditURL(
            "video.trim", [webm], ["range": .span(StudioSpan(start: 0.5, end: nil))])
        #expect(webmTrim.pathExtension == "mp4")
        let webmProbe = try await MediaAudit.probe(webmTrim)
        #expect(MediaFixtures.near(webmProbe.info.duration, 0.5, tolerance: 0.05))
        #expect(webmProbe.info.hasAudio)
        let webmMuted = try await MediaAudit.probe(try await space.auditURL("video.mute", [webm]))
        #expect(webmMuted.info.hasVideo && !webmMuted.info.hasAudio)
    }

    @Test func mergeFitsMixedClipsIntoTheFirstFrame() async throws {
        let space = try Workspace()
        let first = space.url("first.mp4")
        let second = space.url("second.mp4")
        let third = space.url("third.mp4")
        try await MediaAudit.marker(at: first, width: 320, height: 240)
        try await MediaAudit.marker(
            at: second, width: 180, height: 320, rate: "30", audio: "mono", sampleRate: 22050,
            rotation: 90)
        try await MediaAudit.marker(
            at: third, width: 641, height: 361, seconds: 0.5, rate: "60", audio: nil,
            codec: MediaAudit.fullChroma)
        let url = try await space.auditURL("video.merge", [first, second, third])
        let probe = try await MediaAudit.probe(url)
        #expect(probe.info.width == 320 && probe.info.height == 240 && probe.info.rotation == 0)
        #expect(MediaFixtures.near(probe.duration("video"), 2.5, tolerance: 0.05))
        #expect(MediaFixtures.near(probe.duration("audio"), 2.5, tolerance: 0.05))
        #expect(probe.info.channels == 2 && probe.info.sampleRate == 48000)
        let one = try await MediaAudit.frame(url, at: 0.5, in: space)
        #expect(one.redCorner == .topLeft)
        let two = try await MediaAudit.frame(url, at: 1.5, in: space)
        #expect(MediaAudit.isRed(two.pixel(100, 20)))
        #expect(two.pixel(20, 20).b < 40 && two.pixel(20, 20).r < 40)
        #expect(MediaAudit.isGreen(two.pixel(220, 220)))
        let three = try await MediaAudit.frame(url, at: 2.25, in: space)
        #expect(MediaAudit.isRed(three.pixel(20, 50)))
        #expect(three.pixel(160, 10).b < 40)
        let quiet = try await MediaAudit.meanVolume(url, from: 2.05, to: 2.45)
        #expect(quiet < -80)
    }
}
