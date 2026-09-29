@preconcurrency import AVFoundation

enum VideoAudioMix {
    static func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 48000)
    }

    static func level(_ decibels: Double) -> Float {
        Float(pow(10, (decibels.isFinite ? min(12, max(-60, decibels)) : 0) / 20))
    }

    static func muteIntervals(
        project: VideoProject, segment: VideoRenderPipeline.Segment
    ) -> [ClosedRange<Double>] {
        project.muteRanges.compactMap { range -> ClosedRange<Double>? in
            if let clipID = range["clipId"] as? String {
                guard clipID == segment.clip.id else { return nil }
            } else {
                guard range["assetId"] as? String == segment.clip.assetID else { return nil }
            }
            guard let start = (range["startSec"] as? NSNumber)?.doubleValue,
                let end = (range["endSec"] as? NSNumber)?.doubleValue,
                start.isFinite, end.isFinite
            else { return nil }
            let lower = max(start, segment.sourceStart)
            let upper = min(end, segment.sourceEnd)
            guard upper > lower else { return nil }
            let outputLower = segment.outputStart + (lower - segment.sourceStart) / segment.rate
            let outputUpper = segment.outputStart + (upper - segment.sourceStart) / segment.rate
            return outputLower...outputUpper
        }
    }

    static func sourceParameters(
        track: AVCompositionTrack, project: VideoProject,
        segments: [VideoRenderPipeline.Segment], transitions: [(time: Double, half: Double)]
    ) -> AVMutableAudioMixInputParameters {
        let input = AVMutableAudioMixInputParameters(track: track)
        for segment in segments {
            let mutes = muteIntervals(project: project, segment: segment)
            let boundaries = Set(
                [segment.outputStart, segment.outputEnd]
                    + mutes.flatMap { [$0.lowerBound, $0.upperBound] }
                    + transitions.flatMap { [$0.time - $0.half, $0.time, $0.time + $0.half] }
                    .filter { $0 > segment.outputStart && $0 < segment.outputEnd }
            ).sorted()
            let gain = (segment.clip.raw["audioGainDb"] as? NSNumber)?.doubleValue ?? 0
            for (start, end) in zip(boundaries, boundaries.dropFirst()) {
                let middle = (start + end) / 2
                let muted =
                    segment.clip.raw["audioMuted"] as? Bool == true
                    || mutes.contains { $0.contains(middle) }
                let amplitude: Float = muted ? 0 : level(gain)
                func volume(at point: Double) -> Float {
                    let factor = transitions.reduce(1.0) {
                        min($0, min(1, abs(point - $1.time) / $1.half))
                    }
                    return amplitude * Float(factor)
                }
                input.setVolumeRamp(
                    fromStartVolume: volume(at: start), toEndVolume: volume(at: end),
                    timeRange: CMTimeRange(start: time(start), end: time(end)))
            }
        }
        return input
    }

    static func addTracks(
        project: VideoProject, composition: AVMutableComposition, duration: Double
    ) async throws -> [AVMutableAudioMixInputParameters] {
        var parameters: [AVMutableAudioMixInputParameters] = []
        for track in project.audioTracks where !track.muted {
            try Task.checkCancellation()
            guard track.startMs.isFinite, track.endMs.isFinite, track.offsetMs.isFinite,
                track.timebase == "output", track.startMs >= 0, track.offsetMs >= 0
            else { continue }
            let start = track.startMs / 1000
            let end = min(duration, track.endMs / 1000)
            guard end > start else { continue }
            guard let source = project.assets.first(where: { $0.id == track.assetID }) else {
                throw VideoRenderPipeline.RenderError.missingAsset(track.assetID)
            }
            let url =
                (source.raw["edithAudioPath"] as? String).map {
                    URL(fileURLWithPath: $0)
                } ?? source.url
            let asset = AVURLAsset(url: url)
            guard let sourceAudio = try await asset.loadTracks(withMediaType: .audio).first,
                let mixTrack = composition.addMutableTrack(
                    withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            else { continue }
            let available = try await sourceAudio.load(.timeRange)
            let sourceEnd = available.end.seconds
            let sourceStart = available.start.seconds
            let sourceDuration = available.duration.seconds
            guard sourceDuration.isFinite, sourceDuration > 0 else { continue }
            var cursor = start
            var offset = track.offsetMs / 1000
            if track.loop { offset = offset.truncatingRemainder(dividingBy: sourceDuration) }
            offset += sourceStart
            while cursor < end - 0.0001 && offset < sourceEnd {
                try Task.checkCancellation()
                let length = min((end - cursor) * track.rate, sourceEnd - offset)
                let insertion = time(cursor)
                let range = CMTimeRange(start: time(offset), duration: time(length))
                try mixTrack.insertTimeRange(range, of: sourceAudio, at: insertion)
                if track.rate != 1 {
                    mixTrack.scaleTimeRange(
                        CMTimeRange(start: insertion, duration: range.duration),
                        toDuration: time(length / track.rate))
                }
                cursor += length / track.rate
                if !track.loop { break }
                offset = sourceStart
            }
            guard cursor > start else { continue }
            let input = AVMutableAudioMixInputParameters(track: mixTrack)
            let amplitude = level(track.gainDb)
            let fadeIn = min(max(0, track.fadeInMs) / 1000, (cursor - start) / 2)
            let fadeOut = min(max(0, track.fadeOutMs) / 1000, (cursor - start) / 2)
            input.setVolume(fadeIn > 0 ? 0 : amplitude, at: time(start))
            if fadeIn > 0 {
                input.setVolumeRamp(
                    fromStartVolume: 0, toEndVolume: amplitude,
                    timeRange: CMTimeRange(start: time(start), duration: time(fadeIn)))
            }
            if fadeOut > 0 {
                input.setVolumeRamp(
                    fromStartVolume: amplitude, toEndVolume: 0,
                    timeRange: CMTimeRange(start: time(cursor - fadeOut), duration: time(fadeOut)))
            }
            parameters.append(input)
        }
        return parameters
    }
}
