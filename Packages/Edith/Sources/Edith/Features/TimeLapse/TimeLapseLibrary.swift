import AVFoundation
import EdithCore
import Foundation

struct TimeLapseRecording: Identifiable, Sendable {
    let session: TimeLapseSession
    let directory: URL
    var id: UUID { session.id }

    static func load(in root: URL) throws -> [Self] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        let directories = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        return directories.compactMap { directory in
            guard
                let data = try? Data(contentsOf: directory.appendingPathComponent("session.json")),
                let session = try? JSONDecoder().decode(TimeLapseSession.self, from: data),
                (try? session.validate()) != nil
            else { return nil }
            return Self(session: session, directory: directory)
        }.sorted { $0.session.startedAt > $1.session.startedAt }
    }
}

enum TimeLapseExportQuality: String, CaseIterable, Identifiable, Sendable {
    case compact = "Compact HEVC, up to 1080p"
    case high = "High quality HEVC, recorded resolution"
    case original = "Original capture, no re-encoding"
    case editing = "ProRes 422, for editing"
    var id: String { rawValue }
    var preset: String {
        switch self {
        case .compact: AVAssetExportPresetHEVC1920x1080
        case .high: AVAssetExportPresetHEVCHighestQuality
        case .original: AVAssetExportPresetPassthrough
        case .editing: AVAssetExportPresetAppleProRes422LPCM
        }
    }
    var fileType: AVFileType { self == .editing ? .mov : .mp4 }
    var fileExtension: String { self == .editing ? "mov" : "mp4" }
}

enum TimeLapseExporter {
    static func composition(_ recording: TimeLapseRecording, kind: String = "video") async throws
        -> AVMutableComposition
    {
        try recording.session.validate()
        let segments = recording.session.segments.filter { $0.kind == kind }.sorted {
            $0.file < $1.file
        }
        guard !segments.isEmpty else { throw TimeLapseError.empty }
        let composition = AVMutableComposition()
        let mediaType: AVMediaType = kind == "video" ? .video : .audio
        guard
            let destination = composition.addMutableTrack(
                withMediaType: mediaType,
                preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw TimeLapseError.empty }
        var offset = CMTime.zero
        for segment in segments {
            try Task.checkCancellation()
            let url = recording.directory.appendingPathComponent(segment.file)
                .resolvingSymlinksInPath()
            guard url.deletingLastPathComponent() == recording.directory.resolvingSymlinksInPath()
            else {
                throw TimeLapseError.invalidSession
            }
            let asset = AVURLAsset(url: url)
            guard let track = try await asset.loadTracks(withMediaType: mediaType).first else {
                throw TimeLapseError.encoding(
                    "A saved recording segment is missing its media track.")
            }
            let range = try await track.load(.timeRange)
            guard range.duration.isNumeric, range.duration.seconds > 0 else {
                throw TimeLapseError.empty
            }
            if kind != "video" {
                offset = CMTime(
                    seconds: max(
                        offset.seconds, segment.startedAt.timeIntervalSince(segments[0].startedAt)),
                    preferredTimescale: 48000)
            }
            try destination.insertTimeRange(range, of: track, at: offset)
            offset = CMTimeAdd(offset, range.duration)
        }
        return composition
    }

    @available(macOS 15.0, *)
    static func export(
        _ recording: TimeLapseRecording, quality: TimeLapseExportQuality,
        to destination: URL, kind: String = "video"
    ) async throws {
        let composition = try await composition(recording, kind: kind)
        let preset = kind == "video" ? quality.preset : AVAssetExportPresetAppleM4A
        guard let export = AVAssetExportSession(asset: composition, presetName: preset) else {
            throw TimeLapseError.encoding("This Mac does not support the selected export quality.")
        }
        let fileType: AVFileType = kind == "video" ? quality.fileType : .m4a
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(
            ".\(UUID().uuidString).partial")
        defer { try? FileManager.default.removeItem(at: temporary) }
        export.shouldOptimizeForNetworkUse = true
        try await export.export(to: temporary, as: fileType)
        try Task.checkCancellation()
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: destination)
        }
    }
}
