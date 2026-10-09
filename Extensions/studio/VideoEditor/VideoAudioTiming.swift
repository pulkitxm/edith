import AVFoundation

enum VideoAudioTiming {
    static func store(_ range: CMTimeRange, in raw: inout [String: Any]) {
        raw["outputRange"] = [
            "startValue": range.start.value, "startScale": Int64(range.start.timescale),
            "durationValue": range.duration.value, "durationScale": Int64(range.duration.timescale),
        ]
        raw["startMs"] = range.start.seconds * 1000
        raw["endMs"] = range.end.seconds * 1000
    }
}

extension VideoProject.AudioTrack {
    var outputRange: CMTimeRange {
        if let range = raw["outputRange"] as? [String: NSNumber],
            let start = range["startValue"]?.int64Value,
            let startScale = range["startScale"]?.int32Value,
            let duration = range["durationValue"]?.int64Value,
            let durationScale = range["durationScale"]?.int32Value,
            start >= 0, duration > 0, startScale > 0, durationScale > 0
        {
            return CMTimeRange(
                start: CMTime(value: start, timescale: startScale),
                duration: CMTime(value: duration, timescale: durationScale))
        }
        return CMTimeRange(
            start: VideoAudioMix.time(startMs / 1000), end: VideoAudioMix.time(endMs / 1000))
    }
}
