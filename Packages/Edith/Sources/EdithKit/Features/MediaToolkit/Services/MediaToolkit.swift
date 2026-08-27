import AVFoundation
import CoreGraphics
import EdithCore
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum MediaImageFormat: String, CaseIterable, Codable, Identifiable, Sendable {
    case jpeg
    case png
    case heic

    public var id: String { rawValue }

    public var fileExtension: String {
        switch self {
        case .jpeg: "jpg"
        case .png: "png"
        case .heic: "heic"
        }
    }

    var type: UTType {
        switch self {
        case .jpeg: .jpeg
        case .png: .png
        case .heic: .heic
        }
    }
}

public struct MediaImageOptions: Equatable, Sendable {
    public var format: MediaImageFormat
    public var quality: Double
    public var maxDimension: Int?

    public init(format: MediaImageFormat, quality: Double = 0.82, maxDimension: Int? = 1600) {
        self.format = format
        self.quality = min(1, max(0.1, quality.isFinite ? quality : 0.82))
        self.maxDimension = maxDimension.map { min(20_000, max(1, $0)) }
    }
}

public struct MediaImageResult: Equatable, Sendable {
    public let inputURL: URL
    public let outputURL: URL?
    public let inputBytes: Int64
    public let outputBytes: Int64
    public let error: String?

    public init(
        inputURL: URL, outputURL: URL?, inputBytes: Int64, outputBytes: Int64,
        error: String?
    ) {
        self.inputURL = inputURL
        self.outputURL = outputURL
        self.inputBytes = inputBytes
        self.outputBytes = outputBytes
        self.error = error
    }
}

public struct MediaVideoOptions: Equatable, Sendable {
    public var targetMegabytes: Int
    public var keepAudio: Bool

    public init(targetMegabytes: Int = 20, keepAudio: Bool = true) {
        self.targetMegabytes = min(512, max(1, targetMegabytes))
        self.keepAudio = keepAudio
    }

    public var targetBytes: Int64 { Int64(targetMegabytes) * 1_000_000 }
}

public struct MediaVideoPlan: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public let videoBitRate: Int
    public let audioBitRate: Int

    public init(width: Int, height: Int, videoBitRate: Int, audioBitRate: Int) {
        self.width = width
        self.height = height
        self.videoBitRate = videoBitRate
        self.audioBitRate = audioBitRate
    }
}

public struct MediaVideoResult: Equatable, Sendable {
    public let inputURL: URL
    public let outputURL: URL
    public let inputBytes: Int64
    public let outputBytes: Int64
    public let targetBytes: Int64

    public init(
        inputURL: URL, outputURL: URL, inputBytes: Int64, outputBytes: Int64,
        targetBytes: Int64
    ) {
        self.inputURL = inputURL
        self.outputURL = outputURL
        self.inputBytes = inputBytes
        self.outputBytes = outputBytes
        self.targetBytes = targetBytes
    }
}

public enum MediaToolkitError: LocalizedError, Equatable {
    case noInput
    case unsupportedImage(String)
    case unsupportedVideo
    case invalidOutput
    case targetTooSmall
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .noInput: "Choose at least one input file."
        case let .unsupportedImage(name): "\(name) is not a supported image."
        case .unsupportedVideo: "The selected file does not contain a supported video track."
        case .invalidOutput: "The output location is not writable."
        case .targetTooSmall: "The target size is too small for the complete video."
        case let .failed(message): message
        }
    }
}

public enum MediaToolkitOperation: String, CaseIterable, Sendable {
    case convertImages = "convert-images"
    case compressVideo = "compress-video"

    public var descriptor: UserOperationDescriptor {
        switch self {
        case .convertImages:
            UserOperationDescriptor(
                id: UserOperationID(rawValue: "media.convert-images"),
                summary: "Convert and resize local images in a batch.",
                cli: ["media", rawValue], effect: .write)
        case .compressVideo:
            UserOperationDescriptor(
                id: UserOperationID(rawValue: "media.compress-video"),
                summary: "Compress a local video under a chosen size limit.",
                cli: ["media", rawValue], effect: .write)
        }
    }
}

public enum MediaToolkit {
    public static func convertImages(
        _ inputURLs: [URL], to outputDirectory: URL, options: MediaImageOptions,
        progress: @Sendable (Int, Int) -> Void = { _, _ in },
        cancelled: @Sendable () -> Bool = { false }
    ) throws -> [MediaImageResult] {
        guard !inputURLs.isEmpty else { throw MediaToolkitError.noInput }
        try FileManager.default.createDirectory(
            at: outputDirectory, withIntermediateDirectories: true)
        var results: [MediaImageResult] = []
        for (index, inputURL) in inputURLs.enumerated() {
            if cancelled() { throw CancellationError() }
            let inputBytes = fileSize(inputURL)
            do {
                let outputURL = uniqueOutputURL(
                    input: inputURL, directory: outputDirectory,
                    extension: options.format.fileExtension)
                try convertImage(inputURL, to: outputURL, options: options, cancelled: cancelled)
                results.append(
                    MediaImageResult(
                        inputURL: inputURL, outputURL: outputURL, inputBytes: inputBytes,
                        outputBytes: fileSize(outputURL), error: nil))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                results.append(
                    MediaImageResult(
                        inputURL: inputURL, outputURL: nil, inputBytes: inputBytes,
                        outputBytes: 0, error: error.localizedDescription))
            }
            progress(index + 1, inputURLs.count)
        }
        return results
    }

    public static func compressVideo(
        _ inputURL: URL, to outputDirectory: URL, options: MediaVideoOptions,
        progress: @Sendable (Double) -> Void = { _ in },
        cancelled: @Sendable () -> Bool = { false }
    ) async throws -> MediaVideoResult {
        try FileManager.default.createDirectory(
            at: outputDirectory, withIntermediateDirectories: true)
        let asset = AVURLAsset(url: inputURL)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw MediaToolkitError.unsupportedVideo
        }
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw MediaToolkitError.unsupportedVideo }
        let audioTracks =
            options.keepAudio ? try await asset.loadTracks(withMediaType: .audio) : []
        let naturalSize = try await videoTrack.load(.naturalSize)
        let preferredTransform = try await videoTrack.load(.preferredTransform)
        let nominalFrameRate = try await videoTrack.load(.nominalFrameRate)
        let transformed = naturalSize.applying(preferredTransform)
        let sourceSize = CGSize(width: abs(transformed.width), height: abs(transformed.height))
        let frameRate = max(1, Double(nominalFrameRate))
        let outputURL = uniqueOutputURL(
            input: inputURL, directory: outputDirectory, extension: "mp4")
        var scale = 1.0
        var outputBytes: Int64 = 0
        do {
            for pass in 0..<3 {
                guard !cancelled() else { throw CancellationError() }
                guard
                    let plan = videoPlan(
                        targetBytes: options.targetBytes, duration: duration,
                        sourceSize: sourceSize,
                        frameRate: frameRate, hasAudio: !audioTracks.isEmpty, scale: scale)
                else { throw MediaToolkitError.targetTooSmall }
                try encodeVideo(
                    asset: asset, videoTrack: videoTrack, audioTracks: audioTracks,
                    preferredTransform: preferredTransform, frameRate: frameRate,
                    duration: duration, plan: plan, outputURL: outputURL,
                    progress: progress, cancelled: cancelled)
                outputBytes = fileSize(outputURL)
                if outputBytes <= options.targetBytes { break }
                guard pass < 2 else { throw MediaToolkitError.targetTooSmall }
                scale *= min(
                    0.9, Double(options.targetBytes) / Double(max(1, outputBytes)) * 0.9)
            }
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
        return MediaVideoResult(
            inputURL: inputURL, outputURL: outputURL, inputBytes: fileSize(inputURL),
            outputBytes: outputBytes, targetBytes: options.targetBytes)
    }

    public static func videoPlan(
        targetBytes: Int64, duration: Double, sourceSize: CGSize, frameRate: Double,
        hasAudio: Bool, scale: Double = 1
    ) -> MediaVideoPlan? {
        guard targetBytes > 0, duration.isFinite, duration > 0,
            sourceSize.width.isFinite, sourceSize.height.isFinite,
            sourceSize.width > 0, sourceSize.height > 0, frameRate.isFinite, frameRate > 0,
            scale.isFinite, scale > 0
        else { return nil }
        let audioBitRate = hasAudio ? 96_000 : 0
        let totalBitRate = Int(Double(targetBytes * 8) * 0.9 / duration)
        let videoBitRate = Int(Double(totalBitRate - audioBitRate) * scale)
        guard videoBitRate >= 240_000 else { return nil }
        let dimensionScale = min(1, 1920 / max(sourceSize.width, sourceSize.height))
        let sourceWidth = even(Int((sourceSize.width * dimensionScale).rounded()))
        let sourceHeight = even(Int((sourceSize.height * dimensionScale).rounded()))
        let pixelBudget = Double(videoBitRate) / max(1, frameRate * 0.07)
        let pixelScale = min(1, sqrt(pixelBudget / Double(sourceWidth * sourceHeight)))
        let width = even(Int(Double(sourceWidth) * pixelScale))
        let height = even(Int(Double(sourceHeight) * pixelScale))
        return MediaVideoPlan(
            width: width, height: height, videoBitRate: videoBitRate,
            audioBitRate: audioBitRate)
    }

    private static func convertImage(
        _ inputURL: URL, to outputURL: URL, options: MediaImageOptions,
        cancelled: @Sendable () -> Bool
    ) throws {
        guard let source = CGImageSourceCreateWithURL(inputURL as CFURL, nil) else {
            throw MediaToolkitError.unsupportedImage(inputURL.lastPathComponent)
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let sourceWidth = properties?[kCGImagePropertyPixelWidth] as? Int ?? 1
        let sourceHeight = properties?[kCGImagePropertyPixelHeight] as? Int ?? 1
        let maxPixelSize = min(
            max(sourceWidth, sourceHeight), options.maxDimension ?? max(sourceWidth, sourceHeight))
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard
            let image = CGImageSourceCreateThumbnailAtIndex(
                source, 0, thumbnailOptions as CFDictionary)
        else { throw MediaToolkitError.unsupportedImage(inputURL.lastPathComponent) }
        if cancelled() { throw CancellationError() }
        let stagingURL = outputURL.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: stagingURL) }
        guard
            let destination = CGImageDestinationCreateWithURL(
                stagingURL as CFURL, options.format.type.identifier as CFString, 1, nil)
        else { throw MediaToolkitError.invalidOutput }
        CGImageDestinationAddImage(
            destination, image,
            [kCGImageDestinationLossyCompressionQuality: options.quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw MediaToolkitError.failed("The image encoder could not finish the file.")
        }
        if cancelled() { throw CancellationError() }
        try FileManager.default.moveItem(at: stagingURL, to: outputURL)
    }

    private static func encodeVideo(
        asset: AVAsset, videoTrack: AVAssetTrack, audioTracks: [AVAssetTrack],
        preferredTransform: CGAffineTransform, frameRate: Double, duration: Double,
        plan: MediaVideoPlan, outputURL: URL,
        progress: @Sendable (Double) -> Void, cancelled: @Sendable () -> Bool
    ) throws {
        try? FileManager.default.removeItem(at: outputURL)
        guard let reader = try? AVAssetReader(asset: asset),
            let writer = try? AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        else { throw MediaToolkitError.unsupportedVideo }
        writer.shouldOptimizeForNetworkUse = true
        let videoOutput = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ])
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else { throw MediaToolkitError.unsupportedVideo }
        reader.add(videoOutput)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: plan.width,
            AVVideoHeightKey: plan.height,
            AVVideoScalingModeKey: AVVideoScalingModeResizeAspect,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: plan.videoBitRate,
                AVVideoExpectedSourceFrameRateKey: max(1, Int(frameRate.rounded())),
                AVVideoMaxKeyFrameIntervalDurationKey: 4,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false
        videoInput.transform = preferredTransform
        guard writer.canAdd(videoInput) else { throw MediaToolkitError.unsupportedVideo }
        writer.add(videoInput)
        var audioOutput: AVAssetReaderAudioMixOutput?
        var audioInput: AVAssetWriterInput?
        if !audioTracks.isEmpty {
            let output = AVAssetReaderAudioMixOutput(
                audioTracks: audioTracks,
                audioSettings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVLinearPCMBitDepthKey: 32,
                    AVLinearPCMIsFloatKey: true,
                    AVLinearPCMIsNonInterleaved: false,
                    AVLinearPCMIsBigEndianKey: false,
                ])
            if reader.canAdd(output) {
                reader.add(output)
                audioOutput = output
                let input = AVAssetWriterInput(
                    mediaType: .audio,
                    outputSettings: [
                        AVFormatIDKey: kAudioFormatMPEG4AAC,
                        AVSampleRateKey: 48_000,
                        AVNumberOfChannelsKey: 2,
                        AVEncoderBitRateKey: plan.audioBitRate,
                    ])
                if writer.canAdd(input) {
                    writer.add(input)
                    audioInput = input
                }
            }
        }
        guard reader.startReading(), writer.startWriting() else {
            throw MediaToolkitError.failed(
                writer.error?.localizedDescription ?? "The video encoder could not start.")
        }
        writer.startSession(atSourceTime: .zero)
        var nextVideo = videoOutput.copyNextSampleBuffer()
        var nextAudio = audioOutput?.copyNextSampleBuffer()
        while nextVideo != nil || nextAudio != nil {
            if cancelled() {
                reader.cancelReading()
                writer.cancelWriting()
                throw CancellationError()
            }
            let videoTime = nextVideo.map(CMSampleBufferGetPresentationTimeStamp)
            let audioTime = nextAudio.map(CMSampleBufferGetPresentationTimeStamp)
            let videoFirst: Bool
            switch (videoTime, audioTime) {
            case let (video?, audio?): videoFirst = video <= audio
            case (_?, nil): videoFirst = true
            default: videoFirst = false
            }
            let acceptsVideo = nextVideo != nil && videoInput.isReadyForMoreMediaData
            let acceptsAudio = nextAudio != nil && audioInput?.isReadyForMoreMediaData == true
            if acceptsVideo, videoFirst || !acceptsAudio, let sample = nextVideo {
                guard videoInput.append(sample) else { throw writerFailure(writer) }
                let timestamp = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                progress(min(0.99, max(0, timestamp / duration)))
                nextVideo = videoOutput.copyNextSampleBuffer()
            } else if acceptsAudio, let input = audioInput, let sample = nextAudio {
                guard input.append(sample) else { throw writerFailure(writer) }
                nextAudio = audioOutput?.copyNextSampleBuffer()
            } else if nextAudio != nil, audioInput == nil {
                nextAudio = nil
            } else {
                guard writer.status == .writing else { throw writerFailure(writer) }
                Thread.sleep(forTimeInterval: 0.002)
            }
        }
        videoInput.markAsFinished()
        audioInput?.markAsFinished()
        guard reader.status != .failed else {
            throw MediaToolkitError.failed(
                reader.error?.localizedDescription ?? "The video could not be read.")
        }
        let semaphore = DispatchSemaphore(value: 0)
        writer.finishWriting { semaphore.signal() }
        while semaphore.wait(timeout: .now() + .milliseconds(50)) == .timedOut {
            if cancelled() {
                writer.cancelWriting()
                throw CancellationError()
            }
        }
        guard writer.status == .completed else { throw writerFailure(writer) }
        progress(1)
    }

    private static func writerFailure(_ writer: AVAssetWriter) -> MediaToolkitError {
        .failed(writer.error?.localizedDescription ?? "The video could not be encoded.")
    }

    private static func uniqueOutputURL(
        input: URL, directory: URL, extension fileExtension: String
    ) -> URL {
        let base = input.deletingPathExtension().lastPathComponent + "-converted"
        var candidate = directory.appendingPathComponent(base).appendingPathExtension(fileExtension)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base)-\(counter)")
                .appendingPathExtension(fileExtension)
            counter += 1
        }
        return candidate
    }

    private static func fileSize(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    private static func even(_ value: Int) -> Int {
        let positive = max(2, value)
        return positive.isMultiple(of: 2) ? positive : positive - 1
    }
}
