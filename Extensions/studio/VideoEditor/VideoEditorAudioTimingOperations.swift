import AVFoundation

extension VideoEditorService {
    static func audioBounds(_ tracks: [VideoProject.AudioTrack]) throws -> CMTimeRange {
        let ordered = tracks.sorted { $0.outputRange.start < $1.outputRange.start }
        try require(!ordered.isEmpty, "Select at least one audio track.")
        for (left, right) in zip(ordered, ordered.dropFirst()) {
            try require(
                left.outputRange.end <= right.outputRange.start,
                "Audio group tracks must not overlap.")
        }
        return CMTimeRange(
            start: ordered.first!.outputRange.start, end: ordered.last!.outputRange.end)
    }

    static func audioTime(_ seconds: Double, in range: CMTimeRange) -> CMTime {
        if seconds == range.start.seconds { return range.start }
        if seconds == range.end.seconds { return range.end }
        return CMTime(seconds: seconds, preferredTimescale: max(48000, range.duration.timescale))
    }

    static func slicedAudio(_ track: VideoProject.AudioTrack, to range: CMTimeRange) -> [String:
        Any]
    {
        var raw = track.raw
        let original = track.outputRange
        let lower = (range.start - original.start).seconds
        let upper = (range.end - original.start).seconds
        let fadeLimit = original.duration.seconds * (raw["gainEnvelope"] == nil ? 500 : 1000)
        raw["offsetMs"] = track.offsetMs + lower * 1000 * track.rate
        raw["fadeInMs"] = min(
            range.duration.seconds * 1000, max(0, min(track.fadeInMs, fadeLimit) - lower * 1000))
        raw["fadeOutMs"] = min(
            range.duration.seconds * 1000,
            max(0, min(track.fadeOutMs, fadeLimit) - (original.end - range.end).seconds * 1000))
        raw["gainEnvelope"] = VideoAudioAutomation.track(track).slice(from: lower, to: upper).raw
        VideoAudioTiming.store(range, in: &raw)
        return raw
    }

    static func moveAudio(
        _ tracks: [VideoProject.AudioTrack], start: Double, project: inout VideoProject
    ) throws {
        try require(
            start.isFinite && (0...604800).contains(start),
            "Audio start must be within zero to seven days.")
        let bounds = try audioBounds(tracks)
        let delta = audioTime(start, in: bounds) - bounds.start
        let limit =
            VideoRenderPipeline.timingSegments(project: project).last?.outputRange.end ?? .zero
        try require(
            bounds.end + delta <= limit, "Moved audio must fit inside the rendered timeline.")
        for track in tracks {
            project.editRegion("audioTracks", id: track.id) {
                VideoAudioTiming.store(
                    CMTimeRange(
                        start: track.outputRange.start + delta, duration: track.outputRange.duration
                    ), in: &$0)
            }
        }
    }

    static func trimAudio(
        _ tracks: [VideoProject.AudioTrack], start: Double, end: Double, project: inout VideoProject
    ) throws {
        try require(
            start.isFinite && end.isFinite && start >= 0 && end > start && end <= 604800,
            "Invalid audio trim range.")
        let bounds = try audioBounds(tracks)
        let kept = CMTimeRange(start: audioTime(start, in: bounds), end: audioTime(end, in: bounds))
        try require(
            kept.start >= bounds.start && kept.end <= bounds.end && kept.duration > .zero,
            "Audio trim must retain a positive range inside the selected group.")
        var retained = 0
        for track in tracks {
            let overlap = CMTimeRangeGetIntersection(track.outputRange, otherRange: kept)
            if overlap.duration > .zero {
                project.editRegion("audioTracks", id: track.id) {
                    $0 = slicedAudio(track, to: overlap)
                }
                retained += 1
            } else {
                project.removeAudioTrack(track.id)
            }
        }
        try require(retained > 0, "The trim range contains no audio tracks.")
    }

    static func splitAudio(
        _ tracks: [VideoProject.AudioTrack], at seconds: Double, project: inout VideoProject
    ) throws -> (left: [String], right: [String], created: [String: String]) {
        try require(
            seconds.isFinite && (0...604800).contains(seconds),
            "Audio split time must be within zero to seven days.")
        let bounds = try audioBounds(tracks)
        let time = audioTime(seconds, in: bounds)
        try require(
            time > bounds.start && time < bounds.end,
            "Audio split must be inside the selected group.")
        var left: [String] = []
        var right: [String] = []
        var created: [String: String] = [:]
        for track in tracks {
            let range = track.outputRange
            if range.end <= time {
                left.append(track.id)
            } else if range.start >= time {
                right.append(track.id)
            } else {
                let id = "audio_\(UUID().uuidString.lowercased())"
                var before = slicedAudio(track, to: CMTimeRange(start: range.start, end: time))
                var after = slicedAudio(track, to: CMTimeRange(start: time, end: range.end))
                let lane = track.raw["laneId"] as? String ?? track.id
                before["laneId"] = lane
                after["laneId"] = lane
                after["id"] = id
                project.editRegion("audioTracks", id: track.id) { $0 = before }
                project.root["audioTracks"] = project.audioTracks.map(\.raw) + [after]
                left.append(track.id)
                right.append(id)
                created[track.id] = id
            }
        }
        try require(!left.isEmpty && !right.isEmpty, "Audio split must leave tracks on both sides.")
        return (left, right, created)
    }

    static func setAudioFades(
        _ tracks: [VideoProject.AudioTrack], fadeIn: Double?, fadeOut: Double?,
        project: inout VideoProject
    ) throws {
        try require(fadeIn != nil || fadeOut != nil, "Specify fadeIn or fadeOut.")
        try require(
            [fadeIn, fadeOut].compactMap { $0 }.allSatisfy {
                $0.isFinite && (0...604800).contains($0)
            },
            "Fade durations must be finite output seconds from zero to seven days.")
        let bounds = try audioBounds(tracks)
        let duration = bounds.duration.seconds
        let ids = Set(tracks.map(\.id))
        for (fromStart, requested) in [(true, fadeIn), (false, fadeOut)] {
            guard let requested else { continue }
            let current = project.audioTracks.filter { ids.contains($0.id) }.sorted {
                $0.startMs < $1.startMs
            }
            let length = min(requested, duration / 2)
            let previous =
                current.compactMap { track -> Double? in
                    let extent = (fromStart ? track.fadeInMs : track.fadeOutMs) / 1000
                    guard extent > 0 else { return nil }
                    return extent
                        + (fromStart
                        ? track.outputRange.start - bounds.start
                        : bounds.end - track.outputRange.end).seconds
                }.max() ?? 0
            let affected = min(duration, max(length, previous))
            guard affected > 0 else { continue }
            let boundary = fromStart ? affected : duration - affected
            let join = fromStart ? length : duration - length
            let boundaryTrack =
                current.first {
                    let start = ($0.outputRange.start - bounds.start).seconds
                    let end = ($0.outputRange.end - bounds.start).seconds
                    return fromStart
                        ? start <= boundary && boundary < end : start < boundary && boundary <= end
                } ?? (fromStart ? current.last! : current.first!)
            let level = VideoAudioAutomation.track(boundaryTrack).value(
                at: boundary - (boundaryTrack.outputRange.start - bounds.start).seconds)
            for track in current {
                let start = (track.outputRange.start - bounds.start).seconds
                let end = (track.outputRange.end - bounds.start).seconds
                let original = VideoAudioAutomation.track(track)
                let times = Set(
                    original.points.map { $0.time + start } + [start, end, boundary, join]
                )
                .filter { $0 >= start && $0 <= end }.sorted()
                let envelope = VideoAudioAutomation(
                    points: times.map { time in
                        let inside = fromStart ? time <= boundary : time >= boundary
                        let distance = fromStart ? time : duration - time
                        return .init(
                            time: time - start,
                            level: inside
                                ? level * (length > 0 ? min(1, distance / length) : 1)
                                : original.value(at: time - start))
                    })
                project.editRegion("audioTracks", id: track.id) {
                    $0["gainEnvelope"] = envelope.raw
                    let extent = fromStart ? length - start : end - (duration - length)
                    $0[fromStart ? "fadeInMs" : "fadeOutMs"] =
                        max(0, min(end - start, extent)) * 1000
                }
            }
        }
    }
}
