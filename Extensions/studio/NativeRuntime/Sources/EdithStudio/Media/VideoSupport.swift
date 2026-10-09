import Foundation

enum MediaFiles {
    static func produced(in directory: URL, prefix: String) -> [URL] {
        let items =
            (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.isRegularFileKey])) ?? []
        return items.filter { $0.lastPathComponent.hasPrefix(prefix) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}

enum VideoInput {
    static func info(_ run: StudioRun, _ url: URL? = nil) async throws -> StudioMediaInfo {
        let source = url ?? run.input
        let info = try await FFmpeg.info(source, run: run)
        guard info.hasVideo else {
            throw StudioError.unsupportedInput(source.lastPathComponent, run.tool.title)
        }
        return info
    }

    static func length(of span: StudioSpan, within total: Double?) -> Double? {
        guard let length = span.duration(within: total) else { return nil }
        guard let total else { return length }
        return max(0, min(length, total - span.start))
    }
}

enum VideoFilter {
    static func apply(
        _ run: StudioRun, video: String? = nil, audio: String? = nil, dropAudio: Bool = false,
        suffix: String, info known: StudioMediaInfo? = nil, expected: Double? = nil
    ) async throws -> URL {
        let info: StudioMediaInfo
        if let known {
            info = known
        } else {
            info = try await FFmpeg.info(run.input, run: run)
        }
        guard info.hasVideo else {
            throw StudioError.unsupportedInput(run.input.lastPathComponent, run.tool.title)
        }
        let container = MediaEncoding.videoContainer(for: run.input)
        let copyable = MediaEncoding.editableContainers.contains(
            run.input.pathExtension.lowercased())
        let output = run.output(for: run.input, suffix: suffix, ext: container)
        var arguments = ["-i", run.input.path, "-map", "0:v:0"]
        if !dropAudio { arguments += ["-map", "0:a:0?"] }
        arguments += ["-map_metadata", "0"]
        if let video {
            arguments += ["-vf", video + "," + MediaEncoding.evenFilter]
            arguments += MediaEncoding.video(container: container)
        } else if copyable {
            arguments += ["-c:v", "copy"]
        } else {
            arguments +=
                ["-vf", MediaEncoding.evenFilter] + MediaEncoding.video(container: container)
        }
        if dropAudio {
            arguments += ["-an"]
        } else if let audio {
            arguments += ["-af", audio]
            arguments += MediaEncoding.audio(container: container, source: info, allowCopy: false)
        } else {
            arguments += MediaEncoding.audio(container: container, source: info, allowCopy: true)
        }
        arguments += MediaEncoding.finishing(container: container) + [output.path]
        _ = try await FFmpeg.execute(arguments, run: run, expected: expected ?? info.duration)
        return output
    }

    static func overlay(
        _ run: StudioRun, image: URL, info: StudioMediaInfo, suffix: String
    ) async throws -> URL {
        let container = MediaEncoding.videoContainer(for: run.input)
        let output = run.output(for: run.input, suffix: suffix, ext: container)
        let graph =
            "[0:v:0][1:v]overlay=0:0:format=auto,format=yuv420p,\(MediaEncoding.evenFilter)[v]"
        var arguments = ["-i", run.input.path, "-i", image.path, "-filter_complex", graph]
        arguments += ["-map", "[v]", "-map", "0:a:0?", "-map_metadata", "0"]
        arguments += MediaEncoding.video(container: container)
        arguments += MediaEncoding.audio(container: container, source: info, allowCopy: true)
        arguments += MediaEncoding.finishing(container: container) + [output.path]
        _ = try await FFmpeg.execute(arguments, run: run, expected: info.duration)
        return output
    }
}

enum GIFEncoder {
    static func encode(
        _ input: URL, to output: URL, fps: Int, width: Int?, span: StudioSpan, loop: Bool,
        run: StudioRun, duration: Double?
    ) async throws {
        var arguments: [String] = []
        if span.start > 0 { arguments += ["-ss", FFmpeg.seconds(span.start)] }
        arguments += ["-i", input.path]
        let length = VideoInput.length(of: span, within: duration)
        if span.end != nil, let length { arguments += ["-t", FFmpeg.seconds(length)] }
        let scale = width.map { ",scale=\($0):-1:flags=lanczos" } ?? ""
        let rate = min(50, max(1, fps))
        let graph =
            "[0:v:0]fps=\(rate)\(scale),split[a][b];[a]palettegen=stats_mode=diff[p];"
            + "[b][p]paletteuse=dither=bayer:bayer_scale=5:diff_mode=rectangle"
        arguments += ["-filter_complex", graph, "-loop", loop ? "0" : "-1", output.path]
        _ = try await FFmpeg.execute(arguments, run: run, expected: length ?? duration)
    }
}

enum FrameGrabber {
    static func grab(
        _ input: URL, at time: Double, end: Double?, filters: [String], quality: [String],
        to output: URL, run: StudioRun
    ) async throws {
        var picture = ["-map", "0:v:0"]
        if !filters.isEmpty { picture += ["-vf", filters.joined(separator: ",")] }
        let seek =
            ["-ss", FFmpeg.seconds(time), "-i", input.path] + picture
            + ["-frames:v", "1", "-update", "1"] + quality + [output.path]
        do {
            _ = try await FFmpeg.execute(seek, run: run, expected: nil, range: nil)
        } catch StudioError.cancelled {
            throw StudioError.cancelled
        } catch {
            try? FileManager.default.removeItem(at: output)
        }
        if FileManager.default.fileExists(atPath: output.path) { return }
        let rewind =
            end.map { ["-ss", FFmpeg.seconds(min(time, $0) - 1)] } ?? ["-sseof", "-1"]
        let tail = rewind + ["-i", input.path] + picture + ["-update", "1"] + quality
        _ = try await FFmpeg.execute(tail + [output.path], run: run, expected: nil, range: nil)
        guard FileManager.default.fileExists(atPath: output.path) else {
            throw StudioError.nothingToDo(
                "\(StudioTime.format(time)) is past the end of the video.")
        }
    }
}

enum CropDetector {
    static func detect(_ input: URL, run: StudioRun, duration: Double?) async throws -> CGRect? {
        let sample = min(duration ?? 30, 30)
        let report = try run.scratch("cropdetect").appendingPathComponent("crop.txt")
        guard !report.path.contains("'") else { return nil }
        _ = try await FFmpeg.execute(
            [
                "-i", input.path, "-t", FFmpeg.seconds(sample), "-map", "0:v:0", "-vf",
                "cropdetect=limit=24:round=2:reset=0,metadata=mode=print:file='\(report.path)'",
                "-f", "null", "-",
            ], run: run, expected: sample, range: 0...0.3)
        guard let text = try? String(contentsOf: report, encoding: .utf8) else { return nil }
        return parse(text)
    }

    static func parse(_ log: String) -> CGRect? {
        var values: [String: Double] = [:]
        for line in log.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, parts[0].hasPrefix("lavfi.cropdetect.") else { continue }
            values[String(parts[0].dropFirst("lavfi.cropdetect.".count))] = Double(parts[1])
        }
        guard let width = values["w"], let height = values["h"], width > 0, height > 0 else {
            return nil
        }
        return CGRect(x: values["x"] ?? 0, y: values["y"] ?? 0, width: width, height: height)
    }
}

enum Reverser {
    static let memoryBudget = 1_000_000_000.0

    static func chunkLength(for info: StudioMediaInfo) -> Double {
        let format = info.pixelFormat ?? "yuv420p"
        let full = ["444", "rgb", "bgr", "gbr"].contains { format.contains($0) }
        let planes = full ? 3.0 : format.contains("422") ? 2.0 : 1.5
        let deep = ["10", "12", "16"].contains { format.contains($0) } ? 2.0 : 1.0
        let pixels = Double(max(1, info.width ?? 1920) * max(1, info.height ?? 1080))
        let rate = min(240, max(1, info.frameRate ?? 30))
        let seconds = memoryBudget / (pixels * planes * deep * rate)
        return min(10, max(1, seconds.rounded(.down)))
    }

    static func reverse(_ run: StudioRun, info: StudioMediaInfo, audio: Bool) async throws -> URL {
        let container = MediaEncoding.videoContainer(for: run.input)
        let output = run.output(for: run.input, suffix: "reversed", ext: container)
        let filters = ["-vf", "reverse," + MediaEncoding.evenFilter]
        func sound(until end: Double?) -> [String] {
            guard audio else { return ["-an"] }
            guard let end else { return ["-af", "areverse"] }
            return ["-af", info.padToPicture + "atrim=end=\(FFmpeg.seconds(end)),areverse"]
        }
        let maps = ["-map", "0:v:0"] + (audio ? ["-map", "0:a:0"] : [])
        let chunk = chunkLength(for: info)
        guard let duration = info.duration, duration > chunk * 2 else {
            var arguments = ["-i", run.input.path] + maps + filters
            arguments += sound(until: info.videoDuration)
            arguments += MediaEncoding.video(container: container)
            if audio {
                arguments += MediaEncoding.audio(
                    container: container, source: info, allowCopy: false)
            }
            arguments += MediaEncoding.finishing(container: container) + [output.path]
            _ = try await FFmpeg.execute(arguments, run: run, expected: info.duration)
            return output
        }
        let scratch = try run.scratch("reverse")
        let picture = min(info.videoDuration ?? duration, duration)
        var count = max(1, Int((picture / chunk).rounded(.up)))
        if count > 1, picture - Double(count - 1) * chunk < 0.5 { count -= 1 }
        var pieces: [URL] = []
        for index in 0..<count {
            try run.checkCancellation()
            let piece = scratch.appendingPathComponent(String(format: "piece-%04d.mp4", index))
            let start = Double(index) * chunk
            let last = index == count - 1
            var arguments = ["-ss", FFmpeg.seconds(start)]
            if !last { arguments += ["-t", FFmpeg.seconds(chunk)] }
            arguments += ["-i", run.input.path] + maps + filters
            arguments += sound(until: last ? info.videoDuration.map { $0 - start } : nil)
            arguments += [
                "-c:v", "libx264", "-preset", "fast", "-crf", "18", "-pix_fmt", "yuv420p",
            ]
            if audio { arguments += ["-c:a", "aac", "-b:a", "192k", "-ar", "48000", "-ac", "2"] }
            arguments.append(piece.path)
            let low = Double(index) / Double(count) * 0.9
            let high = Double(index + 1) / Double(count) * 0.9
            _ = try await FFmpeg.execute(
                arguments, run: run, expected: last ? picture - start : chunk, range: low...high)
            pieces.append(piece)
        }
        let list = scratch.appendingPathComponent("list.txt")
        try pieces.reversed().map(FFmpeg.concatListEntry).joined(separator: "\n")
            .write(to: list, atomically: true, encoding: .utf8)
        _ = try await FFmpeg.execute(
            ["-f", "concat", "-safe", "0", "-i", list.path, "-c", "copy"]
                + MediaEncoding.finishing(container: container) + [output.path],
            run: run, expected: duration, range: 0.9...1)
        return output
    }
}

enum Captions {
    static func decode(_ file: URL) throws -> String {
        let data = try Data(contentsOf: file)
        for encoding in [String.Encoding.utf8, .utf16, .windowsCP1252, .isoLatin1] {
            if encoding == .utf16,
                !(data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]))
            {
                continue
            }
            if let text = String(data: data, encoding: encoding) { return text }
        }
        throw StudioError.unreadable(file.lastPathComponent)
    }

    static func track(_ run: StudioRun, subtitles: URL, text: String, info: StudioMediaInfo)
        async throws -> URL
    {
        let ext = run.input.pathExtension.lowercased()
        let container = MediaEncoding.editableContainers.contains(ext) ? ext : "mkv"
        let output = run.output(for: run.input, suffix: "subtitled", ext: container)
        let kind = subtitles.pathExtension.lowercased() == "vtt" ? "vtt" : "srt"
        let unicode = try run.scratch("subtitles").appendingPathComponent("captions.\(kind)")
        try text.replacingOccurrences(of: "\u{FEFF}", with: "").write(
            to: unicode, atomically: true, encoding: .utf8)
        var arguments = ["-i", run.input.path, "-i", unicode.path]
        arguments += [
            "-map", "0:v:0", "-map", "0:a:0?", "-map", "1:0", "-c:v", "copy", "-c:a", "copy",
        ]
        arguments += ["-c:s", container == "mkv" ? "srt" : "mov_text"]
        arguments += ["-metadata:s:s:0", "language=und"]
        arguments += MediaEncoding.finishing(container: container) + [output.path]
        _ = try await FFmpeg.execute(arguments, run: run, expected: info.duration)
        return output
    }

    static func burn(_ run: StudioRun, cues: [SubtitleCue], info: StudioMediaInfo) async throws
        -> URL
    {
        guard let size = info.displaySize else {
            throw StudioError.unreadable(run.input.lastPathComponent)
        }
        let width = Int(size.width)
        let height = Int(size.height)
        let duration = info.duration ?? ((cues.map(\.end).max() ?? 0) + 1)
        let style = MediaGraphics.CaptionStyle(
            fontSize: max(8, Double(height) * run.settings.number("size")),
            color: run.settings.color("color", fallback: .white), box: run.settings.bool("box"),
            top: run.settings.text("place") == "top")
        let scratch = try run.scratch("captions")
        var rendered: [String: URL] = [:]
        var entries: [String] = []
        var last: URL?
        for segment in SubtitleParser.timeline(cues, duration: duration) {
            try run.checkCancellation()
            let image: URL
            if let existing = rendered[segment.text] {
                image = existing
            } else {
                image = scratch.appendingPathComponent(
                    String(format: "cue-%05d.png", rendered.count))
                try MediaGraphics.caption(
                    segment.text, width: width, height: height, style: style, to: image)
                rendered[segment.text] = image
            }
            entries.append(FFmpeg.concatListEntry(image))
            entries.append("duration " + FFmpeg.seconds(segment.end - segment.start))
            last = image
        }
        if let last { entries.append(FFmpeg.concatListEntry(last)) }
        let list = scratch.appendingPathComponent("captions.txt")
        try entries.joined(separator: "\n").write(to: list, atomically: true, encoding: .utf8)
        run.progress(0.1)
        let container = MediaEncoding.videoContainer(for: run.input)
        let output = run.output(for: run.input, suffix: "captioned", ext: container)
        let graph =
            "[1:v]format=rgba[s];[0:v:0][s]overlay=0:0:eof_action=pass:format=auto,"
            + "format=yuv420p,\(MediaEncoding.evenFilter)[v]"
        var arguments = ["-i", run.input.path, "-f", "concat", "-safe", "0", "-i", list.path]
        arguments += ["-filter_complex", graph, "-map", "[v]", "-map", "0:a:0?"]
        arguments += MediaEncoding.video(container: container)
        arguments += MediaEncoding.audio(container: container, source: info, allowCopy: true)
        arguments += MediaEncoding.finishing(container: container) + [output.path]
        _ = try await FFmpeg.execute(arguments, run: run, expected: duration, range: 0.1...1)
        return output
    }
}

enum Slideshow {
    static func make(_ run: StudioRun) async throws -> [URL] {
        let parts = run.settings.text("size").split(separator: "x").compactMap { Int($0) }
        let width = parts.count == 2 ? parts[0] : 1920
        let height = parts.count == 2 ? parts[1] : 1080
        let each = max(0.5, run.settings.number("seconds"))
        let count = run.inputs.count
        let fade = run.settings.bool("crossfade") && count > 1 ? min(1, each / 3) : 0
        let total = Double(count) * each - Double(count - 1) * fade
        let scratch = try run.scratch("slides")
        var arguments: [String] = []
        for (index, input) in run.inputs.enumerated() {
            try run.checkCancellation()
            let slide = scratch.appendingPathComponent(String(format: "slide-%04d.png", index))
            try MediaGraphics.slide(
                input, width: width, height: height, fill: run.settings.text("fit") == "fill",
                background: run.settings.color("background"), to: slide)
            arguments += [
                "-loop", "1", "-framerate", "30", "-t", FFmpeg.seconds(each), "-i", slide.path,
            ]
            run.progress(Double(index + 1) / Double(count) * 0.2)
        }
        var chains = (0..<count).map {
            "[\($0):v]fps=30,settb=AVTB,format=yuv420p,setsar=1[s\($0)]"
        }
        if count == 1 {
            chains.append("[s0]null[v]")
        } else if fade > 0 {
            var previous = "s0"
            for index in 1..<count {
                let label = index == count - 1 ? "v" : "x\(index)"
                let offset = Double(index) * (each - fade)
                chains.append(
                    "[\(previous)][s\(index)]xfade=transition=fade:duration=\(FFmpeg.seconds(fade)):"
                        + "offset=\(FFmpeg.seconds(offset))[\(label)]")
                previous = label
            }
        } else {
            chains.append((0..<count).map { "[s\($0)]" }.joined() + "concat=n=\(count):v=1:a=0[v]")
        }
        var maps = ["-map", "[v]"]
        if let music = run.settings.file("audio") {
            let tail = min(2, total / 4)
            arguments += ["-i", music.path]
            chains.append(
                "[\(count):a:0]aformat=sample_fmts=fltp:sample_rates=48000:channel_layouts=stereo,"
                    + "apad,atrim=duration=\(FFmpeg.seconds(total)),"
                    + "afade=t=out:st=\(FFmpeg.seconds(total - tail)):d=\(FFmpeg.seconds(tail))[a]")
            maps += ["-map", "[a]", "-c:a", "aac", "-b:a", "192k"]
        }
        let output = run.output(for: run.inputs[0], suffix: "slideshow", ext: "mp4")
        arguments += ["-filter_complex", chains.joined(separator: ";")] + maps
        arguments +=
            MediaEncoding.video(container: "mp4") + ["-r", "30", "-t", FFmpeg.seconds(total)]
        arguments += MediaEncoding.finishing(container: "mp4") + [output.path]
        _ = try await FFmpeg.execute(arguments, run: run, expected: total, range: 0.2...1)
        return [output]
    }
}
