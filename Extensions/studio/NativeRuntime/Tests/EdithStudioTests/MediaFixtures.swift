import CoreGraphics
import Foundation
import Testing

@testable import EdithStudio

enum MediaFixtures {
    static let environment = StudioEnvironment.detect()
    static var available: Bool {
        environment.ffmpeg != nil && FFmpeg.ffprobe(in: environment) != nil
    }

    static func ffmpeg(_ arguments: [String]) async throws {
        guard let ffmpeg = environment.ffmpeg else { throw StudioError.needsEngine(.ffmpeg) }
        let result = try await StudioProcess.run(
            ffmpeg, ["-hide_banner", "-nostdin", "-y", "-loglevel", "error"] + arguments,
            timeout: 120)
        guard result.status == 0 else { throw StudioError.failed(result.errorTail) }
    }

    static func clip(
        at url: URL, seconds: Double = 3, size: String = "160x120", audio: Bool = true,
        source: String? = nil, videoFilter: String? = nil, lossless: Bool = false
    ) async throws {
        let video = source ?? "testsrc2=size=\(size):rate=25"
        var arguments = ["-f", "lavfi", "-i", "\(video):duration=\(seconds)"]
        if audio {
            arguments += [
                "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=\(seconds)",
            ]
        }
        if let videoFilter { arguments += ["-vf", videoFilter] }
        arguments += ["-c:v", "libx264", "-pix_fmt", "yuv420p"]
        arguments += lossless ? ["-qp", "0", "-preset", "ultrafast"] : ["-preset", "ultrafast"]
        if audio { arguments += ["-c:a", "aac", "-b:a", "128k", "-shortest"] }
        try await ffmpeg(arguments + [url.path])
    }

    static func tone(
        at url: URL, seconds: Double = 3, frequency: Int = 440, codec: [String] = []
    ) async throws {
        try await ffmpeg(
            [
                "-f", "lavfi", "-i",
                "sine=frequency=\(frequency):sample_rate=48000:duration=\(seconds)", "-ac", "2",
            ] + codec + [url.path])
    }

    static func probe(_ url: URL) async throws -> StudioMediaInfo {
        guard let ffprobe = FFmpeg.ffprobe(in: environment) else {
            throw StudioError.needsEngine(.ffmpeg)
        }
        return try await FFmpeg.probe(url, ffprobe: ffprobe)
    }

    static func frame(_ url: URL, at seconds: Double, in space: Workspace) async throws -> CGImage {
        let output = space.url("frame-\(UUID().uuidString).png")
        try await ffmpeg(["-ss", String(seconds), "-i", url.path, "-frames:v", "1", output.path])
        return try StudioImageIO.load(output)
    }

    static func near(_ value: Double?, _ expected: Double, tolerance: Double = 0.3) -> Bool {
        guard let value else { return false }
        return abs(value - expected) <= tolerance
    }
}
