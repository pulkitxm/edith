@preconcurrency import AVFoundation

extension VideoProject.Clip {
    var frameSampling: VideoFrameSampling {
        get throws {
            guard let value = raw["edithFrameSampling"] else { return .hold }
            guard let name = value as? String, let mode = VideoFrameSampling(rawValue: name) else {
                throw VideoEditorService.Failure(
                    "invalid_frame_sampling", "Frame sampling must be hold or nearest.")
            }
            return mode
        }
    }
}

extension VideoProject {
    mutating func setFrameSampling(_ mode: VideoFrameSampling, clipID: String) throws {
        var entries = clips
        guard let index = entries.firstIndex(where: { $0.id == clipID }) else {
            throw VideoEditorService.Failure("not_found", "Unknown clip: \(clipID)")
        }
        guard
            mode == .hold
                || assets.first(where: { $0.id == entries[index].assetID })?.isStill == false
        else {
            throw VideoEditorService.Failure(
                "invalid_frame_sampling", "Nearest frame sampling requires a video clip.")
        }
        entries[index].raw["edithFrameSampling"] = mode.rawValue
        setClips(entries)
    }

    func validateFrameSampling() async throws {
        let nearest = try clips.filter { try $0.frameSampling == .nearest }
        guard !nearest.isEmpty else { return }
        let segments = VideoRenderPipeline.timingSegments(project: self)
        for clip in nearest {
            try Task.checkCancellation()
            guard let source = assets.first(where: { $0.id == clip.assetID }), !source.isStill
            else {
                throw VideoEditorService.Failure(
                    "invalid_frame_sampling", "Nearest frame sampling requires a video clip.")
            }
            let asset = AVURLAsset(url: source.url)
            guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                throw VideoEditorService.Failure(
                    "unsupported_media", "Clip media has no video track.")
            }
            for segment in segments where segment.clip.id == clip.id {
                _ = try await VideoFrameSampling.nearest.visualRange(
                    track: track, source: segment.sourceRange, output: segment.outputRange,
                    frameDuration: frameDuration)
            }
        }
    }
}
