import AVFoundation
import Foundation

public struct StudioMediaInfo: Sendable, Equatable {
    public var duration: Double?
    public var width: Int?
    public var height: Int?
    public var rotation: Int
    public var videoCodec: String?
    public var audioCodec: String?
    public var frameRate: Double?
    public var frameCount: Int?
    public var sampleRate: Int?
    public var channels: Int?
    public var bitRate: Int?
    public var formatName: String?
    public var subtitleTracks = 0
    public var bitDepth: Int?
    public var pixelFormat: String?
    public var videoDuration: Double?
    public var audioDuration: Double?

    public var hasVideo: Bool { videoCodec != nil }
    public var hasAudio: Bool { audioCodec != nil }

    public var displaySize: CGSize? {
        guard let width, let height else { return nil }
        let turned = abs(rotation) % 180 == 90
        return turned
            ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
    }

    public init(
        duration: Double? = nil, width: Int? = nil, height: Int? = nil, rotation: Int = 0,
        videoCodec: String? = nil, audioCodec: String? = nil, frameRate: Double? = nil,
        frameCount: Int? = nil, sampleRate: Int? = nil, channels: Int? = nil,
        bitRate: Int? = nil, formatName: String? = nil
    ) {
        self.duration = duration
        self.width = width
        self.height = height
        self.rotation = rotation
        self.videoCodec = videoCodec
        self.audioCodec = audioCodec
        self.frameRate = frameRate
        self.frameCount = frameCount
        self.sampleRate = sampleRate
        self.channels = channels
        self.bitRate = bitRate
        self.formatName = formatName
    }
}

extension StudioMediaInfo {
    var pictureLength: Double? {
        guard let duration else { return videoDuration }
        return min(videoDuration ?? duration, duration)
    }

    var soundLength: Double? { audioDuration ?? duration }

    var padToPicture: String {
        let missing = (videoDuration ?? 0) - (audioDuration ?? .infinity)
        return missing > 0 ? "apad=pad_dur=\(FFmpeg.seconds(missing))," : ""
    }
}

public enum StudioMedia {
    public static func probe(_ url: URL, environment: StudioEnvironment) async -> StudioMediaInfo? {
        if let ffprobe = FFmpeg.ffprobe(in: environment),
            let info = try? await FFmpeg.probe(url, ffprobe: ffprobe)
        {
            return info
        }
        return await FFmpeg.probeWithAVFoundation(url)
    }
}

enum FFmpeg {
    static let progressArguments = ["-progress", "pipe:1", "-nostats"]

    static func ffprobe(in environment: StudioEnvironment) -> URL? {
        if let ffprobe = environment.ffprobe { return ffprobe }
        guard let ffmpeg = environment.ffmpeg else { return nil }
        let sibling = ffmpeg.deletingLastPathComponent().appendingPathComponent("ffprobe")
        return FileManager.default.isExecutableFile(atPath: sibling.path) ? sibling : nil
    }

    static func probe(_ url: URL, ffprobe: URL) async throws -> StudioMediaInfo {
        let report = FileManager.default.temporaryDirectory.appendingPathComponent(
            "edith-studio-probe-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: report) }
        let result = try await StudioProcess.run(
            ffprobe,
            [
                "-v", "error", "-print_format", "json", "-show_format", "-show_streams", "-o",
                report.path, url.path,
            ], timeout: 60)
        guard result.status == 0, let data = try? Data(contentsOf: report),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw StudioError.unreadable(url.lastPathComponent) }
        return parse(object)
    }

    static func parse(_ object: [String: Any]) -> StudioMediaInfo {
        var info = StudioMediaInfo()
        let format = object["format"] as? [String: Any] ?? [:]
        info.duration = number(format["duration"])
        info.bitRate = number(format["bit_rate"]).map { Int($0) }
        info.formatName = format["format_name"] as? String
        for stream in object["streams"] as? [[String: Any]] ?? [] {
            let type = stream["codec_type"] as? String
            let disposition = stream["disposition"] as? [String: Any]
            let attached = (disposition?["attached_pic"] as? Int ?? 0) == 1
            if type == "video", info.videoCodec == nil, !attached {
                info.videoCodec = stream["codec_name"] as? String
                info.width = stream["width"] as? Int
                info.height = stream["height"] as? Int
                info.frameRate =
                    rate(stream["avg_frame_rate"] as? String)
                    ?? rate(stream["r_frame_rate"] as? String)
                info.frameCount = number(stream["nb_frames"]).map { Int($0) }
                info.rotation = rotation(of: stream)
                info.pixelFormat = stream["pix_fmt"] as? String
                info.videoDuration = number(stream["duration"])
                if info.duration == nil { info.duration = number(stream["duration"]) }
            } else if type == "subtitle" {
                info.subtitleTracks += 1
            } else if type == "audio", info.audioCodec == nil {
                info.audioCodec = stream["codec_name"] as? String
                info.sampleRate = number(stream["sample_rate"]).map { Int($0) }
                info.channels = stream["channels"] as? Int
                info.bitDepth = bitDepth(of: stream)
                info.audioDuration = number(stream["duration"])
                if info.duration == nil { info.duration = number(stream["duration"]) }
            }
        }
        return info
    }

    static func rotation(of stream: [String: Any]) -> Int {
        if let tags = stream["tags"] as? [String: Any], let value = number(tags["rotate"]) {
            return Int(value)
        }
        for side in stream["side_data_list"] as? [[String: Any]] ?? [] {
            if let value = number(side["rotation"]) { return Int(value) }
        }
        return 0
    }

    static func bitDepth(of stream: [String: Any]) -> Int? {
        for key in ["bits_per_raw_sample", "bits_per_sample"] {
            if let bits = number(stream[key]), bits > 0 { return Int(bits) }
        }
        return nil
    }

    static func number(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? String, let parsed = Double(value), parsed.isFinite {
            return parsed
        }
        return nil
    }

    static func rate(_ text: String?) -> Double? {
        guard let text else { return nil }
        let parts = text.split(separator: "/").compactMap { Double($0) }
        guard parts.count == 2, parts[1] > 0, parts[0] > 0 else { return nil }
        return parts[0] / parts[1]
    }

    static func probeWithAVFoundation(_ url: URL) async -> StudioMediaInfo? {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration), duration.seconds.isFinite else {
            return nil
        }
        var info = StudioMediaInfo(duration: duration.seconds)
        if let track = try? await asset.loadTracks(withMediaType: .video).first {
            let size = (try? await track.load(.naturalSize)) ?? .zero
            info.width = Int(size.width)
            info.height = Int(size.height)
            info.videoCodec = "video"
            info.frameRate = (try? await track.load(.nominalFrameRate)).map { Double($0) }
            if let transform = try? await track.load(.preferredTransform) {
                let angle = atan2(transform.b, transform.a) * 180 / .pi
                info.rotation = Int(angle.rounded())
            }
        }
        if (try? await asset.loadTracks(withMediaType: .audio).first) != nil {
            info.audioCodec = "audio"
        }
        return info
    }

    static func info(_ url: URL, run: StudioRun) async throws -> StudioMediaInfo {
        if let ffprobe = ffprobe(in: run.environment) {
            return try await probe(url, ffprobe: ffprobe)
        }
        guard let info = await probeWithAVFoundation(url) else {
            throw StudioError.unreadable(url.lastPathComponent)
        }
        return info
    }

    static func execute(
        _ arguments: [String], run: StudioRun, expected: Double?,
        range: ClosedRange<Double>? = 0...1, loglevel: String = "error", complete: Bool = true
    ) async throws -> StudioProcessResult {
        let ffmpeg = try run.environment.require(.ffmpeg)
        let base = ["-hide_banner", "-nostdin", "-y", "-loglevel", loglevel] + progressArguments
        let total = expected.flatMap { $0 > 0 ? $0 : nil }
        let reached = FFmpegProgress()
        let result = try await StudioProcess.run(ffmpeg, base + arguments) { line in
            guard let seconds = progressSeconds(line) else { return }
            reached.record(seconds)
            guard let range, let total else { return }
            let span = range.upperBound - range.lowerBound
            run.progress(range.lowerBound + span * min(1, seconds / total))
        }
        try run.checkCancellation()
        guard result.status == 0 else {
            throw StudioError.failed("FFmpeg could not finish: " + summary(result.errorTail))
        }
        let stop = reached.seconds ?? 0
        if complete, let total, stop < total * 0.9 - 0.25,
            stop == 0 || !result.errorTail.isEmpty
        {
            throw StudioError.failed(
                "The source stops at \(StudioTime.format(stop)) of \(StudioTime.format(total)). "
                    + "It looks damaged or incomplete.")
        }
        if let range { run.progress(range.upperBound) }
        return result
    }

    static func progressSeconds(_ line: String) -> Double? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        for key in ["out_time_us=", "out_time_ms="] where trimmed.hasPrefix(key) {
            guard let value = Double(trimmed.dropFirst(key.count)), value >= 0 else { return nil }
            return value / 1_000_000
        }
        return nil
    }

    static func summary(_ errorTail: String) -> String {
        let lines = errorTail.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let tail = lines.suffix(3).joined(separator: " ")
        guard !tail.isEmpty else { return "it stopped without an error message." }
        return tail.count > 320 ? String(tail.suffix(320)) : tail
    }

    static func seconds(_ value: Double) -> String {
        String(format: "%.3f", max(0, value))
    }

    static func concatListEntry(_ url: URL) -> String {
        "file '" + url.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

final class FFmpegProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var furthest: Double?

    func record(_ seconds: Double) {
        lock.lock()
        furthest = max(furthest ?? 0, seconds)
        lock.unlock()
    }

    var seconds: Double? {
        lock.lock()
        defer { lock.unlock() }
        return furthest
    }
}
