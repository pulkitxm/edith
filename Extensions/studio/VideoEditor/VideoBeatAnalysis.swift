import AVFoundation
import Foundation

public enum VideoBeatAnalysis {
    struct Settings: Sendable {
        var sensitivity: Double = 0.5
        var refractorySeconds: Double = 0.08
        var minimumSpacingSeconds: Double = 0.15
        var minimumPeak: Float = 0.04
        var maximumWaveformBins: Int = 2048
        var maximumTransients: Int = 10_000

        func validate() throws {
            guard sensitivity.isFinite, (0...1).contains(sensitivity),
                refractorySeconds.isFinite, (0...10).contains(refractorySeconds),
                minimumSpacingSeconds.isFinite, (0...60).contains(minimumSpacingSeconds),
                minimumPeak.isFinite, (0.0001...1).contains(minimumPeak),
                (2...16384).contains(maximumWaveformBins), maximumWaveformBins.isMultiple(of: 2),
                (1...100_000).contains(maximumTransients)
            else { throw AnalysisError.invalidSettings }
        }
    }

    public struct WaveformBin: Codable, Equatable, Sendable {
        public let startSample: Int64
        public var sampleCount: Int64
        public var peak: Float
        public var meanSquare: Double

        public var rms: Double { sqrt(meanSquare) }

        mutating func merge(_ other: Self) {
            let total = sampleCount + other.sampleCount
            meanSquare =
                (meanSquare * Double(sampleCount) + other.meanSquare * Double(other.sampleCount))
                / Double(total)
            sampleCount = total
            peak = max(peak, other.peak)
        }
    }

    public struct Transient: Codable, Equatable, Sendable {
        public let sample: Int64
        public let strength: Float
    }

    public struct TempoEstimate: Codable, Equatable, Sendable {
        public let beatsPerMinute: Double
        public let intervalAgreement: Double
        public let supportingIntervals: Int
    }

    public struct Result: Codable, Equatable, Sendable {
        public let sampleRate: Double
        public let sampleCount: Int64
        public let waveform: [WaveformBin]
        public let transients: [Transient]
        public let transientsTruncated: Bool
        public let tempoEstimate: TempoEstimate?

        public var duration: Double { Double(sampleCount) / sampleRate }

        func markers(
            frameRate: VideoMarkerFrameRate = .fps30, sourceRange: Range<Double>? = nil,
            outputStart: Double = 0, playbackRate: Double = 1
        ) throws -> [VideoMarker] {
            let range = sourceRange ?? 0..<duration
            guard outputStart.isFinite, outputStart >= 0, playbackRate.isFinite, playbackRate > 0,
                range.lowerBound.isFinite, range.upperBound.isFinite, range.lowerBound >= 0
            else { throw AnalysisError.invalidSettings }
            var seen = Set<Int64>()
            return try transients.compactMap { transient in
                let seconds = Double(transient.sample) / sampleRate
                guard range.contains(seconds) else { return nil }
                let frame = try frameRate.frame(
                    at: outputStart + (seconds - range.lowerBound) / playbackRate)
                guard seen.insert(frame).inserted else { return nil }
                return try VideoMarker(
                    frame: frame, frameRate: frameRate, label: "Transient", kind: .transient)
            }
        }
    }

    enum AnalysisError: LocalizedError {
        case noAudio, invalidSettings, invalidPCM, unsupportedDuration, decodeFailed

        var errorDescription: String? {
            switch self {
            case .noAudio: return "The source has no audio track."
            case .invalidSettings:
                return "Audio analysis settings are outside their supported ranges."
            case .invalidPCM:
                return "Audio analysis requires finite, interleaved floating-point PCM."
            case .unsupportedDuration: return "Audio analysis supports sources up to 24 hours long."
            case .decodeFailed: return "The audio track could not be decoded."
            }
        }
    }

    struct Stream {
        let sampleRate: Double
        let channels: Int
        let settings: Settings
        private let windowSize: Int64
        private var position: Int64 = 0
        private var windowCount: Int64 = 0
        private var windowEnergy: Double = 0
        private var windowPeak: Float = 0
        private var peakPosition: Int64 = 0
        private var baseline: Double = 0
        private var previousRMS: Double = 0
        private var lastTransient: Int64?
        private var binWidth: Int64
        private var pendingBin: WaveformBin?
        private var bins: [WaveformBin] = []
        private var transients: [Transient] = []
        private var truncated = false

        init(sampleRate: Double, channels: Int, settings: Settings = Settings()) throws {
            try settings.validate()
            guard sampleRate.isFinite, (1000...384000).contains(sampleRate),
                (1...32).contains(channels)
            else { throw AnalysisError.invalidPCM }
            self.sampleRate = sampleRate
            self.channels = channels
            self.settings = settings
            windowSize = Int64((sampleRate * 0.01).rounded())
            binWidth = windowSize
        }

        mutating func append(_ samples: [Float], startingAtFrame: Int64? = nil) throws {
            try samples.withUnsafeBufferPointer {
                try append($0, startingAtFrame: startingAtFrame)
            }
        }

        mutating func append(
            _ samples: UnsafeBufferPointer<Float>, startingAtFrame: Int64? = nil
        ) throws {
            guard samples.count.isMultiple(of: channels) else { throw AnalysisError.invalidPCM }
            let start = startingAtFrame ?? position
            let count = Int64(samples.count / channels)
            let limit = Int64(sampleRate * 86400)
            guard start >= 0, start <= limit, count <= limit - start else {
                throw AnalysisError.unsupportedDuration
            }
            guard samples.allSatisfy({ $0.isFinite }) else { throw AnalysisError.invalidPCM }
            while position < start {
                if position.isMultiple(of: 16384) { try Task.checkCancellation() }
                consume(peak: 0, energy: 0)
            }
            let skipped = min(count, max(0, position - start))
            for frame in Int(skipped)..<Int(count) {
                if frame.isMultiple(of: 16384) { try Task.checkCancellation() }
                var energy = 0.0
                var peak: Float = 0
                for channel in 0..<channels {
                    let value = min(1, abs(samples[frame * channels + channel]))
                    peak = max(peak, value)
                    energy += Double(value) * Double(value)
                }
                consume(peak: peak, energy: energy / Double(channels))
            }
        }

        func finish() -> Result {
            var copy = self
            if copy.windowCount > 0 { copy.finishWindow() }
            if let pending = copy.pendingBin { copy.appendBin(pending) }
            return Result(
                sampleRate: sampleRate, sampleCount: position, waveform: copy.bins,
                transients: copy.transients, transientsTruncated: copy.truncated,
                tempoEstimate: copy.truncated
                    ? nil : Self.estimateTempo(copy.transients, sampleRate))
        }

        private mutating func consume(peak: Float, energy: Double) {
            if peak > windowPeak {
                windowPeak = peak
                peakPosition = position
            }
            windowEnergy += energy
            windowCount += 1
            position += 1
            if windowCount == windowSize { finishWindow() }
        }

        private mutating func finishWindow() {
            let meanSquare = windowEnergy / Double(windowCount)
            let rms = sqrt(meanSquare)
            let ratio = 5 - settings.sensitivity * 3.5
            let rise = 2 - settings.sensitivity * 0.8
            let spacing = max(settings.refractorySeconds, settings.minimumSpacingSeconds)
            let spaced =
                lastTransient.map { Double(peakPosition - $0) / sampleRate >= spacing } ?? true
            if windowPeak >= settings.minimumPeak, rms > max(0.00001, baseline) * ratio,
                rms > previousRMS * rise, spaced
            {
                if transients.count < settings.maximumTransients {
                    transients.append(Transient(sample: peakPosition, strength: windowPeak))
                } else {
                    truncated = true
                }
                lastTransient = peakPosition
            }
            baseline = baseline * 0.95 + rms * 0.05
            previousRMS = rms
            let bin = WaveformBin(
                startSample: position - windowCount, sampleCount: windowCount,
                peak: windowPeak, meanSquare: meanSquare)
            if pendingBin != nil { pendingBin?.merge(bin) } else { pendingBin = bin }
            if let pending = pendingBin, pending.sampleCount >= binWidth {
                appendBin(pending)
                pendingBin = nil
            }
            windowCount = 0
            windowEnergy = 0
            windowPeak = 0
        }

        private mutating func appendBin(_ bin: WaveformBin) {
            if bins.count == settings.maximumWaveformBins {
                var reduced: [WaveformBin] = []
                reduced.reserveCapacity(bins.count / 2)
                for index in stride(from: 0, to: bins.count, by: 2) {
                    var combined = bins[index]
                    combined.merge(bins[index + 1])
                    reduced.append(combined)
                }
                bins = reduced
                binWidth *= 2
            }
            bins.append(bin)
        }

        private static func estimateTempo(_ transients: [Transient], _ sampleRate: Double)
            -> TempoEstimate?
        {
            guard transients.count >= 7 else { return nil }
            let intervals = zip(transients, transients.dropFirst()).map {
                Double($1.sample - $0.sample) / sampleRate
            }
            let sorted = intervals.sorted()
            let median = sorted[sorted.count / 2]
            guard (0.25...2).contains(median) else { return nil }
            let agreeing = intervals.filter { abs($0 - median) <= median * 0.08 }.count
            let agreement = Double(agreeing) / Double(intervals.count)
            guard agreement >= 0.8 else { return nil }
            return TempoEstimate(
                beatsPerMinute: 60 / median, intervalAgreement: agreement,
                supportingIntervals: agreeing)
        }
    }

    static func analyze(_ url: URL, settings: Settings = Settings()) async throws -> Result {
        try settings.validate()
        try Task.checkCancellation()
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw AnalysisError.noAudio
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw AnalysisError.decodeFailed }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? AnalysisError.decodeFailed }
        defer { if reader.status == .reading { reader.cancelReading() } }
        var stream: Stream?
        while reader.status == .reading {
            try Task.checkCancellation()
            let consumed: Bool = try autoreleasepool {
                guard let buffer = output.copyNextSampleBuffer() else { return false }
                guard let description = CMSampleBufferGetFormatDescription(buffer),
                    let format = CMAudioFormatDescriptionGetStreamBasicDescription(description),
                    let block = CMSampleBufferGetDataBuffer(buffer)
                else { throw AnalysisError.invalidPCM }
                let channels = Int(format.pointee.mChannelsPerFrame)
                let rate = format.pointee.mSampleRate
                guard format.pointee.mFormatID == kAudioFormatLinearPCM,
                    format.pointee.mBitsPerChannel == 32,
                    format.pointee.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                    format.pointee.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
                else { throw AnalysisError.invalidPCM }
                if stream == nil {
                    stream = try Stream(sampleRate: rate, channels: channels, settings: settings)
                }
                guard stream?.channels == channels, stream?.sampleRate == rate else {
                    throw AnalysisError.invalidPCM
                }
                let bytes = CMBlockBufferGetDataLength(block)
                guard bytes > 0, bytes <= 16 * 1024 * 1024,
                    bytes.isMultiple(of: MemoryLayout<Float>.size * channels)
                else { throw AnalysisError.invalidPCM }
                var samples = [Float](repeating: 0, count: bytes / MemoryLayout<Float>.size)
                let status = samples.withUnsafeMutableBytes {
                    CMBlockBufferCopyDataBytes(
                        block, atOffset: 0, dataLength: bytes, destination: $0.baseAddress!)
                }
                guard status == kCMBlockBufferNoErr else { throw AnalysisError.decodeFailed }
                let seconds = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
                guard seconds.isFinite, seconds >= 0, seconds <= 86400 else {
                    throw AnalysisError.unsupportedDuration
                }
                try stream?.append(samples, startingAtFrame: Int64((seconds * rate).rounded()))
                return true
            }
            if !consumed { break }
        }
        try Task.checkCancellation()
        guard reader.status == .completed else { throw reader.error ?? AnalysisError.decodeFailed }
        guard let stream else { throw AnalysisError.noAudio }
        return stream.finish()
    }
}
