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

    static func addTracks(
        project: VideoProject, composition: AVMutableComposition, duration: Double,
        rateSources: inout [VideoAudioRateSource]
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
            let asset = AVURLAsset(url: source.audioURL)
            guard let sourceAudio = try await asset.loadTracks(withMediaType: .audio).first,
                let mixTrack = composition.addMutableTrack(
                    withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            else { continue }
            let available = try await sourceAudio.load(.timeRange)
            let sourceEnd = available.end.seconds
            let sourceDuration = available.duration.seconds
            guard sourceDuration.isFinite, sourceDuration > 0, sourceEnd > 0 else {
                composition.removeTrack(mixTrack)
                continue
            }
            let rendered: VideoAudioRateSource?
            if track.rate != 1 {
                rendered = try await VideoAudioRateCache.shared.source(
                    url: source.audioURL, track: sourceAudio, range: available, rate: track.rate)
                if let rendered { rateSources.append(rendered) }
            } else {
                rendered = nil
            }
            var cursor = time(start)
            let limit = time(end)
            let offsetSeconds =
                track.loop
                ? (track.offsetMs / 1000).truncatingRemainder(dividingBy: sourceEnd)
                : track.offsetMs / 1000
            var offset = CMTime(
                seconds: offsetSeconds, preferredTimescale: max(48000, available.end.timescale))
            var insertedAudio = false
            while cursor < limit && offset < available.end {
                try Task.checkCancellation()
                if offset < available.start {
                    cursor =
                        cursor
                        + CMTimeMultiplyByFloat64(
                            available.start - offset, multiplier: 1 / track.rate)
                    offset = available.start
                }
                guard cursor < limit else { break }
                let outputLength = min(
                    limit - cursor,
                    CMTimeMultiplyByFloat64(available.end - offset, multiplier: 1 / track.rate))
                let length = min(
                    available.end - offset,
                    CMTimeMultiplyByFloat64(outputLength, multiplier: track.rate))
                guard outputLength > .zero, length > .zero else { break }
                let range: CMTimeRange
                if rendered != nil {
                    range = CMTimeRange(
                        start: time((offset - available.start).seconds / track.rate),
                        duration: outputLength)
                } else {
                    range = CMTimeRange(start: offset, duration: length)
                }
                try mixTrack.insertTimeRange(range, of: rendered?.track ?? sourceAudio, at: cursor)
                insertedAudio = true
                cursor = cursor + outputLength
                if !track.loop { break }
                offset = .zero
            }
            guard insertedAudio else {
                composition.removeTrack(mixTrack)
                continue
            }
            let audibleEnd = min(cursor.seconds, end)
            let input = AVMutableAudioMixInputParameters(track: mixTrack)
            VideoAudioAutomation.track(track).slice(from: 0, to: audibleEnd - start)
                .apply(to: input, at: start, gain: level(track.gainDb))
            parameters.append(input)
        }
        return parameters
    }
}
