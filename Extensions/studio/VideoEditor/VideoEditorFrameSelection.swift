import AVFoundation

extension VideoEditorService {
    static func frameSelection(
        in pipeline: VideoRenderPipeline, seconds: Double? = nil, frameIndex: Int64? = nil
    ) throws -> (frame: Int64, time: CMTime) {
        try require((seconds != nil) != (frameIndex != nil), "Choose exactly one of time or frame.")
        let duration = pipeline.composition.duration
        let cadence = pipeline.videoComposition.frameDuration
        try require(
            duration.isNumeric && duration > .zero && cadence.isNumeric && cadence > .zero,
            "The composition has invalid frame timing.")
        func time(_ frame: Int64) throws -> CMTime {
            try require(
                frame >= 0 && frame <= Int32.max, "Frame index is outside the supported range.")
            return CMTimeMultiply(cadence, multiplier: Int32(frame))
        }
        var frame: Int64
        if let seconds {
            try require(
                seconds.isFinite && seconds >= 0 && seconds < duration.seconds,
                "Frame time is outside the rendered timeline.")
            let estimate = floor(seconds / cadence.seconds)
            try require(
                estimate <= Double(Int32.max), "Frame index is outside the supported range.")
            frame = Int64(estimate)
            while frame > 0, try time(frame).seconds > seconds { frame -= 1 }
            while frame < Int32.max, try time(frame + 1).seconds <= seconds,
                try time(frame + 1) < duration
            {
                frame += 1
            }
        } else {
            frame = frameIndex!
        }
        let selected = try time(frame)
        try require(
            selected.isNumeric && selected < duration,
            "Frame index is outside the rendered timeline.")
        return (frame, selected)
    }
}
