@preconcurrency import AVFoundation
import CoreVideo
import Foundation

public final class VirtualCameraRecorder {
    public let url: URL
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private var firstTime: TimeInterval?
    private var lastTime = CMTime.invalid

    public init(url: URL, size: CGSize) throws {
        self.url = url
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
            ])
        input.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input)
        guard writer.canAdd(input) else {
            throw CocoaError(.fileWriteUnknown)
        }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }

    public func append(_ buffer: CVPixelBuffer, at time: TimeInterval) throws {
        guard writer.status == .writing else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        if firstTime == nil {
            firstTime = time
            writer.startSession(atSourceTime: .zero)
        }
        guard input.isReadyForMoreMediaData, let firstTime else { return }
        let timestamp = CMTime(seconds: max(time - firstTime, 0), preferredTimescale: 600)
        guard !lastTime.isValid || timestamp > lastTime else { return }
        guard adaptor.append(buffer, withPresentationTime: timestamp) else {
            throw writer.error ?? CocoaError(.fileWriteUnknown)
        }
        lastTime = timestamp
    }

    public func finish(_ completion: @escaping (Result<URL, Error>) -> Void) {
        guard writer.status == .writing else {
            completion(.failure(writer.error ?? CocoaError(.fileWriteUnknown)))
            return
        }
        guard firstTime != nil else {
            writer.cancelWriting()
            completion(
                .failure(
                    NSError(
                        domain: "MeetingRecording", code: 1,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "No video frames arrived. The recording was not saved."
                        ])))
            return
        }
        input.markAsFinished()
        writer.finishWriting { [self] in
            completion(
                writer.status == .completed
                    ? .success(url) : .failure(writer.error ?? CocoaError(.fileWriteUnknown)))
        }
    }
}
