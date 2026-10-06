@preconcurrency import AVFoundation
import Foundation

final class MeetingVoiceStream: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.pulkit.edith.meeting.voice", qos: .userInitiated)
    private let lock = NSLock()
    private var pending = 0
    private var stopped = false
    private var samples: [Float] = []
    private var history = [Float](repeating: 0, count: 2560)
    private var previousTail: [Float] = []
    private var inferenceDebt: TimeInterval = 0
    let outputFormat: AVAudioFormat
    private let inference: MeetingVoiceInference
    private let converter: AVAudioConverter
    private let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
    private let player: AVAudioPlayerNode
    private let transpose: Float
    private let failure: @Sendable (String) -> Void
    var isStopped: Bool { lock.withLock { stopped } }

    init(
        model: MeetingVoiceModel, input: AVAudioFormat, player: AVAudioPlayerNode, transpose: Float,
        failure: @escaping @Sendable (String) -> Void
    ) throws {
        inference = try MeetingVoiceInference(model: model)
        let rate = try inference.convert([Float](repeating: 0, count: 10240)).rate
        outputFormat = AVAudioFormat(standardFormatWithSampleRate: Double(rate), channels: 1)!
        guard let converter = AVAudioConverter(from: input, to: format) else {
            throw MeetingAudioLibrary.error("Cannot resample speech for voice conversion.")
        }
        self.converter = converter
        self.player = player
        self.transpose = transpose
        self.failure = failure
    }

    func enqueue(_ buffer: AVAudioPCMBuffer) {
        let acceptance = lock.withLock {
            guard !stopped else { return 0 }
            guard pending < 64 else { stopped = true; return 2 }
            pending += 1
            return 1
        }
        if acceptance == 2 {
            stop()
            failure("Voice conversion cannot keep up. Choose a smaller model.")
            return
        }
        guard acceptance == 1 else { return }
        queue.async { [weak self] in
            guard let self else { return }
            defer { self.lock.withLock { self.pending -= 1 } }
            guard !self.lock.withLock({ self.stopped }) else { return }
            do { try self.process(buffer) } catch {
                self.stop()
                self.failure(error.localizedDescription)
            }
        }
    }

    func stop() {
        lock.withLock {
            stopped = true; player.stop()
        }
    }

    private func process(_ input: AVAudioPCMBuffer) throws {
        let capacity = AVAudioFrameCount(
            ceil(Double(input.frameLength) * 16000 / input.format.sampleRate) + 16)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            return
        }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: buffer, error: &error) { _, result in
            if supplied { result.pointee = .noDataNow; return nil }
            supplied = true
            result.pointee = .haveData
            return input
        }
        if status == .error { throw error ?? MeetingAudioLibrary.error("Cannot resample speech.") }
        guard let data = buffer.floatChannelData?[0] else { return }
        samples.append(contentsOf: UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
        while samples.count >= 7680 {
            let chunk = Array(samples.prefix(7680))
            samples.removeFirst(7680)
            let started = ProcessInfo.processInfo.systemUptime
            let converted =
                chunk.allSatisfy({ abs($0) < 0.00001 })
                ? (
                    samples: [Float](repeating: 0, count: Int(outputFormat.sampleRate) * 48 / 100),
                    rate: Int(outputFormat.sampleRate)
                )
                : try inference.convert(history + chunk, transpose: transpose)
            guard !lock.withLock({ stopped }) else { return }
            inferenceDebt = max(
                0, inferenceDebt + ProcessInfo.processInfo.systemUptime - started - 0.48)
            guard inferenceDebt < 1.5 else {
                throw MeetingAudioLibrary.error(
                    "This voice model is too slow for live audio on this Mac. Choose a smaller model."
                )
            }
            history = Array(chunk.suffix(2560))
            let count = converted.rate * 48 / 100
            guard converted.samples.count >= count,
                let outputFormat = AVAudioFormat(
                    standardFormatWithSampleRate: Double(converted.rate), channels: 1),
                let output = AVAudioPCMBuffer(
                    pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(count)),
                let destination = output.floatChannelData?[0]
            else {
                throw MeetingAudioLibrary.error("The voice model did not return enough audio.")
            }
            let tail = converted.samples.suffix(count)
            for (index, value) in tail.enumerated() { destination[index] = value }
            let fade = min(converted.rate / 100, previousTail.count)
            for index in 0..<fade {
                let weight = Float(index) / Float(max(fade, 1))
                destination[index] =
                    previousTail[index] * (1 - weight) + destination[index] * weight
            }
            previousTail = Array(tail.suffix(converted.rate / 100))
            output.frameLength = AVAudioFrameCount(count)
            lock.withLock {
                if !stopped { player.scheduleBuffer(output) }
            }
        }
    }
}
