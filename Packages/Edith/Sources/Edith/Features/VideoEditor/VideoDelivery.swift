@preconcurrency import AVFoundation
import CryptoKit
import VideoToolbox

extension VideoProject {
    func protectsMedia(at destination: URL) -> Bool {
        let destination = destination.resolvingSymlinksInPath()
        if fileURL?.resolvingSymlinksInPath() == destination { return true }
        for asset in assets {
            if asset.url.resolvingSymlinksInPath() == destination { return true }
            var paths: [String] = []
            for key in ["edithSourceImagePath", "edithAudioPath"] {
                if let path = asset.raw[key] as? String { paths.append(path) }
            }
            if let camera = asset.cameraTrack?["sourcePath"] as? String { paths.append(camera) }
            for path in paths {
                if URL(fileURLWithPath: path).resolvingSymlinksInPath() == destination {
                    return true
                }
            }
        }
        return false
    }
}

public struct VideoDeliverySettings: Codable, Equatable, Sendable {
    public enum Codec: String, Codable, CaseIterable, Identifiable, Sendable {
        case h264, hevc, hevc10, proRes422, proRes422HQ, proRes4444

        public var id: String { rawValue }
        var title: String {
            switch self {
            case .h264: "H.264"
            case .hevc: "HEVC"
            case .hevc10: "HEVC Main 10"
            case .proRes422: "ProRes 422"
            case .proRes422HQ: "ProRes 422 HQ"
            case .proRes4444: "ProRes 4444"
            }
        }
        var native: AVVideoCodecType {
            switch self {
            case .h264: .h264
            case .hevc, .hevc10: .hevc
            case .proRes422: .proRes422
            case .proRes422HQ: .proRes422HQ
            case .proRes4444: .proRes4444
            }
        }
        var isMaster: Bool { [.proRes422, .proRes422HQ, .proRes4444].contains(self) }
        var highPrecision: Bool { isMaster || self == .hevc10 }
        public var fileExtension: String { isMaster ? "mov" : "mp4" }
    }

    public enum AudioCodec: String, Codable, CaseIterable, Sendable {
        case aac, pcm
    }

    public enum ColorSpace: String, Codable, CaseIterable, Sendable {
        case rec709, displayP3

        var primaries: String {
            self == .displayP3 ? AVVideoColorPrimaries_P3_D65 : AVVideoColorPrimaries_ITU_R_709_2
        }

        var transfer: String {
            self == .displayP3
                ? kCVImageBufferTransferFunction_sRGB as String
                : AVVideoTransferFunction_ITU_R_709_2
        }
    }

    public var codec: Codec = .h264
    public var bitRate: Int = 40_000_000
    public var keyFrameInterval: Int = 120
    public var audioCodec: AudioCodec = .aac
    public var audioBitRate: Int = 320_000
    public var audioSampleRate: Int = 48_000
    public var audioChannels: Int = 2
    public var requireHardware = false
    public var colorSpace: ColorSpace?

    public init() {}

    public static func master(_ codec: Codec = .proRes422HQ) -> Self {
        var settings = Self()
        settings.codec = codec
        settings.audioCodec = .pcm
        return settings
    }

    public func validate() throws {
        guard (100_000...1_000_000_000).contains(bitRate),
            (1...10_000).contains(keyFrameInterval),
            (32_000...320_000).contains(audioBitRate),
            [44_100, 48_000, 96_000].contains(audioSampleRate),
            (1...2).contains(audioChannels)
        else {
            throw VideoDeliveryError.invalidSettings("Invalid video or audio encoding settings.")
        }
        guard codec.isMaster || audioCodec == .aac else {
            throw VideoDeliveryError.invalidSettings(
                "PCM audio requires a QuickTime ProRes master.")
        }
        guard audioCodec != .aac || audioSampleRate != 96_000 else {
            throw VideoDeliveryError.invalidSettings("AAC delivery supports 44.1 or 48 kHz.")
        }
        guard audioCodec != .aac || audioChannels != 1 || audioBitRate <= 256_000 else {
            throw VideoDeliveryError.invalidSettings("Mono AAC supports at most 256 kbps.")
        }
        guard !requireHardware || !codec.isMaster else {
            throw VideoDeliveryError.invalidSettings(
                "Required hardware encoding is available for H.264 and HEVC delivery.")
        }
    }

    func videoSettings(size: CGSize, frameDuration: CMTime) -> [String: Any] {
        let color = colorSpace ?? .rec709
        var result: [String: Any] = [
            AVVideoCodecKey: codec.native,
            AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: color.primaries,
                AVVideoTransferFunctionKey: color.transfer,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ]
        if !codec.isMaster {
            var compression: [String: Any] = [
                AVVideoAverageBitRateKey: bitRate,
                AVVideoMaxKeyFrameIntervalKey: keyFrameInterval,
                AVVideoExpectedSourceFrameRateKey: 1 / frameDuration.seconds,
                AVVideoAllowFrameReorderingKey: true,
            ]
            if codec == .h264 {
                compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
            }
            if codec == .hevc10 {
                compression[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main10_AutoLevel
            }
            result[AVVideoCompressionPropertiesKey] = compression
            result[AVVideoEncoderSpecificationKey] = [
                kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: true,
                kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String:
                    requireHardware,
            ]
        }
        return result
    }

    var audioSettings: [String: Any] {
        var result: [String: Any] = [
            AVFormatIDKey: audioCodec == .aac ? kAudioFormatMPEG4AAC : kAudioFormatLinearPCM,
            AVSampleRateKey: audioSampleRate, AVNumberOfChannelsKey: audioChannels,
        ]
        if audioCodec == .aac {
            result[AVEncoderBitRateKey] = audioBitRate
        } else {
            result[AVLinearPCMBitDepthKey] = 24
            result[AVLinearPCMIsFloatKey] = false
            result[AVLinearPCMIsBigEndianKey] = false
            result[AVLinearPCMIsNonInterleaved] = false
        }
        return result
    }
}

enum VideoDeliveryError: LocalizedError {
    case invalidSettings(String), failed(String), destinationExists

    var errorDescription: String? {
        switch self {
        case .invalidSettings(let message), .failed(let message): message
        case .destinationExists:
            "The destination already exists. Choose another path or enable overwrite."
        }
    }
}

public struct VideoDeliveryReport: Codable, Sendable {
    public let width: Int
    public let height: Int
    public let duration: Double
    public let frameCount: Int
    public let frameRateNumerator: Int64
    public let frameRateDenominator: Int64
    public let videoCodec: String
    public let videoBitRate: Double
    public let bitsPerComponent: Int?
    public let colorPrimaries: String?
    public let transferFunction: String?
    public let audioCodec: String?
    public let audioSampleRate: Double?
    public let audioChannels: Int?
    public let bytes: Int64
    public let sha256: String
    public var range: VideoDeliveryRangeReport? = nil

    static func inspect(_ url: URL) async throws -> Self {
        let asset = AVURLAsset(url: url)
        guard let video = try await asset.loadTracks(withMediaType: .video).first else {
            throw VideoDeliveryError.failed("The exported file has no video track.")
        }
        let size = try await video.load(.naturalSize)
        let formats = try await video.load(.formatDescriptions)
        guard let format = formats.first else {
            throw VideoDeliveryError.failed("Missing video format.")
        }
        let extensions = CMFormatDescriptionGetExtensions(format) as NSDictionary? ?? [:]
        let duration = try await asset.load(.duration)
        let bitRate = try await video.load(.estimatedDataRate)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: video, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? VideoDeliveryError.failed("Could not verify video frames.")
        }
        var frameCount = 0
        let frameDuration = try await video.load(.minFrameDuration)
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            frameCount += CMSampleBufferGetNumSamples(sample)
        }
        guard reader.status == .completed else {
            throw reader.error ?? VideoDeliveryError.failed("Frame verification failed.")
        }
        var audioCodec: String?
        var sampleRate: Double?
        var channels: Int?
        if let audio = try await asset.loadTracks(withMediaType: .audio).first,
            let format = try await audio.load(.formatDescriptions).first,
            let description = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee
        {
            audioCodec = fourCC(description.mFormatID)
            sampleRate = description.mSampleRate
            channels = Int(description.mChannelsPerFrame)
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var bytes: Int64 = 0
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            try Task.checkCancellation()
            hasher.update(data: data)
            bytes += Int64(data.count)
        }
        var divisor = Int64(frameDuration.timescale)
        var remainder = frameDuration.isNumeric ? frameDuration.value : 0
        while remainder != 0 { (divisor, remainder) = (remainder, divisor % remainder) }
        divisor = max(1, divisor)
        let subtype = CMFormatDescriptionGetMediaSubType(format)
        let bits: Int? =
            [
                kCMVideoCodecType_AppleProRes422, kCMVideoCodecType_AppleProRes422HQ,
                kCMVideoCodecType_AppleProRes422LT, kCMVideoCodecType_AppleProRes422Proxy,
            ].contains(subtype)
            ? 10 : extensions[kCMFormatDescriptionExtension_BitsPerComponent] as? Int
        return Self(
            width: Int(size.width), height: Int(size.height), duration: duration.seconds,
            frameCount: frameCount,
            frameRateNumerator: frameDuration.isNumeric
                ? Int64(frameDuration.timescale) / divisor : 0,
            frameRateDenominator: frameDuration.isNumeric ? frameDuration.value / divisor : 0,
            videoCodec: fourCC(subtype),
            videoBitRate: Double(bitRate),
            bitsPerComponent: bits,
            colorPrimaries: extensions[kCMFormatDescriptionExtension_ColorPrimaries] as? String,
            transferFunction: extensions[kCMFormatDescriptionExtension_TransferFunction] as? String,
            audioCodec: audioCodec, audioSampleRate: sampleRate, audioChannels: channels,
            bytes: bytes, sha256: hasher.finalize().map { String(format: "%02x", $0) }.joined())
    }

    private static func fourCC(_ code: FourCharCode) -> String {
        String(bytes: [24, 16, 8, 0].map { UInt8((code >> $0) & 255) }, encoding: .ascii)
            ?? String(code)
    }
}

extension VideoRenderPipeline {
    func export(
        to destination: URL, settings: VideoDeliverySettings = .init(), overwrite: Bool = false,
        range: VideoDeliveryFrameRange? = nil,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> VideoDeliveryReport {
        var settings = settings
        let color =
            settings.colorSpace
            ?? (videoComposition.colorPrimaries == AVVideoColorPrimaries_P3_D65
                ? VideoDeliverySettings.ColorSpace.displayP3 : .rec709)
        settings.colorSpace = color
        try settings.validate()
        guard destination.isFileURL,
            destination.pathExtension.lowercased() == settings.codec.fileExtension
        else {
            throw VideoDeliveryError.invalidSettings(
                "Use a .\(settings.codec.fileExtension) destination for \(settings.codec.title).")
        }
        guard !FileManager.default.fileExists(atPath: destination.path) || overwrite else {
            throw VideoDeliveryError.destinationExists
        }
        let sources = composition.tracks.flatMap(\.segments).compactMap(\.sourceURL)
        guard
            !sources.contains(where: {
                $0.resolvingSymlinksInPath() == destination.resolvingSymlinksInPath()
            })
        else {
            throw VideoDeliveryError.invalidSettings("An export cannot replace its source media.")
        }
        guard duration.isFinite, duration > 0, canvas.width.isFinite, canvas.height.isFinite,
            (2...16_384).contains(canvas.width), (2...16_384).contains(canvas.height),
            canvas.width.rounded() == canvas.width, canvas.height.rounded() == canvas.height,
            videoComposition.frameDuration.isNumeric, videoComposition.frameDuration.seconds > 0
        else {
            throw VideoDeliveryError.invalidSettings(
                "The project needs a valid canvas, frame rate and duration.")
        }
        let selection = try VideoDeliverySelection(
            range, duration: composition.duration, frameDuration: videoComposition.frameDuration)
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(
            ".\(UUID().uuidString).partial.\(settings.codec.fileExtension)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let reader = try AVAssetReader(asset: composition)
        reader.timeRange = selection.timeRange
        let writer = try AVAssetWriter(
            outputURL: temporary, fileType: settings.codec.isMaster ? .mov : .mp4)
        writer.movieTimeScale =
            CMTimeAdd(videoComposition.frameDuration, composition.duration).timescale
        let videoTracks = try await composition.loadTracks(withMediaType: .video)
        let videoOutput = AVAssetReaderVideoCompositionOutput(
            videoTracks: videoTracks,
            videoSettings: [
                kCVPixelBufferPixelFormatTypeKey as String:
                    settings.codec.highPrecision
                    ? kCVPixelFormatType_64RGBAHalf : kCVPixelFormatType_32BGRA,
                AVVideoAllowWideColorKey: color == .displayP3,
            ])
        let deliveryComposition = videoComposition.mutableCopy() as! AVMutableVideoComposition
        deliveryComposition.colorPrimaries = color.primaries
        deliveryComposition.colorTransferFunction = color.transfer
        deliveryComposition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
        videoOutput.videoComposition = deliveryComposition
        videoOutput.alwaysCopiesSampleData = false
        let encoding = settings.videoSettings(
            size: canvas, frameDuration: videoComposition.frameDuration)
        guard writer.canApply(outputSettings: encoding, forMediaType: .video) else {
            throw VideoDeliveryError.invalidSettings(
                "This Mac cannot encode the requested video settings.")
        }
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: encoding)
        videoInput.expectsMediaDataInRealTime = false
        videoInput.mediaTimeScale = videoComposition.frameDuration.timescale
        guard reader.canAdd(videoOutput), writer.canAdd(videoInput) else {
            throw VideoDeliveryError.failed("Could not configure the native video encoder.")
        }
        reader.add(videoOutput)
        writer.add(videoInput)
        let audioTracks = try await composition.loadTracks(withMediaType: .audio)
        var audioOutput: AVAssetReaderAudioMixOutput?
        var audioInput: AVAssetWriterInput?
        if !audioTracks.isEmpty {
            let output = AVAssetReaderAudioMixOutput(
                audioTracks: audioTracks,
                audioSettings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: settings.audioSampleRate,
                    AVNumberOfChannelsKey: settings.audioChannels,
                    AVLinearPCMBitDepthKey: 32,
                    AVLinearPCMIsFloatKey: true,
                    AVLinearPCMIsNonInterleaved: false,
                ])
            output.audioMix = audioMix
            output.alwaysCopiesSampleData = false
            guard writer.canApply(outputSettings: settings.audioSettings, forMediaType: .audio)
            else {
                throw VideoDeliveryError.invalidSettings(
                    "This Mac cannot encode the requested audio settings.")
            }
            let input = AVAssetWriterInput(
                mediaType: .audio, outputSettings: settings.audioSettings)
            input.expectsMediaDataInRealTime = false
            guard reader.canAdd(output), writer.canAdd(input) else {
                throw VideoDeliveryError.failed("Could not configure the native audio encoder.")
            }
            reader.add(output)
            writer.add(input)
            audioOutput = output
            audioInput = input
        }
        do {
            try Task.checkCancellation()
            guard writer.startWriting() else {
                throw writer.error ?? VideoDeliveryError.failed("Could not start writing.")
            }
            writer.startSession(atSourceTime: selection.timeRange.start)
            guard reader.startReading() else {
                throw reader.error ?? VideoDeliveryError.failed("Could not start rendering.")
            }
            let finalAudioOutput = audioOutput
            let finalAudioInput = audioInput
            async let video: Void = Self.transfer(
                videoOutput, to: videoInput, reader: reader, writer: writer,
                timeRange: selection.timeRange,
                progress: progress)
            async let audio: Void = Self.transfer(
                finalAudioOutput, to: finalAudioInput, reader: reader, writer: writer,
                timeRange: selection.timeRange)
            try await video
            try await audio
            guard reader.status == .completed else {
                throw reader.error ?? VideoDeliveryError.failed("Rendering did not finish.")
            }
            writer.endSession(atSourceTime: selection.timeRange.end)
            await writer.finishWriting()
            try Task.checkCancellation()
            guard writer.status == .completed else {
                throw writer.error ?? VideoDeliveryError.failed("Encoding did not finish.")
            }
            var report = try await VideoDeliveryReport.inspect(temporary)
            report.range = selection.report
            guard report.frameCount == selection.frameCount, report.width == Int(canvas.width),
                report.height == Int(canvas.height)
            else {
                throw VideoDeliveryError.failed(
                    "Export verification did not match the project canvas or frame count.")
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
            writer.cancelWriting()
            throw error
        }
    }

    private static func transfer(
        _ output: AVAssetReaderOutput?, to input: AVAssetWriterInput?, reader: AVAssetReader,
        writer: AVAssetWriter, timeRange: CMTimeRange,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws {
        guard let output, let input else { return }
        var lastProgress = -1.0
        while true {
            try Task.checkCancellation()
            guard writer.status == .writing, reader.status != .failed else {
                throw writer.error ?? reader.error
                    ?? VideoDeliveryError.failed("The encoder stopped before completion.")
            }
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(2))
                guard writer.status == .writing, reader.status != .failed else {
                    throw writer.error ?? reader.error
                        ?? VideoDeliveryError.failed("The encoder stopped accepting frames.")
                }
            }
            guard let sample = output.copyNextSampleBuffer() else { break }
            guard input.append(sample) else {
                throw writer.error ?? VideoDeliveryError.failed("Could not encode a media sample.")
            }
            let fraction = min(
                0.99,
                max(
                    0,
                    (CMSampleBufferGetPresentationTimeStamp(sample) - timeRange.start).seconds
                        / timeRange.duration.seconds))
            if fraction - lastProgress >= 0.01 {
                progress(fraction)
                lastProgress = fraction
            }
        }
        input.markAsFinished()
    }
}
