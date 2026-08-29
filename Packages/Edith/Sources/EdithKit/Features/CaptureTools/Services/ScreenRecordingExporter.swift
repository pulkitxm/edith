import AVFoundation
import AppKit
import ImageIO
import UniformTypeIdentifiers

public enum ScreenRecordingExportError: LocalizedError {
    case unreadableTake
    case emptyTimeline
    case unsupportedFormat
    case exportFailed
    case gifTooLong

    public var errorDescription: String? {
        switch self {
        case .unreadableTake: "The recording take could not be read."
        case .emptyTimeline: "Trim and cuts removed the entire recording."
        case .unsupportedFormat: "The requested export format is unavailable."
        case .exportFailed: "The finished recording could not be exported."
        case .gifTooLong: "GIF export is limited to 30 seconds."
        }
    }
}

public final class ScreenRecordingExporter: @unchecked Sendable {
    public var onProgress: (@Sendable (Double) -> Void)?
    private let lock = NSLock()
    private var activeSession: AVAssetExportSession?
    private var cancelled = false

    public init() {}

    public func cancel() {
        let session = lock.withLock { () -> AVAssetExportSession? in
            cancelled = true
            return activeSession
        }
        session?.cancelExport()
    }

    public func export(
        take: ScreenRecordingTake, document: ScreenRecordingEditDocument,
        to destination: URL, directory: URL? = nil
    ) async throws {
        lock.withLock { cancelled = false }
        let source = ScreenRecordingLibrary.masterURL(for: take.id, in: directory)
        let asset = AVURLAsset(url: source)
        let duration = try await asset.load(.duration).seconds
        let normalized = document.normalized(duration: duration)
        let ranges = normalized.keptRanges(duration: duration)
        guard !ranges.isEmpty else { throw ScreenRecordingExportError.emptyTimeline }
        let pointerTrack = Self.pointerTrack(take: take, directory: directory)
        let built = try await Self.composition(
            asset: asset, ranges: ranges, document: normalized,
            pointerTrack: pointerTrack)
        try? FileManager.default.removeItem(at: destination)
        switch normalized.preset.format {
        case .mp4:
            try await exportMP4(built, document: normalized, to: destination)
        case .gif:
            try await exportGIF(built, document: normalized, to: destination)
        }
    }

    private func exportMP4(
        _ built: BuiltComposition, document: ScreenRecordingEditDocument,
        to destination: URL
    ) async throws {
        guard
            let session = AVAssetExportSession(
                asset: built.asset, presetName: AVAssetExportPresetHighestQuality)
        else { throw ScreenRecordingExportError.unsupportedFormat }
        session.outputURL = destination
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true
        session.videoComposition = built.videoComposition
        session.audioMix = built.audioMix
        lock.withLock { activeSession = session }
        let progressTask = Task { [weak self, weak session] in
            while let self, let session, session.status == .waiting || session.status == .exporting
            {
                self.onProgress?(Double(session.progress))
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        await withCheckedContinuation { continuation in
            session.exportAsynchronously { continuation.resume() }
        }
        progressTask.cancel()
        lock.withLock { activeSession = nil }
        guard session.status == .completed, !lock.withLock({ cancelled }) else {
            try? FileManager.default.removeItem(at: destination)
            throw CancellationError()
        }
        onProgress?(1)
    }

    private func exportGIF(
        _ built: BuiltComposition, document: ScreenRecordingEditDocument,
        to destination: URL
    ) async throws {
        let duration = try await built.asset.load(.duration).seconds
        guard duration <= 30 else { throw ScreenRecordingExportError.gifTooLong }
        let fps = min(max(document.preset.frameRate, 5), 20)
        let count = max(1, Int((duration * Double(fps)).rounded(.up)))
        guard
            let destinationWriter = CGImageDestinationCreateWithURL(
                destination as CFURL, UTType.gif.identifier as CFString, count, nil)
        else { throw ScreenRecordingExportError.exportFailed }
        CGImageDestinationSetProperties(
            destinationWriter,
            [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let generator = AVAssetImageGenerator(asset: built.asset)
        generator.videoComposition = built.videoComposition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = built.videoComposition.renderSize
        let delay = 1 / Double(fps)
        let properties =
            [
                kCGImagePropertyGIFDictionary: [
                    kCGImagePropertyGIFDelayTime: delay,
                    kCGImagePropertyGIFUnclampedDelayTime: delay,
                ]
            ] as CFDictionary
        for index in 0..<count {
            guard !lock.withLock({ cancelled }) else {
                try? FileManager.default.removeItem(at: destination)
                throw CancellationError()
            }
            let seconds = min(duration, Double(index) / Double(fps))
            let result = try await generator.image(
                at: CMTime(seconds: seconds, preferredTimescale: 600))
            CGImageDestinationAddImage(destinationWriter, result.image, properties)
            onProgress?(Double(index + 1) / Double(count))
        }
        guard CGImageDestinationFinalize(destinationWriter) else {
            throw ScreenRecordingExportError.exportFailed
        }
    }

    private struct BuiltComposition {
        let asset: AVMutableComposition
        let videoComposition: AVMutableVideoComposition
        let audioMix: AVMutableAudioMix?
    }

    private static func composition(
        asset: AVAsset, ranges: [ScreenRecordingRange],
        document: ScreenRecordingEditDocument, pointerTrack: ScreenRecordingPointerTrack
    ) async throws -> BuiltComposition {
        guard let sourceVideo = try await asset.loadTracks(withMediaType: .video).first
        else { throw ScreenRecordingExportError.unreadableTake }
        let composition = AVMutableComposition()
        guard
            let videoTrack = composition.addMutableTrack(
                withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        else {
            throw ScreenRecordingExportError.unreadableTake
        }
        let sourceAudio = try await asset.loadTracks(withMediaType: .audio)
        let audioTracks = sourceAudio.compactMap { source -> AVMutableCompositionTrack? in
            guard
                let track = composition.addMutableTrack(
                    withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            else { return nil }
            return track
        }
        var outputCursor = CMTime.zero
        var mappings: [(source: ScreenRecordingRange, outputStart: Double)] = []
        for range in ranges {
            let start = CMTime(seconds: range.start, preferredTimescale: 600)
            let duration = CMTime(seconds: range.end - range.start, preferredTimescale: 600)
            let timeRange = CMTimeRange(start: start, duration: duration)
            try videoTrack.insertTimeRange(timeRange, of: sourceVideo, at: outputCursor)
            for (index, source) in sourceAudio.enumerated() where index < audioTracks.count {
                try? audioTracks[index].insertTimeRange(timeRange, of: source, at: outputCursor)
            }
            mappings.append((range, outputCursor.seconds))
            outputCursor = outputCursor + duration
        }
        let naturalSize = try await sourceVideo.load(.naturalSize)
        let preferredTransform = try await sourceVideo.load(.preferredTransform)
        let orientedBounds = CGRect(origin: .zero, size: naturalSize)
            .applying(preferredTransform).standardized
        let sourceSize = orientedBounds.size
        let crop = resolvedCrop(document.crop, sourceSize: sourceSize)
        let outputWidth = CGFloat(min(max(document.preset.width, 320), 3840))
        let contentScale = outputWidth / max(1, crop.width)
        let padding = CGFloat(document.padding) * 2
        let renderSize = even(
            CGSize(
                width: outputWidth + padding,
                height: crop.height * contentScale + padding))
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: outputCursor)
        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
        var transform = preferredTransform
        transform = transform.concatenating(
            CGAffineTransform(translationX: -orientedBounds.minX, y: -orientedBounds.minY))
        transform = transform.concatenating(
            CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
        transform = transform.concatenating(
            CGAffineTransform(scaleX: contentScale, y: contentScale))
        transform = transform.concatenating(
            CGAffineTransform(translationX: CGFloat(document.padding), y: CGFloat(document.padding))
        )
        layerInstruction.setTransform(transform, at: .zero)
        instruction.layerInstructions = [layerInstruction]
        let videoComposition = AVMutableVideoComposition()
        videoComposition.instructions = [instruction]
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(
            value: 1, timescale: CMTimeScale(min(max(document.preset.frameRate, 15), 60)))
        let parent = CALayer()
        parent.frame = CGRect(origin: .zero, size: renderSize)
        parent.backgroundColor = color(document.backgroundHex ?? "#111827").cgColor
        let videoLayer = CALayer()
        videoLayer.frame = parent.bounds
        parent.addSublayer(videoLayer)
        addZooms(document.zooms, mappings: mappings, duration: outputCursor.seconds, to: videoLayer)
        addTexts(document.texts, mappings: mappings, duration: outputCursor.seconds, to: parent)
        if document.showsPointer {
            addPointer(
                pointerTrack, document: document, mappings: mappings,
                duration: outputCursor.seconds, size: renderSize, to: parent)
        }
        videoComposition.animationTool = AVVideoCompositionCoreAnimationTool(
            postProcessingAsVideoLayer: videoLayer, in: parent)
        let audioMix = makeAudioMix(
            audioTracks, systemVolume: document.systemAudioVolume,
            microphoneVolume: document.microphoneVolume)
        return BuiltComposition(
            asset: composition, videoComposition: videoComposition, audioMix: audioMix)
    }

    private static func resolvedCrop(_ crop: CGRect?, sourceSize: CGSize) -> CGRect {
        guard var crop else { return CGRect(origin: .zero, size: sourceSize) }
        if crop.maxX <= 1, crop.maxY <= 1 {
            crop = CGRect(
                x: crop.minX * sourceSize.width, y: crop.minY * sourceSize.height,
                width: crop.width * sourceSize.width, height: crop.height * sourceSize.height)
        }
        return crop.intersection(CGRect(origin: .zero, size: sourceSize))
    }

    private static func makeAudioMix(
        _ tracks: [AVMutableCompositionTrack], systemVolume: Double,
        microphoneVolume: Double
    ) -> AVMutableAudioMix? {
        guard !tracks.isEmpty else { return nil }
        let parameters = tracks.enumerated().map { index, track in
            let value = index == 0 ? systemVolume : microphoneVolume
            let input = AVMutableAudioMixInputParameters(track: track)
            input.setVolume(Float(min(max(value, 0), 2)), at: .zero)
            return input
        }
        let mix = AVMutableAudioMix()
        mix.inputParameters = parameters
        return mix
    }

    private static func addPointer(
        _ track: ScreenRecordingPointerTrack, document: ScreenRecordingEditDocument,
        mappings: [(source: ScreenRecordingRange, outputStart: Double)],
        duration: Double, size: CGSize, to parent: CALayer
    ) {
        let mapped = ScreenRecordingTimeline.smoothed(
            track.points, amount: document.pointerSmoothing
        ).compactMap { point -> (Double, CGPoint)? in
            guard let time = outputTime(point.time, mappings: mappings) else { return nil }
            return (time, CGPoint(x: point.x * size.width, y: point.y * size.height))
        }
        guard mapped.count > 1, duration > 0 else { return }
        let pointer = CALayer()
        let side = CGFloat(22 * document.pointerScale)
        pointer.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        pointer.cornerRadius = side / 2
        pointer.backgroundColor = NSColor.white.cgColor
        pointer.borderColor = NSColor.systemYellow.cgColor
        pointer.borderWidth = max(2, side / 7)
        pointer.shadowColor = NSColor.black.cgColor
        pointer.shadowOpacity = 0.5
        pointer.shadowRadius = 3
        let animation = CAKeyframeAnimation(keyPath: "position")
        animation.values = mapped.map { NSValue(point: $0.1) }
        animation.keyTimes = mapped.map { NSNumber(value: min(max($0.0 / duration, 0), 1)) }
        animation.duration = duration
        animation.beginTime = AVCoreAnimationBeginTimeAtZero
        animation.isRemovedOnCompletion = false
        animation.fillMode = .forwards
        pointer.add(animation, forKey: "pointer")
        parent.addSublayer(pointer)
        if document.showsClickMarkers {
            for click in track.clicks {
                guard let time = outputTime(click.time, mappings: mappings) else { continue }
                let ring = CALayer()
                ring.bounds = CGRect(x: 0, y: 0, width: 32, height: 32)
                ring.position = CGPoint(x: click.x * size.width, y: click.y * size.height)
                ring.cornerRadius = 16
                ring.borderColor = NSColor.systemYellow.cgColor
                ring.borderWidth = 4
                ring.opacity = 0
                let opacity = CAKeyframeAnimation(keyPath: "opacity")
                opacity.values = [0, 1, 0]
                opacity.keyTimes = [0, 0.2, 1]
                opacity.beginTime = AVCoreAnimationBeginTimeAtZero + time
                opacity.duration = 0.5
                ring.add(opacity, forKey: "click")
                parent.addSublayer(ring)
            }
        }
    }

    private static func addZooms(
        _ zooms: [ScreenRecordingZoom],
        mappings: [(source: ScreenRecordingRange, outputStart: Double)],
        duration: Double, to layer: CALayer
    ) {
        guard duration > 0 else { return }
        var times: [NSNumber] = [0]
        var values: [CATransform3D] = [CATransform3DIdentity]
        for zoom in zooms {
            guard let start = outputTime(zoom.start, mappings: mappings),
                let end = outputTime(zoom.end, mappings: mappings), end > start
            else { continue }
            let scale = CGFloat(min(max(zoom.scale, 1), 3))
            times += [
                NSNumber(value: start / duration),
                NSNumber(value: min(end, start + 0.25) / duration),
                NSNumber(value: max(start, end - 0.25) / duration),
                NSNumber(value: end / duration),
            ]
            values += [
                CATransform3DIdentity, CATransform3DMakeScale(scale, scale, 1),
                CATransform3DMakeScale(scale, scale, 1), CATransform3DIdentity,
            ]
        }
        guard times.count > 1 else { return }
        let animation = CAKeyframeAnimation(keyPath: "transform")
        animation.keyTimes = times
        animation.values = values.map { NSValue(caTransform3D: $0) }
        animation.duration = duration
        animation.beginTime = AVCoreAnimationBeginTimeAtZero
        animation.isRemovedOnCompletion = false
        layer.add(animation, forKey: "zooms")
    }

    private static func addTexts(
        _ texts: [ScreenRecordingTextOverlay],
        mappings: [(source: ScreenRecordingRange, outputStart: Double)],
        duration: Double, to parent: CALayer
    ) {
        guard duration > 0 else { return }
        for text in texts {
            guard let start = outputTime(text.start, mappings: mappings),
                let end = outputTime(text.end, mappings: mappings), end > start,
                !text.text.isEmpty
            else { continue }
            let layer = CATextLayer()
            layer.string = text.text
            layer.alignmentMode = .center
            layer.fontSize = CGFloat(min(max(text.fontSize, 10), 160))
            layer.foregroundColor = color(text.colorHex).cgColor
            layer.shadowColor = NSColor.black.cgColor
            layer.shadowOpacity = 0.7
            layer.shadowRadius = 3
            layer.contentsScale = 2
            layer.frame = CGRect(
                x: parent.bounds.width * CGFloat(text.x) - 260,
                y: parent.bounds.height * CGFloat(text.y) - 40,
                width: 520, height: 80)
            layer.opacity = 0
            let opacity = CAKeyframeAnimation(keyPath: "opacity")
            opacity.values = [0, 1, 1, 0]
            opacity.keyTimes = [0, 0.05, 0.95, 1]
            opacity.beginTime = AVCoreAnimationBeginTimeAtZero + start
            opacity.duration = end - start
            layer.add(opacity, forKey: "visibility")
            parent.addSublayer(layer)
        }
    }

    private static func outputTime(
        _ sourceTime: Double,
        mappings: [(source: ScreenRecordingRange, outputStart: Double)]
    ) -> Double? {
        guard
            let mapping = mappings.first(where: {
                sourceTime >= $0.source.start && sourceTime <= $0.source.end
            })
        else { return nil }
        return mapping.outputStart + sourceTime - mapping.source.start
    }

    private static func pointerTrack(
        take: ScreenRecordingTake, directory: URL?
    ) -> ScreenRecordingPointerTrack {
        let url = ScreenRecordingLibrary.pointerURL(for: take.id, in: directory)
        guard let data = try? Data(contentsOf: url),
            let track = try? JSONDecoder().decode(ScreenRecordingPointerTrack.self, from: data)
        else { return ScreenRecordingPointerTrack() }
        return track
    }

    private static func even(_ size: CGSize) -> CGSize {
        CGSize(
            width: max(2, floor(size.width / 2) * 2),
            height: max(2, floor(size.height / 2) * 2))
    }

    private static func color(_ value: String) -> NSColor {
        let raw = value.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard raw.count == 6, let number = Int(raw, radix: 16) else { return .white }
        return NSColor(
            red: CGFloat((number >> 16) & 255) / 255,
            green: CGFloat((number >> 8) & 255) / 255,
            blue: CGFloat(number & 255) / 255, alpha: 1)
    }
}
