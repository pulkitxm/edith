@preconcurrency import AVFoundation

public enum VideoFrameSampling: String, Codable, CaseIterable, Sendable {
    case hold, nearest

    struct Failure: LocalizedError {
        let reason: String
        var errorDescription: String? {
            "Nearest frame sampling: \(reason) Use hold sampling for this clip instead."
        }
    }

    func visualRange(
        track: AVAssetTrack, source: CMTimeRange, output: CMTimeRange, frameDuration: CMTime
    ) async throws -> CMTimeRange {
        guard self == .nearest else { return source }
        guard source.duration == output.duration else {
            throw Failure(reason: "speed changes are not supported.")
        }
        guard let cursor = track.makeSampleCursor(presentationTimeStamp: source.start) else {
            throw Failure(reason: "the source does not expose sample timestamps.")
        }
        while cursor.presentationTimeStamp < source.start {
            try Task.checkCancellation()
            guard cursor.stepInPresentationOrder(byCount: 1) == 1 else {
                throw Failure(reason: "there is no sample at or after the trim start.")
            }
        }
        let first = cursor.presentationTimeStamp
        guard first.isNumeric, first < source.end else {
            throw Failure(reason: "the trimmed interval contains no post-seek sample.")
        }
        let scale = try Self.timescale([
            source.start.timescale, source.duration.timescale, output.start.timescale,
            first.timescale, try Self.timescale([frameDuration.timescale], doubled: true),
        ])
        let frameTicks = CMTimeConvertScale(frameDuration, timescale: scale, method: .default).value
        let outputTicks = CMTimeConvertScale(output.start, timescale: scale, method: .default).value
        guard frameTicks > 0, outputTicks % frameTicks == 0 else {
            throw Failure(reason: "the clip must start on an output frame boundary.")
        }
        let firstTicks = CMTimeConvertScale(
            first - source.start, timescale: scale, method: .default).value
        let firstFrame = (firstTicks + frameTicks / 2) / frameTicks
        let phase = CMTime(value: firstFrame * frameTicks + frameTicks / 2 - 1, timescale: scale)
        let result = CMTimeRange(start: source.start + phase, duration: source.duration)
        let available = try await track.load(.timeRange)
        guard available.containsTimeRange(result) else {
            throw Failure(reason: "the visual sampling phase extends beyond available source media.")
        }
        return result
    }

    private static func timescale(_ values: [CMTimeScale], doubled: Bool = false) throws
        -> CMTimeScale
    {
        var result: Int64 = 1
        for value in values {
            guard value > 0 else { throw Failure(reason: "the source clock is invalid.") }
            var a = result
            var b = Int64(value)
            while b != 0 { (a, b) = (b, a % b) }
            result = result / a * Int64(value)
            guard result <= Int32.max else {
                throw Failure(reason: "the source and output clocks cannot share an exact phase.")
            }
        }
        if doubled { result *= 2 }
        guard result <= Int32.max else {
            throw Failure(reason: "the output clock cannot represent an exact half frame.")
        }
        return CMTimeScale(result)
    }
}
