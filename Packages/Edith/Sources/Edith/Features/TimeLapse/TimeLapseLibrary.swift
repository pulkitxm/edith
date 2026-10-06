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
    case original = "Original video, no re-encoding"
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
    static func composition(_ recording: TimeLapseRecording) async throws
        -> AVMutableComposition
    {
        try recording.session.validate()
        let composition = AVMutableComposition()
        let segments = recording.session.segments.filter { $0.kind == "video" }.sorted {
            $0.file < $1.file
        }
        guard let first = segments.first else { throw TimeLapseError.empty }
        try await append(recording, kind: "video", to: composition, origin: first.startedAt)
        do {
            let duration = composition.duration
            for audio in ["system", "microphone"] {
                if recording.session.segments.contains(where: { $0.kind == audio }) {
                    try await append(
                        recording, kind: audio, to: composition, origin: first.startedAt,
                        limit: duration, speed: recording.session.settings.speed)
                }
            }
        }
        return composition
    }

    private static func append(
        _ recording: TimeLapseRecording, kind: String,
        to composition: AVMutableComposition, origin: Date, limit: CMTime? = nil, speed: Double = 1
    ) async throws {
        let segments = recording.session.segments.filter { $0.kind == kind }.sorted {
            $0.file < $1.file
        }
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
            guard
                url.deletingLastPathComponent().path
                    == recording.directory.resolvingSymlinksInPath().path
            else { throw TimeLapseError.invalidSession }
            let asset = AVURLAsset(url: url)
            guard let track = try await asset.loadTracks(withMediaType: mediaType).first else {
                throw TimeLapseError.encoding(
                    "A saved recording segment is missing its media track.")
            }
            var range = try await track.load(.timeRange)
            guard range.duration.isNumeric, range.duration.seconds > 0 else {
                throw TimeLapseError.empty
            }
            if kind != "video" || recording.session.settings.mode == .standard {
                let start = segment.startedAt.timeIntervalSince(origin)
                if start < 0 {
                    let trim = CMTime(seconds: -start, preferredTimescale: 60000)
                    range.start = CMTimeAdd(range.start, trim)
                    range.duration = CMTimeSubtract(range.duration, trim)
                }
                offset = CMTime(seconds: max(offset.seconds, start), preferredTimescale: 60000)
            }
            if let limit {
                range.duration = CMTimeMinimum(
                    range.duration,
                    CMTimeSubtract(CMTimeMultiplyByFloat64(limit, multiplier: speed), offset))
            }
            guard range.duration.seconds > 0 else { continue }
            try destination.insertTimeRange(range, of: track, at: offset)
            offset = CMTimeAdd(offset, range.duration)
        }
        if destination.segments.isEmpty {
            composition.removeTrack(destination)
        } else if speed != 1 {
            let range = CMTimeRange(start: .zero, duration: destination.timeRange.end)
            destination.scaleTimeRange(
                range,
                toDuration: CMTimeMultiplyByFloat64(
                    range.duration,
                    multiplier: 1 / speed))
        }
    }

    @available(macOS 15.0, *)
    private static func mixAudio(
        in composition: AVMutableComposition, directory: URL, speed: Double
    ) async throws
        -> URL?
    {
        let tracks = try await composition.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty, tracks.count > 1 || speed != 1 else { return nil }
        var audio = AVMutableComposition()
        for track in tracks {
            guard
                let destination = audio.addMutableTrack(
                    withMediaType: .audio,
                    preferredTrackID: kCMPersistentTrackID_Invalid)
            else { throw TimeLapseError.empty }
            let range = try await track.load(.timeRange)
            try destination.insertTimeRange(range, of: track, at: range.start)
            if speed != 1 {
                let timeline = CMTimeRange(start: .zero, duration: destination.timeRange.end)
                destination.scaleTimeRange(
                    timeline,
                    toDuration: CMTimeMultiplyByFloat64(timeline.duration, multiplier: speed))
            }
        }
        var remaining = speed
        var temporary: [URL] = []
        var completed = false
        defer {
            for url in completed ? temporary.dropLast() : temporary[...] {
                try? FileManager.default.removeItem(at: url)
            }
        }
        repeat {
            try Task.checkCancellation()
            let factor = min(4, remaining)
            let audioTracks = try await audio.loadTracks(withMediaType: .audio)
            for track in audioTracks {
                let range = CMTimeRange(start: .zero, duration: track.timeRange.end)
                track.scaleTimeRange(
                    range,
                    toDuration: CMTimeMultiplyByFloat64(range.duration, multiplier: 1 / factor))
            }
            guard
                let exporter = AVAssetExportSession(
                    asset: audio, presetName: AVAssetExportPresetAppleM4A)
            else { throw TimeLapseError.encoding("Audio mixing is unavailable on this Mac.") }
            let mix = AVMutableAudioMix()
            mix.inputParameters = audioTracks.map { track in
                let parameters = AVMutableAudioMixInputParameters(track: track)
                parameters.setVolume(audioTracks.count > 1 ? 0.5 : 1, at: .zero)
                parameters.audioTimePitchAlgorithm = .spectral
                return parameters
            }
            exporter.audioMix = mix
            exporter.audioTimePitchAlgorithm = .spectral
            let url = directory.appendingPathComponent(".\(UUID().uuidString).m4a")
            temporary.append(url)
            try await exporter.export(to: url, as: .m4a)
            let asset = AVURLAsset(url: url)
            guard let mixed = try await asset.loadTracks(withMediaType: .audio).first else {
                throw TimeLapseError.empty
            }
            remaining /= factor
            if remaining > 1 {
                audio = AVMutableComposition()
                guard
                    let next = audio.addMutableTrack(
                        withMediaType: .audio,
                        preferredTrackID: kCMPersistentTrackID_Invalid)
                else { throw TimeLapseError.empty }
                try next.insertTimeRange(try await mixed.load(.timeRange), of: mixed, at: .zero)
            } else {
                for track in tracks { composition.removeTrack(track) }
                guard
                    let destination = composition.addMutableTrack(
                        withMediaType: .audio,
                        preferredTrackID: kCMPersistentTrackID_Invalid)
                else { throw TimeLapseError.empty }
                var range = try await mixed.load(.timeRange)
                range.duration = CMTimeMinimum(range.duration, composition.duration)
                try destination.insertTimeRange(range, of: mixed, at: .zero)
                completed = true
                return url
            }
        } while remaining > 1
        throw TimeLapseError.empty
    }

    @available(macOS 15.0, *)
    static func export(
        _ recording: TimeLapseRecording, quality: TimeLapseExportQuality,
        to destination: URL
    ) async throws {
        let composition = try await composition(recording)
        let mixedAudio = try await mixAudio(
            in: composition,
            directory: destination.deletingLastPathComponent(),
            speed: recording.session.settings.speed)
        defer { if let mixedAudio { try? FileManager.default.removeItem(at: mixedAudio) } }
        let preset = quality.preset
        guard let export = AVAssetExportSession(asset: composition, presetName: preset) else {
            throw TimeLapseError.encoding("This Mac does not support the selected export quality.")
        }
        let fileType = quality.fileType
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
