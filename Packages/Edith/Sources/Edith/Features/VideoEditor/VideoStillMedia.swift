import AVFoundation
import CoreImage

enum VideoStillMedia {
    static func create(from imageURL: URL, duration: Double = 5) async throws -> URL {
        guard let image = CIImage(contentsOf: imageURL),
            image.extent.width > 0, image.extent.height > 0
        else { throw StillError.unreadableImage }

        let maxSide = max(image.extent.width, image.extent.height)
        let scale = min(1, 1920 / maxSide)
        let width = max(2, Int(image.extent.width * scale) / 2 * 2)
        let height = max(2, Int(image.extent.height * scale) / 2 * 2)
        let media = VideoProject.libraryURL.appendingPathComponent("media", isDirectory: true)
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        let url = media.appendingPathComponent("still-\(UUID().uuidString).mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
            ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? StillError.encodingFailed }
        writer.startSession(atSourceTime: .zero)

        do {
            guard let pool = adaptor.pixelBufferPool else { throw StillError.encodingFailed }
            var buffer: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess,
                let buffer
            else { throw StillError.encodingFailed }
            let scaled =
                image
                .transformed(
                    by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY)
                )
                .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            CIContext().render(
                scaled, to: buffer,
                bounds: CGRect(x: 0, y: 0, width: width, height: height),
                colorSpace: CGColorSpaceCreateDeviceRGB())
            let frames = max(1, Int(duration * 30))
            for frame in 0..<frames {
                try Task.checkCancellation()
                while !input.isReadyForMoreMediaData {
                    try await Task.sleep(for: .milliseconds(10))
                }
                let time = CMTime(value: Int64(frame), timescale: 30)
                guard adaptor.append(buffer, withPresentationTime: time) else {
                    throw writer.error ?? StillError.encodingFailed
                }
            }
            input.markAsFinished()
            await withCheckedContinuation { continuation in
                writer.finishWriting { continuation.resume() }
            }
            guard writer.status == .completed else {
                throw writer.error ?? StillError.encodingFailed
            }
            return url
        } catch {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    enum StillError: LocalizedError {
        case unreadableImage
        case encodingFailed

        var errorDescription: String? {
            switch self {
            case .unreadableImage: "This image could not be opened."
            case .encodingFailed: "The image could not be added to the timeline."
            }
        }
    }
}
