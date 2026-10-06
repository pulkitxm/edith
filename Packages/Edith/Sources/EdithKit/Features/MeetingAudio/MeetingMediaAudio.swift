@preconcurrency import AVFoundation
import CoreMedia
import Foundation

public enum MeetingPCM {
    public static func buffer(from sample: CMSampleBuffer) -> AVAudioPCMBuffer? {
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

    public static func convert(_ input: AVAudioPCMBuffer, using converter: AVAudioConverter) throws
        -> AVAudioPCMBuffer
    {
        let capacity = AVAudioFrameCount(
            ceil(
                Double(input.frameLength) * converter.outputFormat.sampleRate
                    / input.format.sampleRate) + 128)
        guard
            let output = AVAudioPCMBuffer(
                pcmFormat: converter.outputFormat, frameCapacity: capacity)
        else { throw MeetingAudioLibrary.error("Cannot allocate an audio buffer.") }
        var supplied = false
        var failure: NSError?
        let result = converter.convert(to: output, error: &failure) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true
            status.pointee = .haveData
            return input
        }
        guard result != .error else {
            throw failure ?? MeetingAudioLibrary.error("Cannot convert source audio.")
        }
        return output
    }
}

final class MeetingMediaAudio {
    private let player: AVAudioPlayerNode
    private let queue: DispatchQueue
    private let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
    private var converter: AVAudioConverter?
    private var file: AVAudioFile?
    private var path: String?
    private var anchor: Double = 0
    private var pending = 0
    private var generation = 0
    private var lastVideoTime = 0.0

    init(player: AVAudioPlayerNode, queue: DispatchQueue) {
        self.player = player
        self.queue = queue
    }

    func syncVideo(path: String, time: Double, playing: Bool) throws {
        guard time.isFinite, time >= 0 else { return }
        guard playing else { stop(); return }
        if self.path != path {
            stop()
            self.path = path
            file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
            converter = file.flatMap { AVAudioConverter(from: $0.processingFormat, to: format) }
        }
        guard let file, let converter else { return }
        let rendered = player.lastRenderTime.flatMap { player.playerTime(forNodeTime: $0) }
        let position = anchor + Double(rendered?.sampleTime ?? 0) / format.sampleRate
        if !player.isPlaying || abs(position - time) > 0.18 || time < lastVideoTime {
            clearPlayback()
            converter.reset()
            anchor = time
            file.framePosition = min(
                file.length, AVAudioFramePosition(time * file.processingFormat.sampleRate))
        }
        lastVideoTime = time
        while pending < 3, file.framePosition < file.length {
            let capacity = AVAudioFrameCount(min(4800, file.length - file.framePosition))
            guard
                let input = AVAudioPCMBuffer(
                    pcmFormat: file.processingFormat, frameCapacity: capacity)
            else { return }
            try file.read(into: input)
            let output = try MeetingPCM.convert(input, using: converter)
            enqueue(output)
        }
        if pending > 0 && !player.isPlaying { player.play() }
    }

    func appendScreen(_ input: AVAudioPCMBuffer) throws {
        if path != nil { stop() }
        if converter?.inputFormat != input.format {
            converter = AVAudioConverter(from: input.format, to: format)
        }
        guard pending < 4, let converter else { return }
        enqueue(try MeetingPCM.convert(input, using: converter))
        if !player.isPlaying { player.play() }
    }

    private func enqueue(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0 else { return }
        pending += 1
        let generation = generation
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            self?.queue.async { [weak self] in
                guard let self, self.generation == generation else { return }
                self.pending = max(self.pending - 1, 0)
            }
        }
    }

    private func clearPlayback() {
        generation += 1
        player.stop()
        pending = 0
    }

    func stop() {
        clearPlayback()
        file = nil
        path = nil
        converter = nil
        lastVideoTime = 0
    }
}
