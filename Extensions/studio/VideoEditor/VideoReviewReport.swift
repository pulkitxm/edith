@preconcurrency import AVFoundation
import CryptoKit
import Foundation

extension VideoEditorService {
    public enum ReviewStatus: String, Codable, Sendable {
        case passed, failed, sampled
        case notAssessed = "not_assessed"
    }

    public struct ReviewOptions: Sendable {
        public var expectedDuration: Double?
        public var durationTolerance = 0.001
        public var expectedFrameCount: Int64?
        public var expectedShotCount: Int?
        public var checkBorders = false
        public var maximumBorderFrames = 10000
        public init() {}
    }

    public struct ReviewCheck: Codable, Sendable {
        public let name: String
        public let status: ReviewStatus
        public let expected: Double?
        public let actual: Double?
        public let tolerance: Double
    }

    public struct ReviewRange: Codable, Sendable {
        public let start: Double
        public let endExclusive: Double
    }

    public struct ReviewFrameRange: Codable, Sendable {
        public let start: Int64
        public let endExclusive: Int64
        public let basis: String
    }

    public struct ReviewTime: Codable, Sendable {
        public let value: Int64
        public let timescale: Int32

        init(_ time: CMTime) {
            value = time.value
            timescale = time.timescale
        }
    }

    public struct ReviewMarkerDelta: Codable, Sendable {
        public let markerID: String
        public let kind: String
        public let markerSeconds: Double
        public let markerOutputFrame: Int64
        public let deltaSeconds: Double
        public let deltaFrames: Int64
    }

    public struct ReviewSegment: Codable, Sendable {
        public let clipID: String
        public let assetID: String
        public let sourcePath: String
        public let sourceRange: ReviewRange
        public let sourceFrames: ReviewFrameRange?
        public let sourceFrameStatus: String
        public let outputRange: ReviewRange
        public let outputStart: ReviewTime
        public let outputDuration: ReviewTime
        public let outputFrames: ReviewFrameRange
        public let rate: Double
        public let nearestStartMarker: ReviewMarkerDelta?
        public let nearestEndMarker: ReviewMarkerDelta?
    }

    public struct ReviewClip: Codable, Sendable {
        public let clipID: String
        public let assetID: String
        public let sourceRange: ReviewRange
        public let sourceFrames: ReviewFrameRange?
        public let segmentIndices: [Int]
        public let outputRange: ReviewRange?
        public let outputFrames: ReviewFrameRange?
    }

    public struct ReviewDiagnostic: Codable, Sendable {
        public let code: String
        public let path: String?
        public let message: String
    }

    public struct ReviewReport: Codable, Sendable {
        public let version: Int
        public let projectPath: String
        public let projectID: String
        public let status: ReviewStatus
        public let measurementBasis: String
        public let frameDuration: ReviewTime
        public let width: Int
        public let height: Int
        public let duration: Double?
        public let frameCount: Int64?
        public let shotCount: Int?
        public let clips: [ReviewClip]
        public let segments: [ReviewSegment]
        public let checks: [ReviewCheck]
        public let diagnostics: [ReviewDiagnostic]
        public let borders: ReviewBorders?
    }

    public struct ReviewArtifact: Codable, Sendable {
        public let version: Int
        public let path: String
        public let status: ReviewStatus
        public let sha256: String
    }

    public static func reviewReport(_ url: URL, options: ReviewOptions = .init()) async throws
        -> ReviewReport
    {
        try require(
            options.durationTolerance.isFinite && options.durationTolerance >= 0,
            "Duration tolerance must be finite and nonnegative.")
        try require(
            options.expectedDuration.map { $0.isFinite && $0 >= 0 } ?? true,
            "Expected duration must be finite and nonnegative.")
        try require(
            options.expectedFrameCount.map { $0 >= 0 } ?? true,
            "Expected frame count must be nonnegative.")
        try require(
            options.expectedShotCount.map { $0 >= 0 } ?? true,
            "Expected shot count must be nonnegative.")
        try require(
            (2...100000).contains(options.maximumBorderFrames),
            "Border frame limit must be between 2 and 100000.")
        let project = try open(url)
        var diagnostics: [ReviewDiagnostic] = []
        for dependency in VideoProjectExportDestination.dependencies(project) {
            try Task.checkCancellation()
            if dependency.optional && !FileManager.default.fileExists(atPath: dependency.url.path) {
                continue
            }
            do { try requireLocalFile(dependency.url) } catch {
                diagnostics.append(
                    ReviewDiagnostic(
                        code: "missing_or_unreadable_asset", path: dependency.url.path,
                        message: error.localizedDescription))
            }
        }
        var pipeline: VideoRenderPipeline?
        if diagnostics.isEmpty && !project.clips.isEmpty {
            do {
                try await validateMedia(project)
                pipeline = try await VideoRenderPipeline.make(project: project)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                diagnostics.append(
                    ReviewDiagnostic(
                        code: "composition_unavailable", path: nil,
                        message: error.localizedDescription))
            }
        }
        let available = diagnostics.isEmpty && (pipeline != nil || project.clips.isEmpty)
        let frameDuration = project.frameDuration
        let duration = available ? pipeline?.composition.duration ?? .zero : nil
        let frameCount = duration.map { reviewFrameCeiling($0, frameDuration: frameDuration) }
        let nativeSegments = pipeline?.segments ?? []
        var sourceRates: [String: Double] = [:]
        for asset in project.assets
        where nativeSegments.contains(where: { $0.clip.assetID == asset.id }) {
            guard !asset.isStill else { continue }
            if let track = try? await AVURLAsset(url: asset.url).loadTracks(withMediaType: .video)
                .first,
                let fps = try? await track.load(.nominalFrameRate), fps.isFinite, fps > 0,
                fps <= 1000000
            {
                sourceRates[asset.id] = Double(fps)
            }
        }
        let markers = project.markers
        let segments = nativeSegments.map { segment in
            let asset = project.assets.first { $0.id == segment.clip.assetID }!
            let sourceFrames = sourceRates[asset.id].map { fps in
                ReviewFrameRange(
                    start: Int64(floor(segment.sourceStart * fps)),
                    endExclusive: Int64(ceil(segment.sourceEnd * fps)),
                    basis: "nominal_source_fps_coordinates_not_decoded_sample_indices")
            }
            return ReviewSegment(
                clipID: segment.clip.id, assetID: asset.id, sourcePath: asset.url.path,
                sourceRange: ReviewRange(
                    start: segment.sourceStart, endExclusive: segment.sourceEnd),
                sourceFrames: sourceFrames,
                sourceFrameStatus: asset.isStill
                    ? "not_applicable_still" : sourceFrames == nil ? "not_assessed" : "nominal",
                outputRange: ReviewRange(
                    start: segment.outputStart, endExclusive: segment.outputEnd),
                outputStart: ReviewTime(segment.outputRange.start),
                outputDuration: ReviewTime(segment.outputRange.duration),
                outputFrames: ReviewFrameRange(
                    start: reviewFrameCeiling(
                        segment.outputRange.start, frameDuration: frameDuration),
                    endExclusive: reviewFrameCeiling(
                        segment.outputRange.end, frameDuration: frameDuration),
                    basis: "output_frame_presentation_times_in_half_open_range"),
                rate: segment.rate,
                nearestStartMarker: reviewMarker(
                    at: segment.outputStart, markers: markers, fps: project.videoSettings.frameRate),
                nearestEndMarker: reviewMarker(
                    at: segment.outputEnd, markers: markers, fps: project.videoSettings.frameRate))
        }
        let clips = project.clips.map { clip in
            let indices = segments.indices.filter { segments[$0].clipID == clip.id }
            return ReviewClip(
                clipID: clip.id, assetID: clip.assetID,
                sourceRange: ReviewRange(start: clip.start, endExclusive: clip.end),
                sourceFrames: sourceRates[clip.assetID].map {
                    ReviewFrameRange(
                        start: Int64(floor(clip.start * $0)),
                        endExclusive: Int64(ceil(clip.end * $0)),
                        basis: "nominal_source_fps_coordinates_not_decoded_sample_indices")
                },
                segmentIndices: indices,
                outputRange: indices.first.flatMap { first in
                    indices.last.map {
                        ReviewRange(
                            start: segments[first].outputRange.start,
                            endExclusive: segments[$0].outputRange.endExclusive)
                    }
                },
                outputFrames: indices.first.flatMap { first in
                    indices.last.map {
                        ReviewFrameRange(
                            start: segments[first].outputFrames.start,
                            endExclusive: segments[$0].outputFrames.endExclusive,
                            basis: segments[first].outputFrames.basis)
                    }
                })
        }
        let shotCount = available ? Set(segments.map(\.clipID)).count : nil
        let checks = [
            reviewCheck(
                "duration", expected: options.expectedDuration, actual: duration?.seconds,
                tolerance: options.durationTolerance),
            reviewCheck(
                "frame_count", expected: options.expectedFrameCount.map(Double.init),
                actual: frameCount.map(Double.init)),
            reviewCheck(
                "shot_count", expected: options.expectedShotCount.map(Double.init),
                actual: shotCount.map(Double.init)),
        ]
        let borders =
            options.checkBorders
            ? try await reviewBorders(
                project: project, pipeline: pipeline, limit: options.maximumBorderFrames) : nil
        let status: ReviewStatus =
            !diagnostics.isEmpty || checks.contains { $0.status == .failed }
                || borders?.status == .failed
            ? .failed
            : checks.contains { $0.expected != nil && $0.status == .notAssessed }
                ? .notAssessed : borders?.status ?? .passed
        return ReviewReport(
            version: 1, projectPath: url.path, projectID: project.id, status: status,
            measurementBasis: "native_composition_not_encoded_master",
            frameDuration: ReviewTime(frameDuration), width: project.videoSettings.width,
            height: project.videoSettings.height, duration: duration?.seconds,
            frameCount: frameCount, shotCount: shotCount, clips: clips, segments: segments,
            checks: checks, diagnostics: diagnostics, borders: borders)
    }

    public static func writeReviewReport(
        _ report: ReviewReport, project source: URL, to output: URL, overwrite: Bool = false
    ) throws -> ReviewArtifact {
        let project = try open(source)
        try require(
            project.id == report.projectID
                && VideoProjectFileAccess.identity(source)
                    == VideoProjectFileAccess.identity(URL(fileURLWithPath: report.projectPath)),
            "Report does not belong to this project.")
        try requireOutput(output, extension: "json", project: project, source: source)
        try VideoProjectExportDestination.validate(output, project: project)
        try checkDestination(output, overwrite: overwrite)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(report)
        try require(data.count <= 32 << 20, "Review report exceeds 32 MiB.")
        let temporary = temporaryOutput(output)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try data.write(to: temporary)
        try Task.checkCancellation()
        try publish(temporary, to: output, overwrite: overwrite)
        return ReviewArtifact(
            version: 1, path: output.path, status: report.status,
            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    }

    static func reviewFrameCeiling(_ time: CMTime, frameDuration: CMTime) -> Int64 {
        var frame = Int64(ceil(time.seconds / frameDuration.seconds))
        func at(_ number: Int64) -> CMTime {
            CMTime(value: number * frameDuration.value, timescale: frameDuration.timescale)
        }
        while frame > 0 && at(frame - 1) >= time { frame -= 1 }
        while at(frame) < time { frame += 1 }
        return frame
    }

    private static func reviewCheck(
        _ name: String, expected: Double?, actual: Double?, tolerance: Double = 0
    ) -> ReviewCheck {
        let status: ReviewStatus
        if let expected, let actual {
            status = abs(expected - actual) <= tolerance ? .passed : .failed
        } else {
            status = .notAssessed
        }
        return ReviewCheck(
            name: name, status: status, expected: expected, actual: actual, tolerance: tolerance)
    }

    private static func reviewMarker(at seconds: Double, markers: [VideoMarker], fps: Double)
        -> ReviewMarkerDelta?
    {
        guard !markers.isEmpty else { return nil }
        func lowerBound(_ time: Double) -> Int {
            var low = 0
            var high = markers.count
            while low < high {
                let middle = (low + high) / 2
                if markers[middle].seconds < time { low = middle + 1 } else { high = middle }
            }
            return low
        }
        let next = lowerBound(seconds)
        var index = min(next, markers.count - 1)
        if next > 0
            && (next == markers.count
                || seconds - markers[next - 1].seconds <= markers[next].seconds - seconds)
        {
            index = lowerBound(markers[next - 1].seconds)
        }
        let marker = markers[index]
        let frame = Int64((marker.seconds * fps).rounded())
        return ReviewMarkerDelta(
            markerID: marker.id, kind: marker.kind.rawValue, markerSeconds: marker.seconds,
            markerOutputFrame: frame, deltaSeconds: marker.seconds - seconds,
            deltaFrames: frame - Int64((seconds * fps).rounded()))
    }
}
