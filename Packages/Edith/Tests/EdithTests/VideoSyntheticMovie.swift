import AVFoundation
import CoreImage
import Testing
@testable import Edith

enum VideoSyntheticMovie {
    static func write(
        _ image: CIImage, to url: URL, duration: Double = 1,
        frameDuration: CMTime = CMTime(value: 1, timescale: 30),
        transform: CGAffineTransform = .identity
    ) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: Int(image.extent.width),
                AVVideoHeightKey: Int(image.extent.height),
            ])
        input.transform = transform
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(image.extent.width),
                kCVPixelBufferHeightKey as String: Int(image.extent.height),
            ])
        writer.add(input)
        try #require(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, try #require(adaptor.pixelBufferPool), &buffer)
        let pixelBuffer = try #require(buffer)
        VideoImageContext.shared.render(
            image, to: pixelBuffer, bounds: image.extent,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        for frame in 0..<Int(ceil(duration / frameDuration.seconds)) {
            let deadline = Date().addingTimeInterval(10)
            while !input.isReadyForMoreMediaData {
                try Task.checkCancellation()
                try #require(writer.status == .writing && Date() < deadline)
                try await Task.sleep(for: .milliseconds(5))
            }
            try #require(
                adaptor.append(
                    pixelBuffer,
                    withPresentationTime: CMTimeMultiply(frameDuration, multiplier: Int32(frame))))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(seconds: duration, preferredTimescale: 60000))
        await writer.finishWriting()
        try #require(writer.status == .completed)
    }
}
