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
    private var audioInput: AVAssetWriterInput?
    private var lastAudioTime = CMTime.invalid

    public init(url: URL, size: CGSize, audio: Bool = false) throws {
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
        if audio {
            let audioInput = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000,
                    AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 128000,
                ])
            audioInput.expectsMediaDataInRealTime = true
            guard writer.canAdd(audioInput) else { throw CocoaError(.fileWriteUnknown) }
            writer.add(audioInput)
            self.audioInput = audioInput
        }
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

    public func appendAudio(_ buffer: AVAudioPCMBuffer, at time: TimeInterval) throws {
        guard let audioInput, let firstTime, time >= firstTime, buffer.frameLength > 0 else {
            return
        }
        guard writer.status == .writing else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        guard audioInput.isReadyForMoreMediaData else { return }
        let timestamp = CMTime(seconds: time - firstTime, preferredTimescale: 48000)
        guard !lastAudioTime.isValid || timestamp > lastAudioTime else { return }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: Int32(buffer.format.sampleRate)),
            presentationTimeStamp: timestamp, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        let created = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
            makeDataReadyCallback: nil, refcon: nil,
            formatDescription: buffer.format.formatDescription,
            sampleCount: Int(buffer.frameLength), sampleTimingEntryCount: 1,
            sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil,
            sampleBufferOut: &sample)
        guard created == noErr, let sample else { throw CocoaError(.fileWriteUnknown) }
        let copied = CMSampleBufferSetDataBufferFromAudioBufferList(
            sample, blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0,
            bufferList: buffer.audioBufferList)
        guard copied == noErr, CMSampleBufferSetDataReady(sample) == noErr,
            audioInput.append(sample)
        else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        lastAudioTime = timestamp
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
        audioInput?.markAsFinished()
        writer.finishWriting { [self] in
            completion(
                writer.status == .completed
                    ? .success(url) : .failure(writer.error ?? CocoaError(.fileWriteUnknown)))
        }
    }
}
