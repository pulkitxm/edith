import AVFoundation

struct VideoAudioAutomation {
    struct Point {
        let time: Double
        let level: Double
    }

    let points: [Point]

    var raw: [[String: Double]] {
        points.map { ["timeSec": $0.time, "level": $0.level] }
    }

    func value(at time: Double) -> Double {
        guard let first = points.first else { return 1 }
        guard time > first.time else { return first.level }
        for (left, right) in zip(points, points.dropFirst()) where time <= right.time {
            let fraction = (time - left.time) / (right.time - left.time)
            return left.level + (right.level - left.level) * fraction
        }
        return points.last?.level ?? 1
    }

    func slice(from start: Double, to end: Double) -> VideoAudioAutomation {
        let times = [start] + points.map(\.time).filter { $0 > start && $0 < end } + [end]
        return VideoAudioAutomation(
            points: times.map { Point(time: $0 - start, level: value(at: $0)) })
    }

    func apply(to input: AVMutableAudioMixInputParameters, at start: Double, gain: Float) {
        input.audioTimePitchAlgorithm = .spectral
        input.setVolume(gain * Float(value(at: 0)), at: .zero)
        for (left, right) in zip(points, points.dropFirst()) where right.time > left.time {
            guard left.level != right.level else { continue }
            input.setVolumeRamp(
                fromStartVolume: gain * Float(left.level), toEndVolume: gain * Float(right.level),
                timeRange: CMTimeRange(
                    start: VideoAudioMix.time(start + left.time),
                    end: VideoAudioMix.time(start + right.time)))
        }
    }

    static func track(_ track: VideoProject.AudioTrack) -> VideoAudioAutomation {
        if let stored = track.raw["gainEnvelope"] as? [[String: Double]], !stored.isEmpty {
            let points = stored.compactMap { item -> Point? in
                guard let time = item["timeSec"], let level = item["level"],
                    time.isFinite, level.isFinite, time >= 0
                else { return nil }
                return Point(time: time, level: max(0, min(1, level)))
            }.sorted { $0.time < $1.time }
            if !points.isEmpty { return VideoAudioAutomation(points: points) }
        }
        let duration = max(0, (track.endMs - track.startMs) / 1000)
        let fadeIn = min(max(0, track.fadeInMs) / 1000, duration / 2)
        let fadeOut = min(max(0, track.fadeOutMs) / 1000, duration / 2)
        let times = Set([0, fadeIn, duration - fadeOut, duration]).sorted()
        return VideoAudioAutomation(
            points: times.map {
                let head = fadeIn > 0 ? min(1, $0 / fadeIn) : 1
                let tail = fadeOut > 0 ? min(1, (duration - $0) / fadeOut) : 1
                return Point(time: $0, level: min(head, tail))
            })
    }

    static func source(
        start: Double, end: Double, transitions: [(time: Double, half: Double)]
    ) -> VideoAudioAutomation {
        let boundaries = Set(
            [start, end]
                + transitions.flatMap { [$0.time - $0.half, $0.time, $0.time + $0.half] }
                .filter { $0 > start && $0 < end }
        ).sorted()
        return VideoAudioAutomation(
            points: boundaries.map { point in
                let level = transitions.reduce(1.0) {
                    min($0, min(1, abs(point - $1.time) / $1.half))
                }
                return Point(time: point - start, level: level)
            })
    }
}
