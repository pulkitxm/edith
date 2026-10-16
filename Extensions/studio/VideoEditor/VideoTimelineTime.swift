import CoreMedia

enum VideoTimelineTime {
    static func nearest(_ seconds: Double, timescale: CMTimeScale) -> CMTime {
        let ticks = (seconds * Double(timescale)).rounded()
        guard timescale > 0, ticks.isFinite,
            ticks >= Double(Int64.min), ticks < Double(Int64.max)
        else { return .invalid }
        return CMTime(value: Int64(ticks), timescale: timescale)
    }
}
