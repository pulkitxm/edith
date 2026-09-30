import AVFoundation
import CryptoKit
import Foundation

public enum StudioAudioMastering {
    public struct Failure: LocalizedError, Sendable {
        public let code: String
        public let message: String
        public var errorDescription: String? { message }
        public init(_ code: String, _ message: String) {
            self.code = code
            self.message = message
        }
    }

    public struct Health: Codable, Sendable {
        public let version: Int
        public let backend: String
        public let available: Bool
        public let executable: String?
        public let engineVersion: String?
        public let reason: String?
    }

    public struct Measurement: Codable, Sendable {
        public let integratedLUFS: Double?
        public let loudnessRangeLU: Double
        public let truePeakDBTP: Double?
        public let thresholdLUFS: Double?
        public let silent: Bool
    }

    public struct Request: Codable, Sendable {
        public let durationSeconds: Double
        public init(durationSeconds: Double) { self.durationSeconds = durationSeconds }
    }

    public struct Recipe: Codable, Sendable {
        public let sourceStartSeconds: Double
        public let sampleFrames: Int64
        public let sampleRate: Int
        public let channels: Int
        public let fadeOutSeconds: Double
        public let integratedLUFS: Double
        public let truePeakDBTP: Double
        public let loudnessRangeLU: Double
        public let passes: Int
        public let integratedToleranceLU: Double
        public let peakToleranceDB: Double
        public let rangeToleranceLU: Double
    }

    public struct Report: Codable, Sendable {
        public let version: Int
        public let backend: Health
        public let originalPath: String
        public let originalSHA256: String
        public let artifactSHA256: String
        public let recipe: Recipe
        public let before: Measurement
        public let after: Measurement
        public let verified: Bool
    }

    private static let target = "loudnorm=I=-16:TP=-1.5:LRA=11"

    public static func health(environment: StudioEnvironment = .detect()) async -> Health {
        guard let executable = environment.ffmpeg else {
            return Health(
                version: 1, backend: "ffmpeg.loudnorm", available: false,
                executable: nil, engineVersion: nil,
                reason: "Install FFmpeg with the loudnorm filter and expose it on PATH.")
        }
        do {
            let filters = try await StudioProcess.run(
                executable, ["-hide_banner", "-filters"], timeout: 10)
            let version = try await StudioProcess.run(executable, ["-version"], timeout: 10)
            let available =
                filters.status == 0 && filters.output.contains(" loudnorm ") && version.status == 0
            return Health(
                version: 1, backend: "ffmpeg.loudnorm", available: available,
                executable: executable.path,
                engineVersion: version.output.components(separatedBy: .newlines).first,
                reason: available ? nil : "The detected FFmpeg does not provide loudnorm.")
        } catch {
            return Health(
                version: 1, backend: "ffmpeg.loudnorm", available: false,
                executable: executable.path, engineVersion: nil, reason: error.localizedDescription)
        }
    }

    public static func measure(_ source: URL, environment: StudioEnvironment = .detect())
        async throws -> Measurement
    {
        try await localSource(source)
        let backend = await health(environment: environment)
        guard backend.available, let path = backend.executable else {
            throw Failure("audio_backend_unavailable", backend.reason ?? "FFmpeg is unavailable.")
        }
        return try await analyze(source, filter: target, executable: URL(fileURLWithPath: path))
            .measurement
    }

    public static func master(
        _ source: URL, to output: URL, request: Request,
        environment: StudioEnvironment = .detect()
    ) async throws -> Report {
        try await localSource(source)
        let duration = request.durationSeconds
        guard duration.isFinite, duration >= 0.4, duration <= 86_400,
            abs(duration * 48_000 - (duration * 48_000).rounded()) < 0.00001
        else {
            throw Failure(
                "invalid_audio_duration",
                "Choose 0.4...86400 seconds aligned to an exact 48000 Hz sample.")
        }
        guard output.isFileURL, output.pathExtension.lowercased() == "wav",
            output.resolvingSymlinksInPath() != source.resolvingSymlinksInPath(),
            !FileManager.default.fileExists(atPath: output.path)
        else {
            throw Failure(
                "invalid_audio_destination",
                "Choose a new local .wav destination; mastering never overwrites files.")
        }
        let backend = await health(environment: environment)
        guard backend.available, let path = backend.executable else {
            throw Failure("audio_backend_unavailable", backend.reason ?? "FFmpeg is unavailable.")
        }
        let executable = URL(fileURLWithPath: path)
        let originalHash = try sha256(source)
        let frames = Int64((duration * 48_000).rounded())
        let preparation =
            "aresample=48000,aformat=sample_fmts=flt:channel_layouts=stereo,atrim=start_sample=0:end_sample=\(frames),asetpts=N/SR/TB,afade=t=out:ss=\(frames - 12_000):ns=12000"
        let first = try await analyze(
            source, filter: preparation + "," + target, executable: executable)
        guard !first.measurement.silent, let integrated = first.measurement.integratedLUFS,
            let peak = first.measurement.truePeakDBTP,
            let threshold = first.measurement.thresholdLUFS,
            let offset = Double(first.values["target_offset"] ?? ""), offset.isFinite
        else {
            throw Failure(
                "audio_unmeasurable",
                "Silent or gated-out audio cannot be mastered to an integrated loudness target.")
        }
        let second =
            target
            + ":measured_I=\(integrated):measured_TP=\(peak):measured_LRA=\(first.measurement.loudnessRangeLU):measured_thresh=\(threshold):offset=\(offset):linear=true:print_format=json"
        let temporary = output.deletingLastPathComponent().appendingPathComponent(
            ".\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: temporary) }
        _ = try await execute(
            executable,
            [
                "-i", source.path, "-map", "0:a:0", "-vn", "-af",
                preparation + "," + second + ",aresample=48000,atrim=end_sample=\(frames)",
                "-ar", "48000", "-ac", "2", "-c:a", "pcm_s24le", "-map_metadata", "-1", "-fflags",
                "+bitexact", temporary.path,
            ])
        let audio = try AVAudioFile(forReading: temporary)
        guard audio.length == frames, audio.fileFormat.sampleRate == 48_000,
            audio.fileFormat.channelCount == 2
        else {
            throw Failure(
                "audio_verification_failed",
                "The source is shorter than the requested duration or the PCM format/sample count does not match."
            )
        }
        let after = try await analyze(temporary, filter: target, executable: executable).measurement
        guard let measuredI = after.integratedLUFS, let measuredPeak = after.truePeakDBTP,
            abs(measuredI + 16) <= 0.3, measuredPeak <= -1.5 + 0.1,
            after.loudnessRangeLU <= 11 + 0.5
        else {
            throw Failure(
                "audio_verification_failed",
                "Rendered loudness did not meet -16 LUFS ±0.3 LU, -1.5 dBTP +0.1 dB, and LRA <=11.5 LU. No artifact was published."
            )
        }
        guard try sha256(source) == originalHash else {
            throw Failure(
                "audio_source_changed",
                "Source changed during mastering. No artifact was published.")
        }
        let report = Report(
            version: 1, backend: backend, originalPath: source.path,
            originalSHA256: originalHash, artifactSHA256: try sha256(temporary),
            recipe: Recipe(
                sourceStartSeconds: 0, sampleFrames: frames, sampleRate: 48_000,
                channels: 2, fadeOutSeconds: 0.25, integratedLUFS: -16, truePeakDBTP: -1.5,
                loudnessRangeLU: 11, passes: 2, integratedToleranceLU: 0.3,
                peakToleranceDB: 0.1, rangeToleranceLU: 0.5),
            before: first.measurement, after: after, verified: true)
        try Task.checkCancellation()
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o444], ofItemAtPath: temporary.path)
        try FileManager.default.moveItem(at: temporary, to: output)
        return report
    }

    public static func sha256(_ source: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: source)
        defer { try? file.close() }
        var digest = SHA256()
        while let data = try file.read(upToCount: 1 << 20), !data.isEmpty {
            try Task.checkCancellation()
            digest.update(data: data)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func localSource(_ source: URL) async throws {
        guard source.isFileURL,
            try source.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
        else {
            throw Failure("invalid_audio_source", "Expected a regular local audio source.")
        }
        guard try await AVURLAsset(url: source).loadTracks(withMediaType: .audio).count == 1 else {
            throw Failure(
                "invalid_audio_source",
                "Choose a source containing exactly one unambiguous audio stream.")
        }
    }

    private static func execute(_ executable: URL, _ arguments: [String]) async throws
        -> StudioProcessResult
    {
        let result = try await StudioProcess.run(
            executable,
            ["-hide_banner", "-nostdin", "-n", "-nostats"] + arguments, timeout: 21_600)
        guard result.status == 0 else {
            throw Failure("audio_processing_failed", "FFmpeg failed: " + result.errorTail)
        }
        return result
    }

    private static func analyze(_ source: URL, filter: String, executable: URL) async throws
        -> (measurement: Measurement, values: [String: String])
    {
        let result = try await execute(
            executable,
            [
                "-i", source.path, "-map", "0:a:0", "-vn",
                "-af", filter + ":print_format=json", "-f", "null", "-",
            ])
        guard let start = result.errorTail.range(of: "{", options: .backwards),
            let end = result.errorTail.range(of: "}", options: .backwards),
            start.lowerBound < end.upperBound,
            let values = try JSONSerialization.jsonObject(
                with:
                    Data(result.errorTail[start.lowerBound..<end.upperBound].utf8))
                as? [String: String]
        else {
            throw Failure("audio_measurement_failed", "FFmpeg returned no loudnorm measurement.")
        }
        func value(_ key: String) throws -> Double? {
            guard let text = values[key] else {
                throw Failure("audio_measurement_failed", "Missing \(key).")
            }
            if text == "-inf" { return nil }
            guard let number = Double(text), number.isFinite else {
                throw Failure("audio_measurement_failed", "Invalid \(key) measurement.")
            }
            return number
        }
        let integrated = try value("input_i")
        let peak = try value("input_tp")
        return (
            Measurement(
                integratedLUFS: integrated, loudnessRangeLU: try value("input_lra") ?? 0,
                truePeakDBTP: peak, thresholdLUFS: try value("input_thresh"), silent: peak == nil),
            values
        )
    }
}
