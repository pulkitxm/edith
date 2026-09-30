@preconcurrency import AVFoundation
import EdithStudio
import Foundation

public struct VideoAACPassthroughReport: Codable, Sendable {
    public let sourcePath: String
    public let sourceSHA256: String
    public let packetCount: Int
    public let timeBase: String
    public let packetDataAndTimingVerified: Bool
}

enum VideoAACPassthrough {
    struct Stream: Decodable, Equatable {
        let codec_name: String
        let sample_rate: String
        let channels: Int
        let time_base: String
        let start_pts: Int64
        let duration_ts: Int64
        let extradata_hash: String?
    }

    struct Packet: Codable, Equatable {
        struct SideData: Codable, Equatable {
            let side_data_type: String
            let skip_samples: Int?
            let discard_padding: Int?
            let skip_reason: Int?
            let discard_reason: Int?
        }
        let pts: Int64
        let dts: Int64
        let duration: Int64
        let data_hash: String
        let side_data_list: [SideData]?
    }

    struct Probe: Decodable {
        let streams: [Stream]
        let packets: [Packet]
    }

    struct Prepared {
        let source: URL
        let sourceHash: String
        let probe: Probe
        let environment: StudioEnvironment
    }

    static func reject(_ message: String) -> VideoEditorService.Failure {
        .init("invalid_audio_copy", message + " Use AAC encoding to render audio edits.")
    }

    static func prepare(
        _ project: VideoProject, settings: VideoDeliverySettings,
        range: VideoDeliveryFrameRange?
    ) async throws -> Prepared {
        guard range == nil else {
            throw reject(
                "AAC copy supports only the complete stream from zero to end; delivery frame ranges are not supported."
            )
        }
        guard let id = settings.audioCopyTrackID,
            let track = project.audioTracks.first(where: { $0.id == id }), !track.muted,
            project.audioTracks.filter({ !$0.muted }).count == 1,
            let source = project.assets.first(where: { $0.id == track.assetID })
        else {
            throw reject("Supply --audio-copy-track for the single audible independent soundtrack.")
        }
        guard track.timebase == "output", track.outputRange.start == .zero,
            track.offsetMs == 0, track.gainDb == 0, track.rate == 1,
            !track.loop, track.fadeInMs == 0, track.fadeOutMs == 0,
            track.raw["gainEnvelope"] == nil
        else {
            throw reject(
                "AAC copy requires output/source start zero, unity gain/rate, no loops, fades or gain envelope."
            )
        }
        for clip in project.clips where clip.raw["audioMuted"] as? Bool != true {
            guard let asset = project.assets.first(where: { $0.id == clip.assetID }) else {
                throw reject("A clip references missing media.")
            }
            if asset.isStill && asset.raw["edithAudioPath"] == nil { continue }
            guard
                try await AVURLAsset(url: asset.audioURL).loadTracks(withMediaType: .audio).isEmpty
            else {
                throw reject(
                    "Mute attached clip audio before copying a single independent soundtrack.")
            }
        }
        let environment = StudioEnvironment.detect()
        guard environment.ffmpeg != nil, environment.ffprobe != nil else {
            throw VideoEditorService.Failure(
                "audio_copy_backend_unavailable",
                "AAC packet copy and verification require FFmpeg and ffprobe on PATH.")
        }
        let probe = try await probe(source.audioURL, environment: environment)
        guard probe.streams.count == 1, let stream = probe.streams.first,
            stream.codec_name == "aac", stream.start_pts == 0, stream.duration_ts > 0,
            stream.extradata_hash != nil,
            let rate = Int(stream.sample_rate), stream.time_base == "1/\(rate)",
            rate == settings.audioSampleRate, stream.channels == settings.audioChannels
        else {
            throw reject(
                "Expected one zero-based AAC stream with requested sample rate/channels. Set --audio-sample-rate and --audio-channels to match the source."
            )
        }
        let duration = CMTime(value: stream.duration_ts, timescale: Int32(rate))
        let end = VideoRenderPipeline.timingSegments(project: project).last?.outputRange.end
        guard track.outputRange.duration == duration, end == duration else {
            throw reject(
                "Soundtrack and video must cover exactly the complete AAC stream. Trims, partial packets and source offsets are unsupported."
            )
        }
        guard let first = probe.packets.first, let last = probe.packets.last,
            first.pts <= 0, last.pts + last.duration == stream.duration_ts,
            probe.packets.allSatisfy({
                $0.pts == $0.dts && $0.duration > 0 && $0.data_hash.hasPrefix("SHA256:")
            }),
            zip(probe.packets, probe.packets.dropFirst()).allSatisfy({
                $0.pts + $0.duration == $1.pts
            })
        else {
            throw reject("AAC packet timing contains a gap, overlap or ambiguous stream boundary.")
        }
        if first.pts < 0 {
            guard
                first.side_data_list?.contains(where: {
                    $0.side_data_type == "Skip Samples" && Int64($0.skip_samples ?? 0) == -first.pts
                }) == true
            else {
                throw reject("AAC preroll has no matching encoder-delay metadata.")
            }
        }
        return Prepared(
            source: source.audioURL, sourceHash: try StudioAudioMastering.sha256(source.audioURL),
            probe: probe, environment: environment)
    }

    static func export(
        _ prepared: Prepared, pipeline: VideoRenderPipeline, to output: URL,
        settings: VideoDeliverySettings, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> VideoDeliveryReport {
        let video = VideoEditorService.temporaryOutput(output)
        defer { try? FileManager.default.removeItem(at: video) }
        var encoding = settings
        encoding.audioCodec = .aac
        encoding.audioCopyTrackID = nil
        encoding.audioSampleRate = 48_000
        encoding.audioChannels = 2
        let native = try await pipeline.export(to: video, settings: encoding, includeAudio: false) {
            progress(min(0.9, $0 * 0.9))
        }
        let rate = Int32(prepared.probe.streams[0].sample_rate)!
        let timescale = CMTimeAdd(
            pipeline.videoComposition.frameDuration,
            CMTime(value: 1, timescale: rate)
        ).timescale
        let copied = try await mux(
            prepared, video: video, output: output, movieTimescale: timescale)
        var report = try await VideoDeliveryReport.inspect(output)
        guard report.frameCount == native.frameCount, report.width == native.width,
            report.height == native.height, report.audioCodec == "aac "
        else {
            throw VideoEditorService.Failure(
                "audio_copy_verification_failed",
                "Remuxed delivery differs from native video or lacks AAC audio.")
        }
        report.range = native.range
        report.audioPassthrough = copied
        return report
    }

    static func mux(_ prepared: Prepared, video: URL, output: URL, movieTimescale: Int32)
        async throws -> VideoAACPassthroughReport
    {
        guard let executable = prepared.environment.ffmpeg else {
            throw reject("FFmpeg is unavailable.")
        }
        let result = try await StudioProcess.run(
            executable,
            [
                "-hide_banner", "-nostdin", "-n",
                "-copyts", "-i", video.path, "-i", prepared.source.path,
                "-map", "0:v:0", "-map", "1:a:0", "-c", "copy", "-map_metadata", "-1",
                "-avoid_negative_ts", "disabled", "-movie_timescale", String(movieTimescale),
                "-movflags", "+faststart", output.path,
            ], timeout: 21_600)
        guard result.status == 0 else {
            throw VideoEditorService.Failure(
                "audio_copy_failed", "AAC remux failed: " + result.errorTail)
        }
        let copied = try await probe(output, environment: prepared.environment)
        guard copied.streams.count == 1, let stream = copied.streams.first,
            stream == prepared.probe.streams[0], copied.packets == prepared.probe.packets,
            try StudioAudioMastering.sha256(prepared.source) == prepared.sourceHash
        else {
            throw VideoEditorService.Failure(
                "audio_copy_verification_failed",
                "AAC packet bytes, PTS/DTS, durations, delay/padding or source changed. No delivery was published."
            )
        }
        return VideoAACPassthroughReport(
            sourcePath: prepared.source.path,
            sourceSHA256: prepared.sourceHash, packetCount: copied.packets.count,
            timeBase: stream.time_base, packetDataAndTimingVerified: true)
    }

    static func probe(_ source: URL, environment: StudioEnvironment) async throws -> Probe {
        guard let executable = environment.ffprobe else { throw reject("ffprobe is unavailable.") }
        let result = try await StudioProcess.run(
            executable,
            [
                "-v", "error", "-select_streams", "a",
                "-show_streams", "-show_packets", "-show_data_hash", "sha256", "-of", "json",
                source.path,
            ], timeout: 300, captureLimit: 64 << 20)
        guard result.status == 0 else {
            throw reject("Cannot probe AAC packets: " + result.errorTail)
        }
        do { return try JSONDecoder().decode(Probe.self, from: Data(result.output.utf8)) } catch {
            throw reject(
                "Missing or unsupported AAC stream/packet metadata, or packet report exceeded 64 MiB."
            )
        }
    }
}
