import AVFoundation
import CoreImage
import ImageIO

enum VideoStillMedia {
    struct Metadata: Sendable {
        let width: Int
        let height: Int
        let orientation: Int
        let colorSpace: String
        let format: String
    }

    static func image(at url: URL, previewMaxDimension: Int? = nil) throws -> CIImage {
        if let limit = previewMaxDimension, limit > 0 {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                let thumbnail = CGImageSourceCreateThumbnailAtIndex(
                    source, 0,
                    [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: limit,
                    ] as CFDictionary)
            else { throw StillError.unreadableImage }
            return CIImage(cgImage: thumbnail)
        }
        guard let image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]),
            image.extent.width > 0, image.extent.height > 0,
            !image.extent.isInfinite, !image.extent.isNull
        else { throw StillError.unreadableImage }
        return image.transformed(
            by: CGAffineTransform(
                translationX: -image.extent.minX, y: -image.extent.minY))
    }

    static func metadata(at url: URL) throws -> Metadata {
        let image = try image(at: url)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw StillError.unreadableImage
        }
        let properties =
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        return Metadata(
            width: Int(image.extent.width), height: Int(image.extent.height),
            orientation: (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1,
            colorSpace: properties[kCGImagePropertyProfileName] as? String
                ?? image.colorSpace?.name as String? ?? "unknown",
            format: CGImageSourceGetType(source) as String? ?? "unknown")
    }

    actor TimingCarrier {
        static let shared = TimingCarrier()
        private var pending: Task<URL, Error>?

        func url() async throws -> URL {
            if let pending { return try await pending.value }
            let task = Task { try await VideoStillMedia.createTimingCarrier() }
            pending = task
            do { return try await task.value } catch { pending = nil; throw error }
        }
    }

    private static func createTimingCarrier() async throws -> URL {
        let media = VideoProject.libraryURL.appendingPathComponent("media", isDirectory: true)
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        let url = media.appendingPathComponent("timing-\(UUID().uuidString).mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 16, AVVideoHeightKey: 16,
            ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 16, kCVPixelBufferHeightKey as String: 16,
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
            VideoImageContext.shared.render(
                CIImage(color: .black), to: buffer,
                bounds: CGRect(x: 0, y: 0, width: 16, height: 16),
                colorSpace: VideoSettings.ColorSpace.rec709.cgColorSpace)
            while !input.isReadyForMoreMediaData {
                try Task.checkCancellation()
                guard writer.status == .writing else {
                    throw writer.error ?? StillError.encodingFailed
                }
                try await Task.sleep(for: .milliseconds(5))
            }
            guard adaptor.append(buffer, withPresentationTime: .zero) else {
                throw writer.error ?? StillError.encodingFailed
            }
            writer.endSession(atSourceTime: CMTime(value: 1, timescale: 1))
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

extension VideoProject {
    mutating func addStillAsset(
        _ url: URL, duration: Double = 5,
        metadata: VideoStillMedia.Metadata
    ) throws {
        guard duration.isFinite, duration > 0, duration < Double(Int64.max) / 600 else {
            throw VideoVisualEffects.VisualError.invalidDuration
        }
        addAsset(
            url, duration: duration, width: metadata.width, height: metadata.height,
            sourceImage: url,
            sourceMetadata: [
                "codec": metadata.format, "width": metadata.width, "height": metadata.height,
                "orientation": metadata.orientation, "colorSpace": metadata.colorSpace,
            ])
    }
}
