import Foundation

enum VideoTools {
    static let ffmpeg: [StudioRequirement] = [.engine(.ffmpeg)]
    static let gif: Set<String> = ["gif"]

    static var all: [StudioTool] {
        [
            edit, compress, convert, trim, split, merge, toGIF, extractAudio, frames, mute, rotate,
            crop, resize, speed, reverse, addAudio, volume, watermark, subtitles, loop, fps,
            fromImages, stabilize, denoise, fade, adjust, social,
        ]
    }

    static let edit = StudioTool(
        id: "video.edit", title: "Video editor",
        summary: "Cut, zoom, add text and transitions on a timeline, then export.",
        symbol: "film.stack", group: .edit, inputs: [.video], produces: .kind(.video),
        style: .editor(.video, pdfMode: nil),
        keywords: ["timeline", "cut", "zoom", "captions", "editor", "project"])

    static let compress = StudioTool(
        id: "video.compress", title: "Compress video",
        summary: "Shrink videos for sharing while keeping them sharp.",
        symbol: "arrow.down.right.and.arrow.up.left", group: .optimize, inputs: [.video],
        extraExtensions: gif,
        options: [
            .choice(
                "mode", "Aim for",
                [StudioChoice("quality", "Quality level"), StudioChoice("size", "Target size")],
                default: "quality"),
            .choice(
                "level", "Compression",
                [
                    StudioChoice("low", "Less"), StudioChoice("recommended", "Recommended"),
                    StudioChoice("extreme", "Extreme"),
                ], default: "recommended", when: .init("mode", ["quality"])),
            .number(
                "targetMB", "Target size", 0.05...20000, step: 1, default: 25, unit: "MB",
                help: "The whole file, sound included, aims to fit under this size.",
                when: .init("mode", ["size"])),
            .choice(
                "maxHeight", "Resolution",
                [
                    StudioChoice("original", "Original"), StudioChoice("1080", "1080p"),
                    StudioChoice("720", "720p"), StudioChoice("480", "480p"),
                    StudioChoice("360", "360p"),
                ], default: "original"),
            .choice(
                "codec", "Codec",
                [
                    StudioChoice("h264", "H.264 (plays everywhere)"),
                    StudioChoice("hevc", "HEVC (smaller)"),
                ], default: "h264", when: .init("mode", ["quality"])),
        ],
        requirements: ffmpeg, keywords: ["reduce", "shrink", "smaller", "size", "email"],
        actionTitle: "Compress"
    ) { run in
        let info = try await FFmpeg.info(run.input, run: run)
        guard info.hasVideo else {
            throw StudioError.unsupportedInput(run.input.lastPathComponent, "Compress video")
        }
        let output = run.output(for: run.input, suffix: "compressed", ext: "mp4")
        var filters: [String] = []
        let maxHeight = Int(run.settings.text("maxHeight"))
        if let maxHeight, let size = info.displaySize {
            let short = min(size.width, size.height)
            if Double(maxHeight) < short {
                filters.append(
                    size.width >= size.height ? "scale=-2:\(maxHeight)" : "scale=\(maxHeight):-2")
            }
        }
        filters.append(MediaEncoding.evenFilter)
        let filter = ["-vf", filters.joined(separator: ",")]
        let common = ["-i", run.input.path] + MediaEncoding.primaryStreams + filter
        if run.settings.text("mode") == "size" {
            guard let duration = info.duration, duration > 0 else {
                throw StudioError.unavailable("The length of this video is unknown.")
            }
            let audioKbps = info.hasAudio ? 96.0 : 0
            let totalKbps = run.settings.number("targetMB") * 8 * 1024 / duration
            let videoKbps = Int(totalKbps * 0.96 - audioKbps)
            guard videoKbps >= 40 else {
                throw StudioError.invalidOption(
                    "target size", "that is too small for a video this long")
            }
            let log = try run.scratch("passes").appendingPathComponent("pass").path
            let rate = [
                "-c:v", "libx264", "-preset", "medium", "-b:v", "\(videoKbps)k", "-pix_fmt",
                "yuv420p",
            ]
            _ = try await FFmpeg.execute(
                common + rate + [
                    "-pass", "1", "-passlogfile", log, "-an", "-f", "mp4", "/dev/null",
                ],
                run: run, expected: duration, range: 0...0.45)
            let audio = info.hasAudio ? ["-c:a", "aac", "-b:a", "96k"] : []
            _ = try await FFmpeg.execute(
                common + rate + ["-pass", "2", "-passlogfile", log] + audio
                    + MediaEncoding.finishing(container: "mp4") + [output.path],
                run: run, expected: duration, range: 0.45...1)
            return [output]
        }
        let level = run.settings.text("level")
        let hevc = run.settings.text("codec") == "hevc"
        let crf: Int
        switch level {
        case "low": crf = hevc ? 24 : 22
        case "extreme": crf = hevc ? 32 : 31
        default: crf = hevc ? 28 : 26
        }
        let video =
            hevc
            ? [
                "-c:v", "libx265", "-preset", "medium", "-crf", String(crf), "-tag:v", "hvc1",
                "-x265-params", "log-level=error", "-pix_fmt", "yuv420p",
            ]
            : ["-c:v", "libx264", "-preset", "medium", "-crf", String(crf), "-pix_fmt", "yuv420p"]
        let audioRate = level == "extreme" ? "96k" : "128k"
        _ = try await FFmpeg.execute(
            common + video + ["-c:a", "aac", "-b:a", audioRate]
                + MediaEncoding.finishing(container: "mp4") + [output.path],
            run: run, expected: info.duration)
        if maxHeight == nil, StudioRunner.fileSize(output) >= StudioRunner.fileSize(run.input),
            run.input.pathExtension.lowercased() == "mp4"
        {
            try FileManager.default.removeItem(at: output)
            try FileManager.default.copyItem(at: run.input, to: output)
            run.note("This video is already compressed well, so the copy is unchanged.")
        }
        return [output]
    }

    static let convert = StudioTool(
        id: "video.convert", title: "Convert video",
        summary: "Change a video to MP4, MOV, WebM, MKV, AVI or an animated GIF.",
        symbol: "arrow.triangle.2.circlepath", group: .convert, inputs: [.video],
        extraExtensions: gif,
        options: [
            .choice(
                "format", "Convert to",
                [
                    StudioChoice("mp4", "MP4"), StudioChoice("mov", "MOV"),
                    StudioChoice("m4v", "M4V"), StudioChoice("webm", "WebM"),
                    StudioChoice("mkv", "MKV"), StudioChoice("avi", "AVI"),
                    StudioChoice("gif", "GIF"),
                ], default: "mp4"),
            .toggle(
                "fast", "Copy streams when possible", default: true,
                help: "Skips re-encoding when the new container supports the original codecs."),
        ],
        requirements: ffmpeg, keywords: ["mp4", "mov", "webm", "mkv", "avi", "gif", "format"],
        actionTitle: "Convert"
    ) { run in
        let format = run.settings.text("format")
        let info = try await FFmpeg.info(run.input, run: run)
        let same = run.input.pathExtension.lowercased() == format
        let output = run.output(for: run.input, suffix: same ? "converted" : nil, ext: format)
        if format == "gif" {
            try await GIFEncoder.encode(
                run.input, to: output, fps: 12,
                width: min(480, info.displaySize.map { Int($0.width) } ?? 480),
                span: .whole, loop: true, run: run, duration: info.duration)
            return [output]
        }
        let video = info.videoCodec ?? ""
        let copyVideo: Bool
        switch format {
        case "webm": copyVideo = video == "vp9" || video == "vp8" || video == "av1"
        case "avi": copyVideo = video == "mpeg4" || video == "mjpeg"
        case "mkv": copyVideo = !video.isEmpty && video != "gif"
        default: copyVideo = ["h264", "hevc", "mpeg4"].contains(video)
        }
        let fast = run.settings.bool("fast") && copyVideo
        var arguments =
            ["-i", run.input.path] + MediaEncoding.primaryStreams + ["-map_metadata", "0"]
        if fast {
            arguments += ["-c:v", "copy"]
            if video == "hevc", ["mp4", "mov", "m4v"].contains(format) {
                arguments += ["-tag:v", "hvc1"]
            }
        } else {
            arguments += ["-vf", MediaEncoding.evenFilter] + MediaEncoding.video(container: format)
        }
        arguments += MediaEncoding.audio(container: format, source: info, allowCopy: fast)
        arguments += MediaEncoding.finishing(container: format) + [output.path]
        _ = try await FFmpeg.execute(arguments, run: run, expected: info.duration)
        return [output]
    }

    static let trim = StudioTool(
        id: "video.trim", title: "Trim video",
        summary: "Keep only the part of a video you need.",
        symbol: "timeline.selection", group: .edit, inputs: [.video], extraExtensions: gif,
        options: [
            .span(
                help: "Start and end, for example 0:05-0:12. Leave the end empty to keep the rest."),
            .choice(
                "precision", "Cut",
                [StudioChoice("exact", "Exact frame"), StudioChoice("fast", "Fast, at keyframes")],
                default: "exact"),
        ],
        requirements: ffmpeg, keywords: ["cut", "clip", "shorten", "range"], actionTitle: "Trim"
    ) { run in
        let info = try await FFmpeg.info(run.input, run: run)
        let span = run.settings.span("range")
        guard span.start > 0 || span.end != nil else {
            throw StudioError.invalidOption("range", "choose where the clip starts or ends")
        }
        if let total = info.duration, span.start >= total {
            throw StudioError.invalidOption("range", "the start is past the end of the video")
        }
        let length = span.duration(within: info.duration)
        let container = MediaEncoding.videoContainer(for: run.input)
        let output = run.output(for: run.input, suffix: "trimmed", ext: container)
        var arguments = ["-ss", FFmpeg.seconds(span.start), "-i", run.input.path]
        if let length { arguments += ["-t", FFmpeg.seconds(length)] }
        arguments += MediaEncoding.primaryStreams
        if run.settings.text("precision") == "fast",
            MediaEncoding.editableContainers.contains(run.input.pathExtension.lowercased())
        {
            arguments += ["-c", "copy", "-avoid_negative_ts", "make_zero"]
        } else {
            arguments +=
                ["-vf", MediaEncoding.evenFilter]
                + MediaEncoding.video(container: container, crf: 18)
            arguments += MediaEncoding.audio(container: container, source: info, allowCopy: false)
        }
        arguments += MediaEncoding.finishing(container: container) + [output.path]
        _ = try await FFmpeg.execute(arguments, run: run, expected: length)
        return [output]
    }

    static let split = StudioTool(
        id: "video.split", title: "Split video",
        summary: "Cut a video into equal parts, fixed-length pieces or at the times you choose.",
        symbol: "scissors", group: .organize, inputs: [.video],
        options: [
            .choice(
                "mode", "Split",
                [
                    StudioChoice("every", "Every N seconds"), StudioChoice("parts", "Equal parts"),
                    StudioChoice("at", "At times"),
                ], default: "every"),
            .number(
                "seconds", "Piece length", 1...36000, step: 1, default: 60, unit: "s",
                when: .init("mode", ["every"])),
            .integer("parts", "Parts", 2...100, default: 2, when: .init("mode", ["parts"])),
            .text(
                "times", "Split at", placeholder: "0:30, 1:15, 2:00", default: "",
                when: .init("mode", ["at"]), required: true),
        ],
        requirements: ffmpeg, keywords: ["cut", "segments", "pieces", "chapters"],
        groupsOutputs: true, actionTitle: "Split"
    ) { run in
        let info = try await FFmpeg.info(run.input, run: run)
        guard let duration = info.duration, duration > 0 else {
            throw StudioError.unavailable("The length of this video is unknown.")
        }
        var times: [Double]
        switch run.settings.text("mode") {
        case "parts":
            let parts = max(2, run.settings.int("parts"))
            times = (1..<parts).map { duration * Double($0) / Double(parts) }
        case "at":
            times = try run.settings.text("times").split(separator: ",").map {
                guard let value = StudioTime.parse(String($0)) else {
                    throw StudioError.invalidOption("split at", "\($0) is not a time")
                }
                return value
            }
        default:
            let piece = max(1, run.settings.number("seconds"))
            times = Array(stride(from: piece, to: duration, by: piece))
        }
        times = Array(Set(times.filter { $0 > 0.05 && $0 < duration - 0.05 })).sorted()
        guard !times.isEmpty else {
            throw StudioError.nothingToDo("The video is shorter than the first split point.")
        }
        let container = MediaEncoding.videoContainer(for: run.input)
        let stem = run.input.studioStem.replacingOccurrences(of: "%", with: "%%")
        let pattern = run.workDirectory.appendingPathComponent("\(stem)-part-%03d.\(container)")
        let list = times.map(FFmpeg.seconds).joined(separator: ",")
        var arguments = ["-i", run.input.path] + MediaEncoding.primaryStreams
        arguments +=
            ["-vf", MediaEncoding.evenFilter] + MediaEncoding.video(container: container, crf: 18)
        arguments += MediaEncoding.audio(container: container, source: info, allowCopy: false)
        arguments += [
            "-force_key_frames", list, "-f", "segment", "-segment_times", list,
            "-reset_timestamps", "1", "-segment_start_number", "1", pattern.path,
        ]
        _ = try await FFmpeg.execute(arguments, run: run, expected: duration)
        return MediaFiles.produced(in: run.workDirectory, prefix: run.input.studioStem + "-part-")
    }

    static let merge = StudioTool(
        id: "video.merge", title: "Merge videos",
        summary: "Join clips into one video. Sizes, frame rates and sound are matched for you.",
        symbol: "square.stack.3d.forward.dottedline", group: .organize, inputs: [.video],
        extraExtensions: gif, arity: .combine(minimum: 2, maximum: nil),
        options: [
            .choice(
                "size", "Size",
                [
                    StudioChoice("first", "Same as first clip"), StudioChoice("1080", "1080p"),
                    StudioChoice("720", "720p"),
                ], default: "first")
        ],
        requirements: ffmpeg, keywords: ["join", "combine", "concatenate", "append"],
        actionTitle: "Merge"
    ) { run in
        var infos: [StudioMediaInfo] = []
        for input in run.inputs { infos.append(try await FFmpeg.info(input, run: run)) }
        guard let first = infos.first?.displaySize else {
            throw StudioError.unreadable(run.inputs[0].lastPathComponent)
        }
        let target: CGSize
        switch run.settings.text("size") {
        case "1080":
            target =
                first.width >= first.height
                ? CGSize(width: 1920, height: 1080) : CGSize(width: 1080, height: 1920)
        case "720":
            target =
                first.width >= first.height
                ? CGSize(width: 1280, height: 720) : CGSize(width: 720, height: 1280)
        default: target = first
        }
        let width = MediaEncoding.even(target.width)
        let height = MediaEncoding.even(target.height)
        let fps = min(60, max(1, (infos[0].frameRate ?? 30).rounded()))
        var arguments: [String] = []
        for input in run.inputs { arguments += ["-i", input.path] }
        var chains: [String] = []
        var pairs = ""
        var total = 0.0
        for (index, info) in infos.enumerated() {
            let duration = info.duration ?? 1
            total += duration
            chains.append(
                "[\(index):v:0]scale=\(width):\(height):force_original_aspect_ratio=decrease,"
                    + "pad=\(width):\(height):(ow-iw)/2:(oh-ih)/2,setsar=1,fps=\(Int(fps)),"
                    + "format=yuv420p[v\(index)]")
            let audio =
                info.hasAudio
                ? "[\(index):a:0]aformat=sample_fmts=fltp:sample_rates=48000:channel_layouts=stereo,"
                    + "apad,atrim=duration=\(FFmpeg.seconds(duration))[a\(index)]"
                : "anullsrc=channel_layout=stereo:sample_rate=48000,"
                    + "atrim=duration=\(FFmpeg.seconds(duration))[a\(index)]"
            chains.append(audio)
            pairs += "[v\(index)][a\(index)]"
        }
        chains.append(pairs + "concat=n=\(infos.count):v=1:a=1[v][a]")
        let output = run.output(for: run.inputs[0], suffix: "merged", ext: "mp4")
        arguments += [
            "-filter_complex", chains.joined(separator: ";"), "-map", "[v]", "-map", "[a]",
        ]
        arguments += MediaEncoding.video(container: "mp4") + ["-c:a", "aac", "-b:a", "192k"]
        arguments += MediaEncoding.finishing(container: "mp4") + [output.path]
        _ = try await FFmpeg.execute(arguments, run: run, expected: total)
        return [output]
    }

    static let toGIF = StudioTool(
        id: "video.to-gif", title: "Video to GIF",
        summary: "Turn a moment of a video into a smooth, well-colored animated GIF.",
        symbol: "photo.stack", group: .convert, inputs: [.video], produces: .kind(.image),
        options: [
            .span(help: "Leave empty to use the whole video."),
            .integer("fps", "Frames per second", 5...30, default: 12),
            .choice(
                "width", "Width",
                [
                    StudioChoice("320", "320 px"), StudioChoice("480", "480 px"),
                    StudioChoice("640", "640 px"), StudioChoice("800", "800 px"),
                    StudioChoice("original", "Original"),
                ], default: "480"),
            .toggle("loop", "Loop forever", default: true),
        ],
        requirements: ffmpeg, keywords: ["gif", "animation", "meme", "loop"],
        actionTitle: "Make GIF"
    ) { run in
        let info = try await FFmpeg.info(run.input, run: run)
        let output = run.output(for: run.input, suffix: nil, ext: "gif")
        let requested = Int(run.settings.text("width"))
        let sourceWidth = info.displaySize.map { Int($0.width) }
        let width = requested.map { min($0, sourceWidth ?? $0) }
        try await GIFEncoder.encode(
            run.input, to: output, fps: run.settings.int("fps"),
            width: width == sourceWidth ? nil : width, span: run.settings.span("range"),
            loop: run.settings.bool("loop"), run: run, duration: info.duration)
        return [output]
    }

    static let extractAudio = StudioTool(
        id: "video.extract-audio", title: "Extract audio",
        summary: "Save the soundtrack of a video as MP3, M4A, WAV, FLAC or Opus.",
        symbol: "waveform.badge.plus", group: .convert, inputs: [.video], produces: .kind(.audio),
        options: [
            .choice(
                "format", "Format",
                [
                    StudioChoice("mp3", "MP3"), StudioChoice("m4a", "M4A (AAC)"),
                    StudioChoice("wav", "WAV"), StudioChoice("flac", "FLAC"),
                    StudioChoice("opus", "Opus"),
                ], default: "mp3"),
            StudioOption.choice(
                "bitrate", "Quality", MediaEncoding.bitrateChoices, default: "192",
                when: .init("format", ["mp3", "m4a", "opus"])),
        ],
        requirements: ffmpeg, keywords: ["mp3", "sound", "music", "soundtrack", "audio"],
        actionTitle: "Extract audio"
    ) { run in
        let info = try await FFmpeg.info(run.input, run: run)
        guard info.hasAudio else { throw StudioError.nothingToDo("This video has no sound.") }
        let format = MediaEncoding.audioFormat(
            run.settings.text("format"), bitrate: Int(run.settings.text("bitrate")) ?? 192)
        let output = run.output(for: run.input, suffix: nil, ext: format.ext)
        _ = try await FFmpeg.execute(
            ["-i", run.input.path, "-vn", "-map", "0:a:0", "-map_metadata", "0"] + format.arguments
                + [output.path], run: run, expected: info.duration)
        return [output]
    }

    static let frames = StudioTool(
        id: "video.frames", title: "Video to images",
        summary: "Save frames as JPG or PNG, every few seconds, at set times or as one thumbnail.",
        symbol: "photo.on.rectangle.angled", group: .convert, inputs: [.video],
        extraExtensions: gif, produces: .kind(.image),
        options: [
            .choice(
                "mode", "Capture",
                [
                    StudioChoice("interval", "Every N seconds"),
                    StudioChoice("count", "A set number of frames"),
                    StudioChoice("times", "At times"),
                    StudioChoice("thumbnail", "One thumbnail"),
                ], default: "interval"),
            .number(
                "seconds", "Every", 0.1...3600, step: 0.5, default: 1, unit: "s",
                when: .init("mode", ["interval"])),
            .integer("count", "Frames", 1...200, default: 10, when: .init("mode", ["count"])),
            .text(
                "times", "Times", placeholder: "0:01, 0:05.5, 1:20", default: "",
                when: .init("mode", ["times"]), required: true),
            .time(
                "at", "Thumbnail at", default: 1,
                help: "Past the end means the middle of the video.",
                when: .init("mode", ["thumbnail"])),
            .choice(
                "format", "Format", [StudioChoice("jpg", "JPG"), StudioChoice("png", "PNG")],
                default: "jpg"),
            .choice(
                "width", "Size",
                [
                    StudioChoice("original", "Original"), StudioChoice("1280", "1280 px wide"),
                    StudioChoice("640", "640 px wide"), StudioChoice("320", "320 px wide"),
                ], default: "original"),
        ],
        requirements: ffmpeg,
        keywords: ["frames", "screenshots", "stills", "thumbnail", "jpg", "png", "snapshot"],
        groupsOutputs: true, actionTitle: "Save images"
    ) { run in
        let info = try await FFmpeg.info(run.input, run: run)
        let duration = info.duration ?? 0
        let ext = run.settings.text("format") == "png" ? "png" : "jpg"
        var filters: [String] = []
        if let width = Int(run.settings.text("width")) { filters.append("scale=\(width):-2") }
        let quality = ext == "jpg" ? ["-q:v", "2"] : []
        let stem = run.input.studioStem
        switch run.settings.text("mode") {
        case "interval":
            let every = max(0.1, run.settings.number("seconds"))
            let pattern = run.workDirectory.appendingPathComponent(
                stem.replacingOccurrences(of: "%", with: "%%") + "-frame-%04d.\(ext)")
            let chain = (["fps=1/\(FFmpeg.seconds(every))"] + filters).joined(separator: ",")
            _ = try await FFmpeg.execute(
                ["-i", run.input.path, "-map", "0:v:0", "-vf", chain] + quality + [pattern.path],
                run: run, expected: duration)
            return MediaFiles.produced(in: run.workDirectory, prefix: stem + "-frame-")
        case "thumbnail":
            var at = run.settings.number("at")
            if duration > 0, at >= duration { at = duration / 2 }
            let output = run.output(for: run.input, suffix: "thumbnail", ext: ext)
            try await FrameGrabber.grab(
                run.input, at: at, filters: filters, quality: quality, to: output, run: run)
            return [output]
        default:
            let times: [Double]
            if run.settings.text("mode") == "count" {
                guard duration > 0 else {
                    throw StudioError.unavailable("The length of this video is unknown.")
                }
                let count = max(1, run.settings.int("count"))
                times = (0..<count).map { duration * (Double($0) + 0.5) / Double(count) }
            } else {
                times = try run.settings.text("times").split(separator: ",").map {
                    guard let value = StudioTime.parse(String($0)) else {
                        throw StudioError.invalidOption("times", "\($0) is not a time")
                    }
                    return value
                }
            }
            var outputs: [URL] = []
            let inside = times.filter { duration <= 0 || $0 < duration }
            for (index, time) in inside.enumerated() {
                try run.checkCancellation()
                let label = "frame-" + String(format: "%04d", index + 1)
                let output = run.output(for: run.input, suffix: label, ext: ext)
                do {
                    try await FrameGrabber.grab(
                        run.input, at: time, filters: filters, quality: quality, to: output,
                        run: run)
                    outputs.append(output)
                } catch StudioError.cancelled {
                    throw StudioError.cancelled
                } catch {
                    run.note("No frame was found at \(StudioTime.format(time)).")
                }
                run.progress(Double(index + 1) / Double(inside.count))
            }
            guard !outputs.isEmpty else {
                throw StudioError.nothingToDo("None of those times are inside the video.")
            }
            return outputs
        }
    }

    static let mute = StudioTool(
        id: "video.mute", title: "Mute video",
        summary: "Remove the sound from a video without touching the picture.",
        symbol: "speaker.slash", group: .edit, inputs: [.video],
        requirements: ffmpeg, keywords: ["silent", "remove audio", "no sound"],
        actionTitle: "Mute"
    ) { run in
        let info = try await FFmpeg.info(run.input, run: run)
        let container = MediaEncoding.videoContainer(for: run.input)
        let copy = MediaEncoding.editableContainers.contains(run.input.pathExtension.lowercased())
        let output = run.output(for: run.input, suffix: "muted", ext: container)
        var arguments = ["-i", run.input.path, "-map", "0:v:0", "-an", "-map_metadata", "0"]
        arguments +=
            copy
            ? ["-c:v", "copy"]
            : ["-vf", MediaEncoding.evenFilter] + MediaEncoding.video(container: container)
        _ = try await FFmpeg.execute(
            arguments + MediaEncoding.finishing(container: container) + [output.path], run: run,
            expected: info.duration)
        return [output]
    }

    static let rotate = StudioTool(
        id: "video.rotate", title: "Rotate video",
        summary: "Turn a video sideways or upside down, or mirror it.",
        symbol: "rotate.right", group: .edit, inputs: [.video], extraExtensions: gif,
        options: [
            .choice(
                "turn", "Rotate",
                [
                    StudioChoice("right", "Right 90°"), StudioChoice("left", "Left 90°"),
                    StudioChoice("180", "180°"), StudioChoice("mirror", "Mirror"),
                    StudioChoice("flip", "Upside down mirror"),
                ], default: "right")
        ],
        requirements: ffmpeg, keywords: ["turn", "flip", "mirror", "portrait", "landscape"],
        actionTitle: "Rotate"
    ) { run in
        let filter: String
        switch run.settings.text("turn") {
        case "left": filter = "transpose=2"
        case "180": filter = "hflip,vflip"
        case "mirror": filter = "hflip"
        case "flip": filter = "vflip"
        default: filter = "transpose=1"
        }
        return [try await VideoFilter.apply(run, video: filter, suffix: "rotated")]
    }

    static let crop = StudioTool(
        id: "video.crop", title: "Crop video",
        summary: "Crop to square, vertical or widescreen, a custom area, or remove black bars.",
        symbol: "crop", group: .edit, inputs: [.video], extraExtensions: gif,
        options: [
            .choice(
                "mode", "Crop",
                [
                    StudioChoice("aspect", "To a shape"), StudioChoice("area", "Custom area"),
                    StudioChoice("auto", "Remove black bars"),
                ], default: "aspect"),
            .choice(
                "aspect", "Shape",
                [
                    StudioChoice("1:1", "Square 1:1"), StudioChoice("9:16", "Vertical 9:16"),
                    StudioChoice("16:9", "Widescreen 16:9"), StudioChoice("4:5", "Portrait 4:5"),
                    StudioChoice("4:3", "Classic 4:3"),
                ], default: "1:1", when: .init("mode", ["aspect"])),
            .rect(
                "area", "Area", default: StudioRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8),
                when: .init("mode", ["area"])),
        ],
        requirements: ffmpeg,
        keywords: ["square", "vertical", "black bars", "letterbox", "aspect"],
        actionTitle: "Crop"
    ) { run in
        let info = try await FFmpeg.info(run.input, run: run)
        guard let size = info.displaySize else {
            throw StudioError.unreadable(run.input.lastPathComponent)
        }
        let rect: CGRect
        switch run.settings.text("mode") {
        case "area":
            rect = run.settings.rect("area").pixels(in: size)
        case "auto":
            guard
                let detected = try await CropDetector.detect(
                    run.input, run: run, duration: info.duration),
                detected.width < size.width - 1 || detected.height < size.height - 1
            else { throw StudioError.nothingToDo("No black bars were found in this video.") }
            rect = detected
        default:
            let parts = run.settings.text("aspect").split(separator: ":").compactMap { Double($0) }
            let ratio = parts.count == 2 && parts[1] > 0 ? parts[0] / parts[1] : 1
            if size.width / size.height > ratio {
                let width = size.height * ratio
                rect = CGRect(x: (size.width - width) / 2, y: 0, width: width, height: size.height)
            } else {
                let height = size.width / ratio
                rect = CGRect(
                    x: 0, y: (size.height - height) / 2, width: size.width, height: height)
            }
        }
        let x = MediaEncoding.floorEven(rect.minX)
        let y = MediaEncoding.floorEven(rect.minY)
        let width = min(MediaEncoding.even(rect.width), MediaEncoding.floorEven(size.width) - x)
        let height = min(MediaEncoding.even(rect.height), MediaEncoding.floorEven(size.height) - y)
        let filter = "crop=\(width):\(height):\(x):\(y)"
        return [try await VideoFilter.apply(run, video: filter, suffix: "cropped", info: info)]
    }

    static let resize = StudioTool(
        id: "video.resize", title: "Resize video",
        summary: "Change the resolution to 4K, 1080p, 720p, 480p or a custom width.",
        symbol: "arrow.up.left.and.arrow.down.right", group: .edit, inputs: [.video],
        extraExtensions: gif,
        options: [
            .choice(
                "size", "Resolution",
                [
                    StudioChoice("2160", "4K"), StudioChoice("1440", "1440p"),
                    StudioChoice("1080", "1080p"), StudioChoice("720", "720p"),
                    StudioChoice("480", "480p"), StudioChoice("360", "360p"),
                    StudioChoice("custom", "Custom width"),
                ], default: "720"),
            .integer(
                "width", "Width", 16...7680, default: 1280, unit: "px",
                when: .init("size", ["custom"])),
            .toggle("upscale", "Allow making it bigger", default: false),
        ],
        requirements: ffmpeg, keywords: ["scale", "resolution", "1080p", "720p", "4k", "smaller"],
        actionTitle: "Resize"
    ) { run in
        let info = try await FFmpeg.info(run.input, run: run)
        guard let size = info.displaySize else {
            throw StudioError.unreadable(run.input.lastPathComponent)
        }
        let filter: String
        let upscale = run.settings.bool("upscale")
        if run.settings.text("size") == "custom" {
            let width = MediaEncoding.even(Double(run.settings.int("width")))
            if !upscale, Double(width) >= size.width {
                throw StudioError.nothingToDo("The video is already \(Int(size.width)) px wide.")
            }
            filter = "scale=\(width):-2"
        } else {
            let target = Int(run.settings.text("size")) ?? 720
            let short = min(size.width, size.height)
            if !upscale, Double(target) >= short {
                throw StudioError.nothingToDo("The video is already \(Int(short))p or smaller.")
            }
            filter = size.width >= size.height ? "scale=-2:\(target)" : "scale=\(target):-2"
        }
        return [try await VideoFilter.apply(run, video: filter, suffix: "resized", info: info)]
    }

    static let speed = StudioTool(
        id: "video.speed", title: "Change speed",
        summary: "Speed a video up for timelapses or slow it down, with matching sound.",
        symbol: "gauge.with.dots.needle.67percent", group: .edit, inputs: [.video],
        extraExtensions: gif,
        options: [
            .choice(
                "speed", "Speed",
                ["0.25", "0.5", "0.75", "1.25", "1.5", "2", "3", "4"].map {
                    StudioChoice($0, $0 + "×")
                }, default: "2"),
            .toggle("sound", "Keep the sound", default: true),
        ],
        requirements: ffmpeg, keywords: ["fast", "slow motion", "timelapse", "faster", "slower"],
        actionTitle: "Change speed"
    ) { run in
        let factor = Double(run.settings.text("speed")) ?? 2
        let info = try await FFmpeg.info(run.input, run: run)
        let video = "setpts=PTS/\(factor)"
        let keep = run.settings.bool("sound") && info.hasAudio
        let expected = info.duration.map { $0 / factor }
        return [
            try await VideoFilter.apply(
                run, video: video, audio: keep ? MediaEncoding.atempo(factor) : nil,
                dropAudio: !keep, suffix: "\(run.settings.text("speed"))x", info: info,
                expected: expected)
        ]
    }

    static let reverse = StudioTool(
        id: "video.reverse", title: "Reverse video",
        summary: "Play a video backwards, sound included.",
        symbol: "backward", group: .edit, inputs: [.video], extraExtensions: gif,
        options: [.toggle("sound", "Reverse the sound too", default: true)],
        requirements: ffmpeg, keywords: ["backwards", "rewind", "boomerang"],
        actionTitle: "Reverse"
    ) { run in
        let info = try await FFmpeg.info(run.input, run: run)
        let keep = run.settings.bool("sound") && info.hasAudio
        return [try await Reverser.reverse(run, info: info, audio: keep)]
    }

    static let addAudio = StudioTool(
        id: "video.add-audio", title: "Add music",
        summary: "Replace the soundtrack or mix in background music.",
        symbol: "music.note.tv", group: .edit, inputs: [.video],
        options: [
            .file("audio", "Music", kinds: [.audio, .video], required: true),
            .choice(
                "mode", "Sound",
                [
                    StudioChoice("mix", "Mix with original"),
                    StudioChoice("replace", "Replace original"),
                ],
                default: "mix"),
            .percent("volume", "Music volume", 0...2, default: 0.6),
            .toggle("loop", "Loop music to fill the video", default: true),
            .number("fadeOut", "Fade out", 0...20, step: 0.5, default: 2, unit: "s"),
        ],
        requirements: ffmpeg, keywords: ["music", "soundtrack", "background", "song", "audio"],
        actionTitle: "Add music"
    ) { run in
        guard let music = run.settings.file("audio") else {
            throw StudioError.invalidOption("music", "choose an audio file")
        }
        let info = try await FFmpeg.info(run.input, run: run)
        let musicInfo = try await FFmpeg.info(music, run: run)
        guard musicInfo.hasAudio else {
            throw StudioError.unsupportedInput(music.lastPathComponent, "Add music")
        }
        guard let duration = info.duration, duration > 0 else {
            throw StudioError.unavailable("The length of this video is unknown.")
        }
        let fade = min(run.settings.number("fadeOut"), duration / 2)
        var musicChain =
            "[1:a:0]aformat=sample_fmts=fltp:sample_rates=48000:channel_layouts=stereo,"
            + "volume=\(String(format: "%.3f", run.settings.number("volume")))"
        musicChain += ",atrim=duration=\(FFmpeg.seconds(duration))"
        if fade > 0 {
            musicChain +=
                ",afade=t=out:st=\(FFmpeg.seconds(duration - fade)):d=\(FFmpeg.seconds(fade))"
        }
        let mix = run.settings.text("mode") == "mix" && info.hasAudio
        let graph: String
        if mix {
            graph =
                musicChain + "[m];[0:a:0]aformat=sample_fmts=fltp:sample_rates=48000:"
                + "channel_layouts=stereo[o];[o][m]amix=inputs=2:duration=first:"
                + "dropout_transition=0:normalize=0[a]"
        } else {
            graph = musicChain + ",apad,atrim=duration=\(FFmpeg.seconds(duration))[a]"
        }
        let container = MediaEncoding.videoContainer(for: run.input)
        let output = run.output(for: run.input, suffix: "with-music", ext: container)
        var arguments = ["-i", run.input.path]
        if run.settings.bool("loop") { arguments += ["-stream_loop", "-1"] }
        arguments += ["-i", music.path, "-filter_complex", graph, "-map", "0:v:0", "-map", "[a]"]
        let copy = MediaEncoding.editableContainers.contains(run.input.pathExtension.lowercased())
        arguments +=
            copy
            ? ["-c:v", "copy"]
            : ["-vf", MediaEncoding.evenFilter] + MediaEncoding.video(container: container)
        arguments += ["-c:a", "aac", "-b:a", "192k", "-t", FFmpeg.seconds(duration)]
        arguments += MediaEncoding.finishing(container: container) + [output.path]
        _ = try await FFmpeg.execute(arguments, run: run, expected: duration)
        return [output]
    }

    static let volume = StudioTool(
        id: "video.volume", title: "Adjust volume",
        summary: "Make a video louder or quieter, or even out loudness automatically.",
        symbol: "speaker.wave.3", group: .edit, inputs: [.video],
        options: [
            .choice(
                "mode", "Volume",
                [
                    StudioChoice("normalize", "Normalize loudness"),
                    StudioChoice("adjust", "Change by"),
                ],
                default: "normalize"),
            .number(
                "gain", "Change", -30...30, step: 1, default: 6, unit: "dB",
                when: .init("mode", ["adjust"])),
        ],
        requirements: ffmpeg, keywords: ["louder", "quieter", "normalize", "boost", "loudness"],
        actionTitle: "Adjust volume"
    ) { run in
        let info = try await FFmpeg.info(run.input, run: run)
        guard info.hasAudio else { throw StudioError.nothingToDo("This video has no sound.") }
        let filter =
            run.settings.text("mode") == "adjust"
            ? "volume=\(Int(run.settings.number("gain")))dB"
            : "loudnorm=I=-16:TP=-1.5:LRA=11,aresample=48000,asetnsamples=n=4096:p=0"
        return [try await VideoFilter.apply(run, audio: filter, suffix: "volume", info: info)]
    }

    static let watermark = StudioTool(
        id: "video.watermark", title: "Watermark video",
        summary: "Stamp text or a logo on every frame, with the position and opacity you choose.",
        symbol: "drop.halffull", group: .edit, inputs: [.video], extraExtensions: gif,
        options: [
            .choice(
                "kind", "Watermark",
                [StudioChoice("text", "Text"), StudioChoice("image", "Image")],
                default: "text"),
            .text(
                "text", "Text", placeholder: "@yourname", default: "© Studio",
                when: .init("kind", ["text"]), required: true),
            .font(when: .init("kind", ["text"])),
            .toggle("bold", "Bold", default: true, when: .init("kind", ["text"])),
            .color("color", "Color", default: "#FFFFFF", when: .init("kind", ["text"])),
            .file("image", "Logo", kinds: [.image], when: .init("kind", ["image"]), required: true),
            .anchor(default: .bottomRight, includeTiled: true),
            .percent("size", "Size", 0.03...1, default: 0.2, help: "Relative to the video width."),
            .percent("opacity", "Opacity", 0.05...1, default: 0.7),
            .number("rotation", "Rotation", -180...180, step: 5, default: 0, unit: "°"),
        ],
        requirements: ffmpeg, keywords: ["logo", "brand", "stamp", "copyright", "overlay"],
        actionTitle: "Add watermark"
    ) { run in
        let info = try await FFmpeg.info(run.input, run: run)
        guard let size = info.displaySize else {
            throw StudioError.unreadable(run.input.lastPathComponent)
        }
        let stamp = try StudioStamp.from(run.settings)
        let overlay = try run.scratch("overlay").appendingPathComponent("watermark.png")
        try MediaGraphics.stampOverlay(
            stamp, width: Int(size.width), height: Int(size.height), to: overlay)
        return [
            try await VideoFilter.overlay(run, image: overlay, info: info, suffix: "watermarked")
        ]
    }

    static let subtitles = StudioTool(
        id: "video.subtitles", title: "Add subtitles",
        summary:
            "Add an SRT or VTT file as a subtitle track, or burn the captions into the picture.",
        symbol: "captions.bubble", group: .edit, inputs: [.video],
        options: [
            .file("subtitles", "Subtitles", kinds: [.document, .other], required: true),
            .choice(
                "mode", "Subtitles",
                [
                    StudioChoice("burn", "Burn into the picture"),
                    StudioChoice("track", "Add as a track"),
                ], default: "burn"),
            .percent(
                "size", "Text size", 0.02...0.15, default: 0.055,
                help: "Relative to the video height.", when: .init("mode", ["burn"])),
            .color("color", "Text color", default: "#FFFFFF", when: .init("mode", ["burn"])),
            .toggle("box", "Dark box behind text", default: true, when: .init("mode", ["burn"])),
            .choice(
                "place", "Position",
                [StudioChoice("bottom", "Bottom"), StudioChoice("top", "Top")],
                default: "bottom", when: .init("mode", ["burn"])),
        ],
        requirements: ffmpeg,
        keywords: ["captions", "srt", "vtt", "subtitle", "burn", "closed captions"],
        actionTitle: "Add subtitles"
    ) { run in
        guard let file = run.settings.file("subtitles") else {
            throw StudioError.invalidOption("subtitles", "choose an SRT or VTT file")
        }
        let raw: String
        do {
            raw = try String(contentsOf: file, encoding: .utf8)
        } catch {
            raw = try String(contentsOf: file, encoding: .isoLatin1)
        }
        let cues = SubtitleParser.parse(raw)
        guard !cues.isEmpty else {
            throw StudioError.unsupportedInput(file.lastPathComponent, "Add subtitles")
        }
        let info = try await FFmpeg.info(run.input, run: run)
        if run.settings.text("mode") == "track" {
            return [try await Captions.track(run, subtitles: file, info: info)]
        }
        return [try await Captions.burn(run, cues: cues, info: info)]
    }

    static let loop = StudioTool(
        id: "video.loop", title: "Loop video",
        summary: "Repeat a clip several times in a row.",
        symbol: "repeat", group: .edit, inputs: [.video], extraExtensions: gif,
        options: [.integer("times", "Play it", 2...50, default: 3, unit: "times")],
        requirements: ffmpeg, keywords: ["repeat", "loop", "boomerang"], actionTitle: "Loop"
    ) { run in
        let info = try await FFmpeg.info(run.input, run: run)
        let times = max(2, run.settings.int("times"))
        let container = MediaEncoding.videoContainer(for: run.input)
        let output = run.output(for: run.input, suffix: "loop-\(times)x", ext: container)
        var arguments = ["-stream_loop", String(times - 1), "-i", run.input.path]
        arguments += MediaEncoding.primaryStreams + ["-vf", MediaEncoding.evenFilter]
        arguments += MediaEncoding.video(container: container)
        arguments += MediaEncoding.audio(container: container, source: info, allowCopy: false)
        arguments += MediaEncoding.finishing(container: container) + [output.path]
        _ = try await FFmpeg.execute(
            arguments, run: run, expected: info.duration.map { $0 * Double(times) })
        return [output]
    }

    static let fps = StudioTool(
        id: "video.fps", title: "Change frame rate",
        summary: "Convert to 24, 25, 30, 50 or 60 frames per second.",
        symbol: "speedometer", group: .convert, inputs: [.video], extraExtensions: gif,
        options: [
            .choice(
                "fps", "Frame rate",
                ["15", "24", "25", "30", "50", "60"].map { StudioChoice($0, "\($0) fps") },
                default: "30")
        ],
        requirements: ffmpeg, keywords: ["fps", "frame rate", "framerate", "smooth"],
        actionTitle: "Convert"
    ) { run in
        let rate = run.settings.text("fps")
        return [try await VideoFilter.apply(run, video: "fps=\(rate)", suffix: "\(rate)fps")]
    }

    static let fromImages = StudioTool(
        id: "video.from-images", title: "Images to video",
        summary: "Make a slideshow video from photos, with crossfades and optional music.",
        symbol: "photo.stack.fill", group: .create, inputs: [.image],
        arity: .combine(minimum: 1, maximum: nil), produces: .kind(.video),
        options: [
            .number("seconds", "Each photo", 0.5...60, step: 0.5, default: 3, unit: "s"),
            .toggle("crossfade", "Crossfade between photos", default: true),
            .choice(
                "size", "Size",
                [
                    StudioChoice("1920x1080", "1080p widescreen"),
                    StudioChoice("1280x720", "720p widescreen"),
                    StudioChoice("1080x1920", "Vertical 1080×1920"),
                    StudioChoice("1080x1080", "Square 1080×1080"),
                ], default: "1920x1080"),
            .choice(
                "fit", "Photos",
                [StudioChoice("fit", "Fit whole photo"), StudioChoice("fill", "Fill the frame")],
                default: "fit"),
            .color("background", "Background", default: "#000000", when: .init("fit", ["fit"])),
            .file("audio", "Music", kinds: [.audio], help: "Optional. Trimmed and faded to fit."),
        ],
        requirements: ffmpeg, keywords: ["slideshow", "photos", "montage", "reel"],
        actionTitle: "Make video", family: .video
    ) { run in
        try await Slideshow.make(run)
    }

    static let stabilize = StudioTool(
        id: "video.stabilize", title: "Stabilize video",
        summary: "Smooth out shaky handheld footage.",
        symbol: "hand.raised.slash", group: .optimize, inputs: [.video],
        options: [
            .choice(
                "strength", "Strength",
                [StudioChoice("normal", "Normal"), StudioChoice("strong", "Strong")],
                default: "normal")
        ],
        requirements: ffmpeg, keywords: ["shaky", "steady", "deshake", "smooth"],
        actionTitle: "Stabilize"
    ) { run in
        let range = run.settings.text("strength") == "strong" ? 64 : 32
        return [
            try await VideoFilter.apply(
                run, video: "deshake=rx=\(range):ry=\(range):edge=mirror", suffix: "stabilized")
        ]
    }

    static let denoise = StudioTool(
        id: "video.denoise", title: "Reduce noise",
        summary: "Clean up grainy low-light video and, optionally, background hiss.",
        symbol: "wand.and.stars", group: .optimize, inputs: [.video],
        options: [
            .choice(
                "strength", "Strength",
                [
                    StudioChoice("light", "Light"), StudioChoice("medium", "Medium"),
                    StudioChoice("strong", "Strong"),
                ], default: "medium"),
            .toggle("audio", "Also reduce background noise", default: false),
        ],
        requirements: ffmpeg, keywords: ["grain", "noise", "clean", "hiss", "denoise"],
        actionTitle: "Reduce noise"
    ) { run in
        let video: String
        switch run.settings.text("strength") {
        case "light": video = "hqdn3d=2:1.5:3:2.25"
        case "strong": video = "hqdn3d=8:6:12:9"
        default: video = "hqdn3d=4:3:6:4.5"
        }
        let info = try await FFmpeg.info(run.input, run: run)
        let audio = run.settings.bool("audio") && info.hasAudio ? "afftdn=nr=20:nf=-30" : nil
        return [
            try await VideoFilter.apply(
                run, video: video, audio: audio, suffix: "denoised", info: info)
        ]
    }

    static let fade = StudioTool(
        id: "video.fade", title: "Fade in and out",
        summary: "Fade the picture and sound in from black and out to black.",
        symbol: "circle.lefthalf.striped.horizontal", group: .edit, inputs: [.video],
        options: [
            .number("fadeIn", "Fade in", 0...10, step: 0.5, default: 1, unit: "s"),
            .number("fadeOut", "Fade out", 0...10, step: 0.5, default: 1, unit: "s"),
        ],
        requirements: ffmpeg, keywords: ["fade", "black", "intro", "outro", "transition"],
        actionTitle: "Add fades"
    ) { run in
        let info = try await FFmpeg.info(run.input, run: run)
        guard let duration = info.duration, duration > 0 else {
            throw StudioError.unavailable("The length of this video is unknown.")
        }
        let fadeIn = min(run.settings.number("fadeIn"), duration / 2)
        let fadeOut = min(run.settings.number("fadeOut"), duration / 2)
        guard fadeIn > 0 || fadeOut > 0 else {
            throw StudioError.invalidOption("fade", "choose a fade in or fade out length")
        }
        var video: [String] = []
        var audio: [String] = []
        if fadeIn > 0 {
            video.append("fade=t=in:st=0:d=\(FFmpeg.seconds(fadeIn))")
            audio.append("afade=t=in:st=0:d=\(FFmpeg.seconds(fadeIn))")
        }
        if fadeOut > 0 {
            let start = FFmpeg.seconds(duration - fadeOut)
            video.append("fade=t=out:st=\(start):d=\(FFmpeg.seconds(fadeOut))")
            audio.append("afade=t=out:st=\(start):d=\(FFmpeg.seconds(fadeOut))")
        }
        return [
            try await VideoFilter.apply(
                run, video: video.joined(separator: ","),
                audio: info.hasAudio ? audio.joined(separator: ",") : nil, suffix: "faded",
                info: info)
        ]
    }

    static let adjust = StudioTool(
        id: "video.adjust", title: "Adjust colors",
        summary: "Change brightness, contrast, saturation and gamma.",
        symbol: "slider.horizontal.3", group: .edit, inputs: [.video], extraExtensions: gif,
        options: [
            .number("brightness", "Brightness", -0.5...0.5, step: 0.02, default: 0.05),
            .number("contrast", "Contrast", 0.5...2, step: 0.05, default: 1.1),
            .number("saturation", "Saturation", 0...3, step: 0.05, default: 1.2),
            .number("gamma", "Gamma", 0.3...3, step: 0.05, default: 1),
        ],
        requirements: ffmpeg, keywords: ["color", "brightness", "contrast", "saturation", "grade"],
        actionTitle: "Apply"
    ) { run in
        let values = ["brightness", "contrast", "saturation", "gamma"].map {
            "\($0)=" + String(format: "%.3f", run.settings.number($0))
        }
        return [
            try await VideoFilter.apply(
                run, video: "eq=" + values.joined(separator: ":"), suffix: "adjusted")
        ]
    }

    static let social = StudioTool(
        id: "video.social", title: "Resize for social",
        summary: "Fit a video to Reels, TikTok, Shorts, square or widescreen, with a blurred fill.",
        symbol: "rectangle.portrait.on.rectangle.portrait", group: .convert, inputs: [.video],
        extraExtensions: gif,
        options: [
            .choice(
                "shape", "Format",
                [
                    StudioChoice("9:16", "Reels, TikTok, Shorts 9:16"),
                    StudioChoice("1:1", "Square 1:1"), StudioChoice("4:5", "Portrait 4:5"),
                    StudioChoice("16:9", "YouTube 16:9"),
                ], default: "9:16"),
            .choice(
                "fill", "Fill",
                [
                    StudioChoice("blur", "Blurred background"), StudioChoice("bars", "Black bars"),
                    StudioChoice("crop", "Crop to fill"),
                ], default: "blur"),
            .choice(
                "quality", "Size",
                [StudioChoice("1080", "1080 px"), StudioChoice("720", "720 px")],
                default: "1080"),
        ],
        requirements: ffmpeg,
        keywords: ["instagram", "tiktok", "reels", "shorts", "youtube", "vertical", "square"],
        actionTitle: "Resize"
    ) { run in
        let base = Double(run.settings.text("quality")) ?? 1080
        let size: (Int, Int)
        switch run.settings.text("shape") {
        case "1:1": size = (Int(base), Int(base))
        case "4:5": size = (Int(base), MediaEncoding.even(base * 1.25))
        case "16:9": size = (MediaEncoding.even(base * 16 / 9), Int(base))
        default: size = (Int(base), MediaEncoding.even(base * 16 / 9))
        }
        let (width, height) = size
        let graph: String
        switch run.settings.text("fill") {
        case "crop":
            graph =
                "[0:v:0]scale=\(width):\(height):force_original_aspect_ratio=increase,"
                + "crop=\(width):\(height),setsar=1,format=yuv420p[v]"
        case "bars":
            graph =
                "[0:v:0]scale=\(width):\(height):force_original_aspect_ratio=decrease,"
                + "pad=\(width):\(height):(ow-iw)/2:(oh-ih)/2:color=black,setsar=1,format=yuv420p[v]"
        default:
            graph =
                "[0:v:0]split[a][b];[a]scale=\(width):\(height):force_original_aspect_ratio=increase,"
                + "crop=\(width):\(height),boxblur=20:5,eq=brightness=-0.08[bg];"
                + "[b]scale=\(width):\(height):force_original_aspect_ratio=decrease[fg];"
                + "[bg][fg]overlay=(W-w)/2:(H-h)/2,setsar=1,format=yuv420p[v]"
        }
        let info = try await FFmpeg.info(run.input, run: run)
        let label = run.settings.text("shape").replacingOccurrences(of: ":", with: "x")
        let output = run.output(for: run.input, suffix: label, ext: "mp4")
        var arguments = [
            "-i", run.input.path, "-filter_complex", graph, "-map", "[v]", "-map", "0:a:0?",
        ]
        arguments += MediaEncoding.video(container: "mp4")
        arguments += MediaEncoding.audio(container: "mp4", source: info, allowCopy: true)
        arguments += MediaEncoding.finishing(container: "mp4") + [output.path]
        _ = try await FFmpeg.execute(arguments, run: run, expected: info.duration)
        return [output]
    }
}
