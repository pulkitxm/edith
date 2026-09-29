@preconcurrency import AVFoundation

final class VideoAudioRateSource {
    let url: URL
    let asset: AVAsset
    let track: AVAssetTrack

    init(url: URL, asset: AVAsset, track: AVAssetTrack) {
        self.url = url
        self.asset = asset
        self.track = track
    }

    deinit { try? FileManager.default.removeItem(at: url) }
}

actor VideoAudioRateCache {
    static let shared = VideoAudioRateCache()
    private var entries: [String: VideoAudioRateSource] = [:]

    func source(url: URL, track: AVAssetTrack, range: CMTimeRange, rate: Double) async throws
        -> VideoAudioRateSource
    {
        let metadata = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let key =
            "\(url.absoluteString):\(metadata.contentModificationDate?.timeIntervalSince1970 ?? 0):\(metadata.fileSize ?? 0):\(rate)"
        if let source = entries[key] { return source }
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-audio-rate-\(UUID().uuidString).caf")
        do {
            let composition = AVMutableComposition()
            guard
                let scaled = composition.addMutableTrack(
                    withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            else { throw VideoRenderPipeline.RenderError.exportFailed("Could not prepare audio") }
            try scaled.insertTimeRange(range, of: track, at: .zero)
            scaled.scaleTimeRange(
                CMTimeRange(start: .zero, duration: range.duration),
                toDuration: VideoAudioMix.time(range.duration.seconds / rate))
            let reader = try AVAssetReader(asset: composition)
            let descriptions = try await track.load(.formatDescriptions)
            guard let description = descriptions.first,
                let stream = CMAudioFormatDescriptionGetStreamBasicDescription(description)
            else {
                throw VideoRenderPipeline.RenderError.exportFailed("Could not read audio format")
            }
            let channels = stream.pointee.mChannelsPerFrame
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: channels,
                interleaved: true)!
            let output = AVAssetReaderAudioMixOutput(
                audioTracks: [scaled],
                audioSettings: [
                    AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000,
                    AVNumberOfChannelsKey: channels, AVLinearPCMBitDepthKey: 32,
                    AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
                ])
            output.audioTimePitchAlgorithm = .spectral
            reader.add(output)
            guard reader.startReading() else {
                throw VideoRenderPipeline.RenderError.exportFailed(
                    "Audio rate reader: \(String(describing: reader.error))")
            }
            defer { reader.cancelReading() }
            try write(reader: reader, output: output, format: format, to: destination)
            let asset = AVURLAsset(url: destination)
            guard let rendered = try await asset.loadTracks(withMediaType: .audio).first else {
                throw VideoRenderPipeline.RenderError.exportFailed("Could not read rendered audio")
            }
            let source = VideoAudioRateSource(url: destination, asset: asset, track: rendered)
            if entries.count >= 8 { entries.removeAll() }
            entries[key] = source
            return source
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    private func write(
        reader: AVAssetReader, output: AVAssetReaderAudioMixOutput, format: AVAudioFormat,
        to url: URL
    ) throws {
        let file = try AVAudioFile(
            forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32,
            interleaved: true)
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sample))
            guard let block = CMSampleBufferGetDataBuffer(sample),
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
                let data = buffer.floatChannelData?[0]
            else { throw VideoRenderPipeline.RenderError.exportFailed("Could not decode audio") }
            buffer.frameLength = frames
            let status = CMBlockBufferCopyDataBytes(
                block, atOffset: 0,
                dataLength: Int(frames) * Int(format.channelCount) * MemoryLayout<Float>.size,
                destination: data)
            guard status == kCMBlockBufferNoErr else {
                throw VideoRenderPipeline.RenderError.exportFailed("Could not copy decoded audio")
            }
            try file.write(from: buffer)
        }
        guard reader.status == .completed else {
            throw VideoRenderPipeline.RenderError.exportFailed(
                "Audio rate decode: \(String(describing: reader.error))")
        }
    }
}
