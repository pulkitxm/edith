@preconcurrency import AVFoundation
import CoreMedia
import Foundation

final class VirtualCameraSourceAudio {
    typealias Chunk = (buffer: AVAudioPCMBuffer, time: TimeInterval)

    static let lead: TimeInterval = 0.2
    private let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
    private var converter: AVAudioConverter?
    private var file: AVAudioFile?
    private var path: String?
    private var lastVideoTime = 0.0
    private var nextTime: TimeInterval?

    func video(path: String, time: Double, playing: Bool, now: TimeInterval) throws -> [Chunk] {
        guard playing, time.isFinite, time >= 0 else { reset(); return [] }
        if self.path != path {
            reset()
            self.path = path
            let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
            self.file = file
            converter = AVAudioConverter(from: file.processingFormat, to: format)
        }
        guard let file, let converter else { return [] }
        let rate = file.processingFormat.sampleRate
        let position = Double(file.framePosition) / rate
        if time < lastVideoTime || position < time - Self.lead || position > time + 2 * Self.lead {
            converter.reset()
            nextTime = nil
            file.framePosition = min(file.length, AVAudioFramePosition(time * rate))
        }
        lastVideoTime = time
        var chunks: [Chunk] = []
        while file.framePosition < file.length,
            Double(file.framePosition) / rate < time + Self.lead
        {
            let start = Double(file.framePosition) / rate
            let capacity = AVAudioFrameCount(min(4800, file.length - file.framePosition))
            guard
                let input = AVAudioPCMBuffer(
                    pcmFormat: file.processingFormat, frameCapacity: capacity)
            else { break }
            try file.read(into: input)
            if let chunk = stamp(try Self.convert(input, using: converter), at: now + start - time)
            {
                chunks.append(chunk)
            }
        }
        return chunks
    }

    func screen(_ sample: CMSampleBuffer, now: TimeInterval) throws -> Chunk? {
        if path != nil { reset() }
        guard let input = Self.buffer(from: sample) else { return nil }
        if converter?.inputFormat != input.format {
            converter = AVAudioConverter(from: input.format, to: format)
        }
        guard let converter else { return nil }
        return stamp(try Self.convert(input, using: converter), at: now)
    }

    func reset() {
        file = nil
        path = nil
        converter = nil
        lastVideoTime = 0
        nextTime = nil
    }

    private func stamp(_ buffer: AVAudioPCMBuffer, at time: TimeInterval) -> Chunk? {
        guard buffer.frameLength > 0 else { return nil }
        var start = time
        if let nextTime, abs(nextTime - time) < Self.lead { start = nextTime }
        nextTime = start + Double(buffer.frameLength) / format.sampleRate
        return (buffer, start)
    }

    static func buffer(from sample: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let description = sample.formatDescription else { return nil }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        guard
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format, frameCapacity: AVAudioFrameCount(sample.numSamples))
        else { return nil }
        buffer.frameLength = buffer.frameCapacity
        guard
            CMSampleBufferCopyPCMDataIntoAudioBufferList(
                sample, at: 0, frameCount: Int32(buffer.frameLength),
                into: buffer.mutableAudioBufferList) == noErr
        else { return nil }
        return buffer
    }

    static func convert(_ input: AVAudioPCMBuffer, using converter: AVAudioConverter) throws
        -> AVAudioPCMBuffer
    {
        let capacity = AVAudioFrameCount(
            ceil(
                Double(input.frameLength) * converter.outputFormat.sampleRate
                    / input.format.sampleRate) + 128)
        guard
            let output = AVAudioPCMBuffer(
                pcmFormat: converter.outputFormat, frameCapacity: capacity)
        else { throw failure("Cannot allocate an audio buffer.") }
        var supplied = false
        var error: NSError?
        let result = converter.convert(to: output, error: &error) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true
            status.pointee = .haveData
            return input
        }
        guard result != .error else { throw error ?? failure("Cannot convert source audio.") }
        return output
    }

    private static func failure(_ message: String) -> NSError {
        NSError(
            domain: "VirtualCameraSourceAudio", code: 1,
            userInfo: [NSLocalizedDescriptionKey: message])
    }
}
