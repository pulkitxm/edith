import AVFoundation
import Foundation

extension VideoEditorService {
    public enum MarkerRate: Sendable {
        case explicit(VideoMarkerFrameRate)
        case project
    }

    public enum MarkerChange: Sendable {
        case add(frame: Int64, rate: MarkerRate, label: String)
        case update(id: String, frame: Int64?, rate: MarkerRate?, label: String?)
        case remove(id: String)
        case importDocument(Data, replace: Bool)
    }

    public struct MarkerReport: Codable, Sendable {
        public let version: Int
        public let path: String
        public let written: Bool
        public let positionUnit: String
        public let markers: [MarkerEntry]
    }

    public struct MarkerEntry: Codable, Sendable {
        public let id: String
        public let frame: Int64
        public let frameRate: VideoMarkerFrameRate
        public let label: String
        public let kind: VideoMarker.Kind
        public let outputSeconds: Double
        public let nonDropFrameTimecode: String

        init(_ marker: VideoMarker) {
            id = marker.id
            frame = marker.frame
            frameRate = marker.frameRate
            label = marker.label
            kind = marker.kind
            outputSeconds = marker.seconds
            nonDropFrameTimecode = marker.frameRate.timecode(at: marker.frame)
        }
    }

    public struct MarkerSnapReport: Codable, Sendable {
        public let version: Int
        public let requestedOutputFrame: Int64
        public let outputFrame: Int64
        public let thresholdFrames: Int64
        public let frameRate: VideoMarkerFrameRate
        public let outputSeconds: Double
        public let nonDropFrameTimecode: String
        public let matched: Bool
    }

    public struct MarkerExportReport: Codable, Sendable {
        public let version: Int
        public let path: String
        public let written: Bool
        public let markerCount: Int
    }

    public static func listMarkers(_ url: URL) throws -> MarkerReport {
        let project = try open(url)
        try validateMarkerStorage(project)
        return markerReport(project, url: url, written: false)
    }

    public static func changeMarkers(
        _ change: MarkerChange, in url: URL, dryRun: Bool = false
    ) async throws -> MarkerReport {
        let lock = dryRun ? nil : try await VideoProjectFileAccess.transaction(url)
        defer { withExtendedLifetime(lock) {} }
        let snapshot = try readProject(url)
        var project = snapshot.project
        try validateMarkerStorage(project)
        do {
            switch change {
            case .add(let frame, let rate, let label):
                let fps = try await markerFrameRate(rate, project: project)
                try project.addMarker(atFrame: frame, frameRate: fps, label: label)
            case .update(let id, let frame, let rate, let label):
                try require(frame != nil || rate != nil || label != nil, "Specify an update.")
                try require(
                    frame == nil || rate != nil, "Output frame updates require an FPS choice.")
                let fps: VideoMarkerFrameRate?
                if let rate {
                    fps = try await markerFrameRate(rate, project: project)
                } else {
                    fps = nil
                }
                try project.updateMarker(id, frame: frame, frameRate: fps, label: label)
            case .remove(let id): try project.removeMarker(id)
            case .importDocument(let data, let replace):
                try project.importMarkers(data, replace: replace)
            }
        } catch let failure as Failure { throw failure } catch {
            throw Failure("invalid_markers", error.localizedDescription)
        }
        try validateStructure(project)
        try validateMarkerStorage(project)
        try protectSources(project, destination: url)
        let data = try encodedProject(project)
        try await validateMedia(project)
        let report = markerReport(project, url: url, written: !dryRun)
        try require(
            JSONEncoder().encode(report).count <= 4 << 20,
            "Marker result exceeds the 4 MiB command limit.")
        try Task.checkCancellation()
        if !dryRun {
            try saveEncoded(data, to: url, overwrite: true, expectedSource: snapshot.revision)
        }
        return report
    }

    public static func exportMarkers(
        _ url: URL, to output: URL, overwrite: Bool = false
    ) throws -> MarkerExportReport {
        let project = try open(url)
        try validateMarkerStorage(project)
        try requireOutput(output, extension: "json", project: project, source: url)
        do { try VideoProjectExportDestination.validate(output, project: project) } catch {
            throw Failure("invalid_destination", error.localizedDescription)
        }
        try checkDestination(output, overwrite: overwrite)
        let data = try project.exportMarkers()
        let temporary = temporaryOutput(output)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try data.write(to: temporary, options: .atomic)
        try Task.checkCancellation()
        try publish(temporary, to: output, overwrite: overwrite)
        return MarkerExportReport(
            version: 1, path: output.path, written: true, markerCount: project.markers.count)
    }

    public static func snapMarker(
        _ url: URL, frame: Int64, thresholdFrames: Int64, rate: MarkerRate
    ) async throws -> MarkerSnapReport {
        let project = try open(url)
        try validateMarkerStorage(project)
        try require(frame >= 0 && frame <= VideoMarker.maximumFrame, "Invalid output frame.")
        try require(thresholdFrames >= 0, "Threshold is a nonnegative number of output frames.")
        let fps = try await markerFrameRate(rate, project: project)
        let matched = VideoMarkers.nearestFrame(
            to: frame, markers: project.markers, thresholdFrames: thresholdFrames, frameRate: fps)
        let output = matched ?? frame
        return MarkerSnapReport(
            version: 1, requestedOutputFrame: frame, outputFrame: output,
            thresholdFrames: thresholdFrames,
            frameRate: fps, outputSeconds: fps.seconds(at: output),
            nonDropFrameTimecode: fps.timecode(at: output), matched: matched != nil)
    }

    static func markerFrameRate(_ selection: MarkerRate, project: VideoProject) async throws
        -> VideoMarkerFrameRate
    {
        if case .explicit(let rate) = selection { return rate }
        if let value = project.root["edithVideoSettings"] {
            do {
                let settings = try JSONDecoder().decode(
                    StoredMarkerFPS.self,
                    from: JSONSerialization.data(
                        withJSONObject: value, options: [.fragmentsAllowed]))
                return try VideoMarkerFrameRate(
                    numerator: settings.frameRateNumerator,
                    denominator: settings.frameRateDenominator)
            } catch { throw Failure("invalid_frame_rate", error.localizedDescription) }
        }
        guard !project.clips.isEmpty else {
            throw Failure(
                "invalid_frame_rate",
                "An empty project requires explicit FPS or saved video settings.")
        }
        let duration = try await VideoRenderPipeline.make(project: project).videoComposition
            .frameDuration
        guard duration.isNumeric, duration.value > 0, duration.timescale > 0 else {
            throw Failure(
                "invalid_frame_rate", "The native composition has no valid frame duration.")
        }
        return try VideoMarkerFrameRate(
            numerator: Int(duration.timescale), denominator: Int(duration.value))
    }

    private struct StoredMarkerFPS: Decodable {
        let frameRateNumerator: Int
        let frameRateDenominator: Int
    }

    static func validateMarkerStorage(_ project: VideoProject) throws {
        guard let value = project.root["edithMarkers"] else { return }
        do {
            let data = try JSONSerialization.data(
                withJSONObject: value, options: [.fragmentsAllowed])
            let markers = try JSONDecoder().decode([VideoMarker].self, from: data)
            try VideoMarkers.validate(markers)
        } catch { throw Failure("invalid_markers", error.localizedDescription) }
    }

    static func markerReport(_ project: VideoProject, url: URL, written: Bool) -> MarkerReport {
        MarkerReport(
            version: 1, path: url.path, written: written, positionUnit: "output_frames",
            markers: project.markers.map(MarkerEntry.init))
    }
}
