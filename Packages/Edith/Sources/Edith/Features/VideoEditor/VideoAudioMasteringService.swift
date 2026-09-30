import CoreMedia
import EdithStudio
import Foundation

extension VideoEditorService {
    static func validateMasteredAudio(_ asset: VideoProject.Asset) throws {
        guard let provenance = asset.raw["edithAudioMastering"] else { return }
        do {
            let report = try JSONDecoder().decode(
                StudioAudioMastering.Report.self,
                from: JSONSerialization.data(withJSONObject: provenance))
            guard report.version == 1, report.verified,
                report.originalPath == asset.url.path,
                try StudioAudioMastering.sha256(asset.url) == report.originalSHA256,
                try StudioAudioMastering.sha256(asset.audioURL) == report.artifactSHA256
            else {
                throw Failure(
                    "invalid_audio_provenance",
                    "Mastered source or artifact changed. Master the original source again into a new bundle."
                )
            }
        } catch let error as Failure {
            throw error
        } catch {
            throw Failure(
                "invalid_audio_provenance",
                "Cannot validate mastered asset: \(error.localizedDescription)")
        }
    }

    public struct AudioMeasurementReport: Codable, Sendable {
        public let version: Int
        public let assetID: String
        public let sourcePath: String
        public let sourceSHA256: String
        public let measurement: StudioAudioMastering.Measurement
    }

    public struct AudioMasteringResult: Codable, Sendable {
        public let version: Int
        public let path: String
        public let projectPath: String
        public let audioPath: String
        public let assetID: String
        public let trackID: String
        public let report: StudioAudioMastering.Report
    }

    public static func measureAudio(_ url: URL, assetID: String) async throws
        -> AudioMeasurementReport
    {
        let project = try open(url)
        let id = project.audioTracks.first(where: { $0.id == assetID })?.assetID ?? assetID
        guard let asset = project.assets.first(where: { $0.id == id }), !asset.isStill else {
            throw Failure(
                "invalid_asset", "Choose an audio/video asset or independent audio-track ID.")
        }
        do {
            let hash = try StudioAudioMastering.sha256(asset.audioURL)
            let measurement = try await StudioAudioMastering.measure(asset.audioURL)
            try require(
                try StudioAudioMastering.sha256(asset.audioURL) == hash,
                "Source changed during measurement.")
            return AudioMeasurementReport(
                version: 1, assetID: id, sourcePath: asset.audioURL.path,
                sourceSHA256: hash, measurement: measurement)
        } catch let error as StudioAudioMastering.Failure {
            throw Failure(error.code, error.message)
        }
    }

    public static func masterAudio(
        _ url: URL, trackID: String, to destination: URL,
        request: StudioAudioMastering.Request
    ) async throws -> AudioMasteringResult {
        var project = try open(url)
        guard let track = project.audioTracks.first(where: { $0.id == trackID }),
            let asset = project.assets.first(where: { $0.id == track.assetID })
        else {
            throw Failure(
                "invalid_audio_track", "Choose an independent soundtrack track ID from show.")
        }
        try require(destination.isFileURL, "Choose a local mastering bundle directory.")
        try checkDestination(destination, overwrite: false)
        try VideoProjectExportDestination.validate(destination, project: project)
        let timelineEnd = VideoRenderPipeline.timingSegments(project: project).last?.outputEnd ?? 0
        try require(
            request.durationSeconds <= timelineEnd,
            "Mastered soundtrack must fit the output timeline.")
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(
            ".\(UUID().uuidString).mastering")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let audioPath = destination.appendingPathComponent("soundtrack.wav")
        let projectPath = destination.appendingPathComponent("project.openscreen")
        let report: StudioAudioMastering.Report
        do {
            report = try await StudioAudioMastering.master(
                asset.url,
                to: temporary.appendingPathComponent("soundtrack.wav"), request: request)
        } catch let error as StudioAudioMastering.Failure {
            throw Failure(error.code, error.message)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let reportData = try encoder.encode(report)
        let id = "asset_\(UUID().uuidString.lowercased())"
        project.root["assets"] =
            project.assets.map(\.raw) + [
                [
                    "id": id, "kind": "audio", "label": "Mastered soundtrack",
                    "originalPath": asset.url.path, "edithAudioPath": audioPath.path,
                    "durationSec": request.durationSeconds,
                    "audio": ["codec": "pcm_s24le", "sampleRate": 48000, "channels": 2],
                    "edithAudioMastering": try JSONSerialization.jsonObject(with: reportData),
                ]
            ]
        project.editRegion("audioTracks", id: trackID) {
            $0["assetId"] = id
            $0["offsetMs"] = 0
            $0["rate"] = 1
            $0["timebase"] = "output"
            $0["gainDb"] = 0
            $0["muted"] = false
            $0["loop"] = false
            $0["fadeInMs"] = 0
            $0["fadeOutMs"] = 0
            $0.removeValue(forKey: "gainEnvelope")
            VideoAudioTiming.store(
                CMTimeRange(
                    start: .zero,
                    duration: CMTime(value: report.recipe.sampleFrames, timescale: 48000)), in: &$0)
        }
        var metadata = project.root["project"] as? [String: Any] ?? [:]
        metadata["id"] = UUID().uuidString.lowercased()
        project.root["project"] = metadata
        try validateStructure(project)
        try encodedProject(project).write(
            to: temporary.appendingPathComponent("project.openscreen"))
        try reportData.write(to: temporary.appendingPathComponent("report.json"))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o444],
            ofItemAtPath: temporary.appendingPathComponent("report.json").path)
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: temporary, to: destination)
        return AudioMasteringResult(
            version: 1, path: destination.path, projectPath: projectPath.path,
            audioPath: audioPath.path, assetID: id, trackID: trackID, report: report)
    }
}
