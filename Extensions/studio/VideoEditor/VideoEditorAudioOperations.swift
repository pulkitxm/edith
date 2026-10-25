@preconcurrency import AVFoundation

extension VideoEditorService {
    static func audioSelection(
        _ reference: String, project: VideoProject, aliases: [String: [String]]
    ) throws -> [VideoProject.AudioTrack] {
        let ids = aliases[reference] ?? [reference]
        try require(!ids.isEmpty, "Audio group is empty: \(reference)")
        return try ids.map { id in
            guard let track = project.audioTracks.first(where: { $0.id == id }) else {
                throw Failure("not_found", "Unknown audio track: \(reference)")
            }
            return track
        }.sorted { $0.startMs < $1.startMs }
    }

    static func requireAudioName(
        _ name: String, project: VideoProject, aliases: [String: String],
        audioAliases: [String: [String]]
    ) throws {
        try require(
            !name.isEmpty && name.count <= 100 && aliases[name] == nil && audioAliases[name] == nil
                && !project.clips.contains { $0.id == name }
                && !project.audioTracks.contains { $0.id == name },
            "Audio alias must be unique and contain 1 to 100 characters.")
    }

    static func applyAudio(
        _ operation: VideoEditPlan.Operation, project: inout VideoProject,
        aliases: [String: String], audioAliases: inout [String: [String]], directory: URL
    ) async throws {
        switch operation {
        case let .addAudio(path, start, offset, name):
            try requireAudioName(
                name, project: project, aliases: aliases, audioAliases: audioAliases)
            let end = VideoRenderPipeline.timingSegments(project: project).last?.outputEnd ?? 0
            try require(
                start.isFinite && start >= 0 && start < end,
                "Audio start must be inside the rendered output timeline.")
            let url = try mediaURL(path, directory: directory)
            let asset = AVURLAsset(url: url)
            guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
                throw Failure("unsupported_media", "Expected media with an audio track.")
            }
            let duration = try await track.load(.timeRange).end.seconds
            try require(
                duration.isFinite && duration > 0 && duration <= 604800 && offset.isFinite
                    && offset >= 0 && offset < duration, "Invalid audio duration or source offset.")
            let previous = Set(project.audioTracks.map(\.id))
            project.addAudio(
                url, duration: duration, at: start * 1000, sourceOffsetMs: offset * 1000)
            let ids = project.audioTracks.map(\.id).filter { !previous.contains($0) }
            try require(ids.count == 1, "Audio must have a positive rendered duration.")
            audioAliases[name] = ids
        case let .audioOptions(reference, gainDb, muted, loop):
            let tracks = try audioSelection(reference, project: project, aliases: audioAliases)
            try require(
                gainDb.isFinite && (-60...12).contains(gainDb),
                "Gain must be between -60 and 12 dB.")
            for track in tracks {
                project.setAudioGain(track.id, decibels: gainDb)
                project.setAudioOptions(track.id, muted: muted, loop: loop)
            }
        case let .removeAudio(reference):
            let tracks = try audioSelection(reference, project: project, aliases: audioAliases)
            for track in tracks { project.removeAudioTrack(track.id) }
            let remaining = Set(project.audioTracks.map(\.id))
            audioAliases = audioAliases.mapValues { $0.filter { remaining.contains($0) } }
        case let .detachAudio(reference, name):
            try requireAudioName(
                name, project: project, aliases: aliases, audioAliases: audioAliases)
            let id = aliases[reference] ?? reference
            guard let clip = project.clips.first(where: { $0.id == id }),
                let source = project.assets.first(where: { $0.id == clip.assetID })
            else { throw Failure("not_found", "Unknown clip: \(reference)") }
            try require(
                !source.isStill || source.raw["edithAudioPath"] is String,
                "This source has no audio track.")
            let asset = AVURLAsset(url: source.audioURL)
            try require(
                try await !asset.loadTracks(withMediaType: .audio).isEmpty,
                "This source has no audio track.")
            let ids = project.detachAudio(clipID: id)
            try require(
                !ids.isEmpty,
                "Audio has already been detached or the clip has no rendered duration.")
            audioAliases[name] = ids
        case let .moveAudio(reference, start):
            let tracks = try audioSelection(reference, project: project, aliases: audioAliases)
            try moveAudio(tracks, start: start, project: &project)
        case let .trimAudio(reference, start, end):
            let tracks = try audioSelection(reference, project: project, aliases: audioAliases)
            try trimAudio(tracks, start: start, end: end, project: &project)
            let remaining = Set(project.audioTracks.map(\.id))
            audioAliases = audioAliases.mapValues { $0.filter { remaining.contains($0) } }
        case let .splitAudio(reference, time, rightName):
            try requireAudioName(
                rightName, project: project, aliases: aliases, audioAliases: audioAliases)
            let tracks = try audioSelection(reference, project: project, aliases: audioAliases)
            let split = try splitAudio(tracks, at: time, project: &project)
            audioAliases = audioAliases.mapValues { ids in
                ids.flatMap { id in split.created[id].map { [id, $0] } ?? [id] }
            }
            if audioAliases[reference] != nil { audioAliases[reference] = split.left }
            audioAliases[rightName] = split.right
        case let .audioFades(reference, fadeIn, fadeOut):
            let tracks = try audioSelection(reference, project: project, aliases: audioAliases)
            try setAudioFades(tracks, fadeIn: fadeIn, fadeOut: fadeOut, project: &project)
        default:
            throw Failure("invalid_operation", "Expected an audio operation.")
        }
    }
}
