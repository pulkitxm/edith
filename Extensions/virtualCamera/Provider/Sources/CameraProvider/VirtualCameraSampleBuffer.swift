import CoreMedia
import CoreVideo
import Foundation

public enum VirtualCameraSampleBuffer {
    public static func hostTimeNanoseconds(_ time: CMTime) -> UInt64 {
        guard time.isValid, time.seconds.isFinite, time.seconds > 0 else { return 0 }
        return UInt64(time.seconds * 1_000_000_000)
    }

    public static func now() -> CMTime {
        CMClockGetTime(CMClockGetHostTimeClock())
    }

    public static func make(
        pixelBuffer: CVPixelBuffer, presentationTime: CMTime, frameRate: Int
    ) -> CMSampleBuffer? {
        var format: CMFormatDescription?
        guard
            CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
                formatDescriptionOut: &format) == noErr, let format
        else { return nil }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(max(frameRate, 1))),
            presentationTimeStamp: presentationTime, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard
            CMSampleBufferCreateReadyWithImageBuffer(
                allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
                formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample)
                == noErr
        else { return nil }
        return sample
    }
}
