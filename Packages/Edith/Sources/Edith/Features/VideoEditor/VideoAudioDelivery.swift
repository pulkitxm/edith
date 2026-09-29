@preconcurrency import AVFoundation
import CryptoKit

struct VideoAudioDeliverySettings: Codable, Equatable, Sendable {
    enum Container: String, CaseIterable, Codable, Sendable {
        case wav, aiff, m4a
    }

    var container: Container = .wav
    var sampleRate = 48_000
    var channels = 2
    var bitRate = 320_000

    func validate() throws {
        guard [44_100, 48_000, 96_000].contains(sampleRate), (1...2).contains(channels),
            (32_000...320_000).contains(bitRate), container != .m4a || sampleRate != 96_000
        else { throw VideoDeliveryError.invalidSettings("Invalid audio delivery settings.") }
        guard container != .m4a || channels != 1 || bitRate <= 256_000 else {
            throw VideoDeliveryError.invalidSettings("Mono AAC supports at most 256 kbps.")
        }
    }

    var encoding: [String: Any] {
        var settings = VideoDeliverySettings()
        settings.audioCodec = container == .m4a ? .aac : .pcm
        settings.audioSampleRate = sampleRate
        settings.audioChannels = channels
        settings.audioBitRate = bitRate
        var encoding = settings.audioSettings
        if container == .aiff { encoding[AVLinearPCMIsBigEndianKey] = true }
        return encoding
    }
}

struct VideoAudioDeliveryReport: Codable, Sendable {
    let duration: Double
    let sampleRate: Double
    let channels: Int
    let frames: Int64
    let bytes: Int64
    let sha256: String

    static func inspect(_ url: URL) throws -> Self {
        let audio = try AVAudioFile(forReading: url)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var bytes: Int64 = 0
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            try Task.checkCancellation()
            hasher.update(data: data)
            bytes += Int64(data.count)
        }
        return Self(
            duration: Double(audio.length) / audio.processingFormat.sampleRate,
            sampleRate: audio.processingFormat.sampleRate,
            channels: Int(audio.processingFormat.channelCount), frames: audio.length, bytes: bytes,
            sha256: hasher.finalize().map { String(format: "%02x", $0) }.joined())
    }
}

extension VideoRenderPipeline {
    func exportAudio(
        to destination: URL, settings: VideoAudioDeliverySettings = .init(),
        overwrite: Bool = false,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> VideoAudioDeliveryReport {
        try settings.validate()
        guard destination.isFileURL,
            destination.pathExtension.lowercased() == settings.container.rawValue
        else {
            throw VideoDeliveryError.invalidSettings(
                "The destination extension must be .\(settings.container.rawValue).")
        }
        guard overwrite || !FileManager.default.fileExists(atPath: destination.path) else {
            throw VideoDeliveryError.destinationExists
        }
        for track in composition.tracks {
            for segment in track.segments {
                if segment.sourceURL?.resolvingSymlinksInPath()
                    == destination.resolvingSymlinksInPath()
                {
                    throw VideoDeliveryError.invalidSettings(
                        "An export cannot replace its source media.")
                }
            }
        }
        let tracks = try await composition.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else {
            throw VideoDeliveryError.invalidSettings("The timeline has no audio to export.")
        }
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(
            ".\(UUID().uuidString).partial.\(settings.container.rawValue)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let reader = try AVAssetReader(asset: composition)
        let output = AVAssetReaderAudioMixOutput(
            audioTracks: tracks,
            audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: settings.sampleRate, AVNumberOfChannelsKey: settings.channels,
                AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: false,
            ])
        output.audioMix = audioMix
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw VideoDeliveryError.failed("Could not configure the audio mix export.")
        }
        reader.add(output)
        do {
            try Task.checkCancellation()
            guard reader.startReading() else {
                throw reader.error ?? VideoDeliveryError.failed("Could not read the audio mix.")
            }
            let frames = CMTimeConvertScale(
                composition.duration, timescale: Int32(settings.sampleRate),
                method: .roundHalfAwayFromZero
            ).value
            try Self.writeAudioMix(
                output, to: temporary, settings: settings, frames: frames, progress: progress)
            guard reader.status == .completed else {
                throw reader.error ?? VideoDeliveryError.failed("The audio mix did not finish.")
            }
            try Task.checkCancellation()
            let report = try VideoAudioDeliveryReport.inspect(temporary)
            guard report.frames == frames, report.sampleRate == Double(settings.sampleRate),
                report.channels == settings.channels
            else {
                throw VideoDeliveryError.failed(
                    "The audio output did not match the requested format.")
            }
            try Task.checkCancellation()
            if overwrite {
                guard rename(temporary.path, destination.path) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            } else {
                try FileManager.default.moveItem(at: temporary, to: destination)
            }
            progress(1)
            return report
        } catch {
            reader.cancelReading()
            throw error
        }
    }

    private static func writeAudioMix(
        _ output: AVAssetReaderOutput, to url: URL, settings: VideoAudioDeliverySettings,
        frames: Int64, progress: @escaping @Sendable (Double) -> Void
    ) throws {
        guard frames > 0,
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: Double(settings.sampleRate),
                channels: AVAudioChannelCount(settings.channels), interleaved: true),
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192)
        else { throw VideoDeliveryError.failed("Could not allocate the audio encoding buffer.") }
        let file = try AVAudioFile(
            forWriting: url, settings: settings.encoding, commonFormat: .pcmFormatFloat32,
            interleaved: true)
        var cursor: Int64 = 0
        func silence(until end: Int64) throws {
            while cursor < end {
                try Task.checkCancellation()
                buffer.frameLength = AVAudioFrameCount(min(8192, end - cursor))
                for audioBuffer in UnsafeMutableAudioBufferListPointer(
                    buffer.mutableAudioBufferList)
                {
                    if let data = audioBuffer.mData {
                        memset(data, 0, Int(audioBuffer.mDataByteSize))
                    }
                }
                try file.write(from: buffer)
                cursor += Int64(buffer.frameLength)
            }
        }
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            let start = CMTimeConvertScale(
                CMSampleBufferGetPresentationTimeStamp(sample),
                timescale: Int32(settings.sampleRate), method: .roundHalfAwayFromZero
            ).value
            try silence(until: min(frames, max(0, start)))
            let count = CMSampleBufferGetNumSamples(sample)
            var offset = Int(max(0, cursor - start))
            while offset < count && cursor < frames {
                try Task.checkCancellation()
                let length = min(8192, count - offset, Int(frames - cursor))
                buffer.frameLength = AVAudioFrameCount(length)
                guard
                    CMSampleBufferCopyPCMDataIntoAudioBufferList(
                        sample, at: Int32(offset), frameCount: Int32(length),
                        into: buffer.mutableAudioBufferList) == noErr
                else {
                    throw VideoDeliveryError.failed("Could not decode the mixed audio samples.")
                }
                try file.write(from: buffer)
                offset += length
                cursor += Int64(length)
            }
            progress(min(0.99, Double(cursor) / Double(frames)))
        }
        try silence(until: frames)
    }
}
