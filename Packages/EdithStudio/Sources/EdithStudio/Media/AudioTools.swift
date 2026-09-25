import Foundation

enum AudioTools {
    static let ffmpeg: [StudioRequirement] = [.engine(.ffmpeg)]
    static let normalize = "aformat=sample_fmts=fltp:sample_rates=48000:channel_layouts=stereo"

    static var all: [StudioTool] {
        [
            trim, convert, compress, merge, volume, speed, fade, reverse, removeSilence, denoise,
            toVideo,
        ]
    }

    static func edited(
        _ run: StudioRun, filter: String, suffix: String, expected: ((Double) -> Double)? = nil
    ) async throws -> URL {
        let info = try await FFmpeg.info(run.input, run: run)
        guard info.hasAudio else {
            throw StudioError.unsupportedInput(run.input.lastPathComponent, run.tool.title)
        }
        let format = MediaEncoding.sameAudioFormat(for: run.input, info: info)
        let output = run.output(for: run.input, suffix: suffix, ext: format.ext)
        _ = try await FFmpeg.execute(
            ["-i", run.input.path, "-vn", "-map", "0:a:0", "-map_metadata", "0", "-af", filter]
                + format.arguments + [output.path],
            run: run, expected: info.duration.map { expected?($0) ?? $0 })
        return output
    }

    static let trim = StudioTool(
        id: "audio.trim", title: "Trim audio",
        summary: "Cut a song, voice memo or podcast down to the part you want.",
        symbol: "waveform.path", group: .edit, inputs: [.audio],
        options: [
            .span(
                help: "Start and end, for example 0:30-1:45. Leave the end empty to keep the rest."),
            .number("fadeIn", "Fade in", 0...10, step: 0.5, default: 0, unit: "s"),
            .number("fadeOut", "Fade out", 0...10, step: 0.5, default: 0, unit: "s"),
        ],
        requirements: ffmpeg, keywords: ["cut", "clip", "ringtone", "shorten"], actionTitle: "Trim"
    ) { run in
        let info = try await FFmpeg.info(run.input, run: run)
        let span = run.settings.span("range")
        guard span.start > 0 || span.end != nil else {
            throw StudioError.invalidOption("range", "choose where the clip starts or ends")
        }
        if let total = info.duration, span.start >= total {
            throw StudioError.invalidOption("range", "the start is past the end of the audio")
        }
        let length = span.duration(within: info.duration)
        var filters: [String] = []
        let fadeIn = run.settings.number("fadeIn")
        let fadeOut = run.settings.number("fadeOut")
        if fadeIn > 0 { filters.append("afade=t=in:st=0:d=\(FFmpeg.seconds(fadeIn))") }
        if fadeOut > 0, let length {
            let start = max(0, length - fadeOut)
            filters.append("afade=t=out:st=\(FFmpeg.seconds(start)):d=\(FFmpeg.seconds(fadeOut))")
        }
        let format = MediaEncoding.sameAudioFormat(for: run.input, info: info)
        let output = run.output(for: run.input, suffix: "trimmed", ext: format.ext)
        var arguments = ["-ss", FFmpeg.seconds(span.start), "-i", run.input.path]
        if let length { arguments += ["-t", FFmpeg.seconds(length)] }
        arguments += ["-vn", "-map", "0:a:0", "-map_metadata", "0"]
        if !filters.isEmpty { arguments += ["-af", filters.joined(separator: ",")] }
        _ = try await FFmpeg.execute(
            arguments + format.arguments + [output.path], run: run, expected: length)
        return [output]
    }

    static let convert = StudioTool(
        id: "audio.convert", title: "Convert audio",
        summary: "Change audio to MP3, M4A, WAV, FLAC, Opus, OGG, AIFF or Apple Lossless.",
        symbol: "arrow.triangle.2.circlepath", group: .convert, inputs: [.audio, .video],
        produces: .kind(.audio),
        options: [
            .choice("format", "Convert to", MediaEncoding.audioFormatChoices, default: "mp3"),
            .choice(
                "bitrate", "Quality", MediaEncoding.bitrateChoices, default: "192",
                when: .init("format", ["mp3", "m4a", "opus", "ogg"])),
            .toggle("mono", "Mix down to mono", default: false),
        ],
        requirements: ffmpeg,
        keywords: ["mp3", "wav", "flac", "m4a", "aac", "opus", "ogg", "aiff", "alac", "format"],
        actionTitle: "Convert", family: .audio
    ) { run in
        let info = try await FFmpeg.info(run.input, run: run)
        guard info.hasAudio else { throw StudioError.nothingToDo("This file has no sound.") }
        let format = MediaEncoding.audioFormat(
            run.settings.text("format"), bitrate: Int(run.settings.text("bitrate")) ?? 192)
        let same = run.input.pathExtension.lowercased() == format.ext
        let output = run.output(for: run.input, suffix: same ? "converted" : nil, ext: format.ext)
        var arguments = ["-i", run.input.path, "-vn", "-map", "0:a:0", "-map_metadata", "0"]
        if run.settings.bool("mono") { arguments += ["-ac", "1"] }
        _ = try await FFmpeg.execute(
            arguments + format.arguments + [output.path], run: run, expected: info.duration)
        return [output]
    }

    static let compress = StudioTool(
        id: "audio.compress", title: "Compress audio",
        summary: "Make audio files smaller for sharing, keeping voices and music clear.",
        symbol: "arrow.down.right.and.arrow.up.left", group: .optimize, inputs: [.audio],
        options: [
            .choice(
                "level", "Compression",
                [
                    StudioChoice("low", "Less"), StudioChoice("recommended", "Recommended"),
                    StudioChoice("extreme", "Extreme"),
                ], default: "recommended",
                help: "Lossless files such as WAV and FLAC become AAC in an M4A file."),
            .toggle("mono", "Mix down to mono", default: false),
        ],
        requirements: ffmpeg, keywords: ["reduce", "shrink", "smaller", "bitrate", "podcast"],
        actionTitle: "Compress"
    ) { run in
        let info = try await FFmpeg.info(run.input, run: run)
        guard info.hasAudio else { throw StudioError.nothingToDo("This file has no sound.") }
        let bitrate: Int
        switch run.settings.text("level") {
        case "low": bitrate = 160
        case "extreme": bitrate = 64
        default: bitrate = 96
        }
        let ext = run.input.pathExtension.lowercased()
        let name = ["mp3", "opus", "ogg"].contains(ext) ? ext : "m4a"
        let format = MediaEncoding.audioFormat(name, bitrate: bitrate)
        let output = run.output(for: run.input, suffix: "compressed", ext: format.ext)
        var arguments = ["-i", run.input.path, "-vn", "-map", "0:a:0", "-map_metadata", "0"]
        if run.settings.bool("mono") || run.settings.text("level") == "extreme" {
            arguments += ["-ac", "1"]
        }
        _ = try await FFmpeg.execute(
            arguments + format.arguments + [output.path], run: run, expected: info.duration)
        if StudioRunner.fileSize(output) >= StudioRunner.fileSize(run.input), ext == format.ext {
            try FileManager.default.removeItem(at: output)
            try FileManager.default.copyItem(at: run.input, to: output)
            run.note(
                "This audio is already as small as this level allows, so the copy is unchanged.")
        }
        return [output]
    }

    static let merge = StudioTool(
        id: "audio.merge", title: "Merge audio",
        summary: "Join audio files one after another, with an optional crossfade.",
        symbol: "waveform.badge.plus", group: .organize, inputs: [.audio],
        arity: .combine(minimum: 2, maximum: nil),
        options: [
            .choice(
                "format", "Save as",
                [
                    StudioChoice("same", "Same as first file"), StudioChoice("mp3", "MP3"),
                    StudioChoice("m4a", "M4A (AAC)"), StudioChoice("wav", "WAV"),
                ], default: "same"),
            .number("crossfade", "Crossfade", 0...10, step: 0.5, default: 0, unit: "s"),
        ],
        requirements: ffmpeg, keywords: ["join", "combine", "concatenate", "playlist", "mix"],
        actionTitle: "Merge"
    ) { run in
        var infos: [StudioMediaInfo] = []
        for input in run.inputs {
            let info = try await FFmpeg.info(input, run: run)
            guard info.hasAudio else {
                throw StudioError.unsupportedInput(input.lastPathComponent, "Merge audio")
            }
            infos.append(info)
        }
        let choice = run.settings.text("format")
        let format =
            choice == "same"
            ? MediaEncoding.sameAudioFormat(for: run.inputs[0], info: infos[0])
            : MediaEncoding.audioFormat(choice)
        let crossfade = run.settings.number("crossfade")
        var arguments: [String] = []
        for input in run.inputs { arguments += ["-i", input.path] }
        var chains = run.inputs.indices.map { "[\($0):a:0]\(normalize)[a\($0)]" }
        if crossfade > 0 {
            var previous = "a0"
            for index in 1..<run.inputs.count {
                let label = index == run.inputs.count - 1 ? "out" : "x\(index)"
                chains.append(
                    "[\(previous)][a\(index)]acrossfade=d=\(FFmpeg.seconds(crossfade))[\(label)]")
                previous = label
            }
        } else {
            chains.append(
                run.inputs.indices.map { "[a\($0)]" }.joined()
                    + "concat=n=\(run.inputs.count):v=0:a=1[out]")
        }
        let total =
            infos.reduce(0) { $0 + ($1.duration ?? 0) } - crossfade * Double(run.inputs.count - 1)
        let output = run.output(for: run.inputs[0], suffix: "merged", ext: format.ext)
        arguments += ["-filter_complex", chains.joined(separator: ";"), "-map", "[out]"]
        _ = try await FFmpeg.execute(
            arguments + format.arguments + [output.path], run: run, expected: total)
        return [output]
    }

    static let volume = StudioTool(
        id: "audio.volume", title: "Change volume",
        summary: "Make audio louder or quieter, or even out loudness to podcast levels.",
        symbol: "speaker.wave.3", group: .edit, inputs: [.audio],
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
        actionTitle: "Change volume"
    ) { run in
        let filter =
            run.settings.text("mode") == "adjust"
            ? "volume=\(Int(run.settings.number("gain")))dB"
            : "loudnorm=I=-16:TP=-1.5:LRA=11,aresample=48000,asetnsamples=n=4096:p=0"
        return [try await edited(run, filter: filter, suffix: "volume")]
    }

    static let speed = StudioTool(
        id: "audio.speed", title: "Audio speed",
        summary: "Speed up or slow down audio, keeping the pitch natural or not.",
        symbol: "gauge.with.dots.needle.67percent", group: .edit, inputs: [.audio],
        options: [
            .choice(
                "speed", "Speed",
                ["0.5", "0.75", "0.9", "1.1", "1.25", "1.5", "2"].map {
                    StudioChoice($0, $0 + "×")
                },
                default: "1.25"),
            .toggle("pitch", "Keep the pitch", default: true),
        ],
        requirements: ffmpeg, keywords: ["faster", "slower", "tempo", "pitch", "podcast"],
        actionTitle: "Change speed"
    ) { run in
        let factor = Double(run.settings.text("speed")) ?? 1.25
        let filter: String
        if run.settings.bool("pitch") {
            filter = MediaEncoding.atempo(factor)
        } else {
            filter = "asetrate=\(Int(48000 * factor)),aresample=48000"
        }
        let chain = "aresample=48000," + filter
        return [
            try await edited(
                run, filter: chain, suffix: "\(run.settings.text("speed"))x",
                expected: { $0 / factor })
        ]
    }

    static let fade = StudioTool(
        id: "audio.fade", title: "Fade audio",
        summary: "Add smooth fades to the start and end.",
        symbol: "waveform.path.ecg", group: .edit, inputs: [.audio],
        options: [
            .number("fadeIn", "Fade in", 0...30, step: 0.5, default: 2, unit: "s"),
            .number("fadeOut", "Fade out", 0...30, step: 0.5, default: 3, unit: "s"),
        ],
        requirements: ffmpeg, keywords: ["fade", "intro", "outro"], actionTitle: "Add fades"
    ) { run in
        let info = try await FFmpeg.info(run.input, run: run)
        guard let duration = info.duration, duration > 0 else {
            throw StudioError.unavailable("The length of this audio is unknown.")
        }
        let fadeIn = min(run.settings.number("fadeIn"), duration / 2)
        let fadeOut = min(run.settings.number("fadeOut"), duration / 2)
        guard fadeIn > 0 || fadeOut > 0 else {
            throw StudioError.invalidOption("fade", "choose a fade in or fade out length")
        }
        var filters: [String] = []
        if fadeIn > 0 { filters.append("afade=t=in:st=0:d=\(FFmpeg.seconds(fadeIn))") }
        if fadeOut > 0 {
            filters.append(
                "afade=t=out:st=\(FFmpeg.seconds(duration - fadeOut)):d=\(FFmpeg.seconds(fadeOut))")
        }
        return [try await edited(run, filter: filters.joined(separator: ","), suffix: "faded")]
    }

    static let reverse = StudioTool(
        id: "audio.reverse", title: "Reverse audio",
        summary: "Play audio backwards.", symbol: "backward", group: .edit, inputs: [.audio],
        requirements: ffmpeg, keywords: ["backwards", "rewind"], actionTitle: "Reverse"
    ) { run in
        [try await edited(run, filter: "areverse", suffix: "reversed")]
    }

    static let removeSilence = StudioTool(
        id: "audio.remove-silence", title: "Remove silence",
        summary: "Cut long pauses from recordings, or just trim silence at the start and end.",
        symbol: "waveform.slash", group: .optimize, inputs: [.audio],
        options: [
            .choice(
                "where", "Remove",
                [
                    StudioChoice("all", "All long pauses"),
                    StudioChoice("ends", "Only start and end"),
                ],
                default: "all"),
            .number(
                "pause", "Pauses longer than", 0.2...10, step: 0.1, default: 0.8, unit: "s",
                when: .init("where", ["all"])),
            .number(
                "threshold", "Silence is quieter than", -80...(-20), step: 1, default: -45,
                unit: "dB"),
        ],
        requirements: ffmpeg, keywords: ["pauses", "gaps", "dead air", "podcast", "trim"],
        actionTitle: "Remove silence"
    ) { run in
        let threshold = "\(Int(run.settings.number("threshold")))dB"
        let filter: String
        if run.settings.text("where") == "ends" {
            let edge = "silenceremove=start_periods=1:start_threshold=\(threshold)"
            filter = "\(edge),areverse,\(edge),areverse"
        } else {
            filter =
                "silenceremove=start_periods=1:start_threshold=\(threshold):"
                + "stop_periods=-1:stop_threshold=\(threshold):"
                + "stop_duration=\(FFmpeg.seconds(run.settings.number("pause")))"
        }
        return [try await edited(run, filter: filter, suffix: "tightened")]
    }

    static let denoise = StudioTool(
        id: "audio.denoise", title: "Reduce audio noise",
        summary: "Lower steady background noise such as hiss, hum and fans.",
        symbol: "wand.and.stars", group: .optimize, inputs: [.audio],
        options: [
            .choice(
                "strength", "Strength",
                [
                    StudioChoice("light", "Light"), StudioChoice("medium", "Medium"),
                    StudioChoice("strong", "Strong"),
                ], default: "medium"),
            .toggle("rumble", "Also cut low rumble", default: true),
        ],
        requirements: ffmpeg, keywords: ["hiss", "hum", "noise", "clean", "voice"],
        actionTitle: "Reduce noise"
    ) { run in
        let amount: Int
        switch run.settings.text("strength") {
        case "light": amount = 10
        case "strong": amount = 30
        default: amount = 20
        }
        var filter = "afftdn=nr=\(amount):nf=-30"
        if run.settings.bool("rumble") { filter = "highpass=f=80," + filter }
        return [try await edited(run, filter: filter, suffix: "denoised")]
    }

    static let toVideo = StudioTool(
        id: "audio.to-video", title: "Audio to video",
        summary: "Turn audio into an MP4 with a cover image or a moving waveform, ready to upload.",
        symbol: "play.rectangle", group: .convert, inputs: [.audio], produces: .kind(.video),
        options: [
            .choice(
                "style", "Picture",
                [StudioChoice("waveform", "Waveform"), StudioChoice("cover", "Cover image")],
                default: "waveform"),
            .file(
                "image", "Cover image", kinds: [.image], when: .init("style", ["cover"]),
                required: true),
            .color("color", "Wave color", default: "#D97757", when: .init("style", ["waveform"])),
            .choice(
                "size", "Size",
                [
                    StudioChoice("1280x720", "720p widescreen"),
                    StudioChoice("1080x1080", "Square 1080"),
                    StudioChoice("1080x1920", "Vertical 1080×1920"),
                ], default: "1280x720"),
        ],
        requirements: ffmpeg, keywords: ["youtube", "podcast", "waveform", "visualizer", "mp4"],
        actionTitle: "Make video"
    ) { run in
        let info = try await FFmpeg.info(run.input, run: run)
        guard info.hasAudio else { throw StudioError.nothingToDo("This file has no sound.") }
        let parts = run.settings.text("size").split(separator: "x").compactMap { Int($0) }
        let width = parts.count == 2 ? parts[0] : 1280
        let height = parts.count == 2 ? parts[1] : 720
        let output = run.output(for: run.input, suffix: nil, ext: "mp4")
        var arguments: [String]
        if run.settings.text("style") == "cover" {
            guard let image = run.settings.file("image") else {
                throw StudioError.invalidOption("cover image", "choose an image")
            }
            let cover = try run.scratch("cover").appendingPathComponent("cover.png")
            try MediaGraphics.slide(
                image, width: width, height: height, fill: false, background: .black, to: cover)
            arguments = [
                "-loop", "1", "-framerate", "2", "-i", cover.path, "-i", run.input.path,
                "-map", "0:v", "-map", "1:a:0", "-c:v", "libx264", "-tune", "stillimage",
                "-preset", "fast", "-crf", "22", "-pix_fmt", "yuv420p", "-r", "2",
            ]
        } else {
            let color = run.settings.color(
                "color", fallback: StudioColor(red: 0.85, green: 0.47, blue: 0.34))
            let hex = color.hex.dropFirst().prefix(6)
            let graph =
                "[0:a:0]showwaves=s=\(width)x\(height / 2):mode=cline:rate=25:colors=0x\(hex),"
                + "pad=\(width):\(height):0:(oh-ih)/2:color=0x111114,format=yuv420p[v]"
            arguments = [
                "-i", run.input.path, "-filter_complex", graph, "-map", "[v]", "-map", "0:a:0",
            ]
            arguments += MediaEncoding.video(container: "mp4")
        }
        arguments += ["-c:a", "aac", "-b:a", "192k", "-shortest"]
        if let duration = info.duration { arguments += ["-t", FFmpeg.seconds(duration)] }
        arguments += MediaEncoding.finishing(container: "mp4") + [output.path]
        _ = try await FFmpeg.execute(arguments, run: run, expected: info.duration)
        return [output]
    }
}
