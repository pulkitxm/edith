import CoreMedia

public struct VideoDeliveryFrameRange: Codable, Equatable, Sendable {
    public let startFrame: Int64
    public let endFrame: Int64

    public init(startFrame: Int64, endFrame: Int64) {
        self.startFrame = startFrame
        self.endFrame = endFrame
    }
}

public struct VideoDeliveryRangeReport: Codable, Equatable, Sendable {
    public let startFrame: Int64
    public let endFrame: Int64
    public let frameRateNumerator: Int64
    public let frameRateDenominator: Int64
}

struct VideoDeliverySelection {
    let timeRange: CMTimeRange
    let frameCount: Int
    let report: VideoDeliveryRangeReport?

    init(
        _ requested: VideoDeliveryFrameRange?, duration: CMTime, frameDuration: CMTime
    ) throws {
        guard duration.isNumeric, duration > .zero,
            frameDuration.isNumeric, frameDuration > .zero
        else {
            throw VideoDeliveryError.invalidSettings("The composition has invalid frame timing.")
        }
        let ticks = CMTimeConvertScale(
            duration, timescale: frameDuration.timescale, method: .roundAwayFromZero)
        guard ticks.isNumeric, ticks.value > 0 else {
            throw VideoDeliveryError.invalidSettings("The composition has invalid frame timing.")
        }
        let count =
            ticks.value / frameDuration.value
            + (ticks.value % frameDuration.value == 0 ? 0 : 1)
        let start = requested?.startFrame ?? 0
        let end = requested?.endFrame ?? count
        guard start >= 0, end > start, end <= count, end <= Int32.max else {
            throw VideoDeliveryError.invalidSettings(
                "Choose output frames satisfying 0 <= startFrame < endFrame <= \(count).")
        }
        let startTime = CMTimeMultiply(frameDuration, multiplier: Int32(start))
        let endTime = CMTimeMinimum(
            CMTimeMultiply(frameDuration, multiplier: Int32(end)), duration)
        guard startTime.isNumeric, endTime.isNumeric, endTime > startTime else {
            throw VideoDeliveryError.invalidSettings(
                "The requested output range has invalid timing.")
        }
        timeRange = CMTimeRange(start: startTime, end: endTime)
        frameCount = Int(end - start)
        var divisor = Int64(frameDuration.timescale)
        var remainder = frameDuration.value
        while remainder != 0 { (divisor, remainder) = (remainder, divisor % remainder) }
        report = requested.map { _ in
            VideoDeliveryRangeReport(
                startFrame: start, endFrame: end,
                frameRateNumerator: Int64(frameDuration.timescale) / divisor,
                frameRateDenominator: frameDuration.value / divisor)
        }
    }
}
