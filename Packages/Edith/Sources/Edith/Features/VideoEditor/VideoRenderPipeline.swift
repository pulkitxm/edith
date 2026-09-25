import AVFoundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers

enum ZoomAnimation {
    struct State {
        let scale: Double
        let x: Double
        let y: Double

        static let identity = State(scale: 1, x: 0.5, y: 0.5)
    }

    private static func ease(_ fraction: Double) -> Double {
        let value = min(1, max(0, fraction))
        return value * value * (3 - 2 * value)
    }

    private static func mix(_ from: State, _ to: State, fraction: Double) -> State {
        let weight = ease(fraction)
        return State(
            scale: from.scale + (to.scale - from.scale) * weight,
            x: from.x + (to.x - from.x) * weight,
            y: from.y + (to.y - from.y) * weight)
    }

    static func sample(
        at timeMs: Double, zooms: [VideoProject.Zoom], cursor: CGPoint? = nil
    ) -> State {
        let ordered = zooms.sorted { $0.startMs < $1.startMs }
        func state(_ zoom: VideoProject.Zoom) -> State {
            let automatic = zoom.raw["focusMode"] as? String == "auto"
            return State(
                scale: [1.25, 1.5, 1.8, 2.2, 3.5, 5.0][max(0, min(5, zoom.depth - 1))],
                x: automatic ? cursor.map { Double($0.x) } ?? zoom.focusX : zoom.focusX,
                y: automatic ? cursor.map { Double($0.y) } ?? zoom.focusY : zoom.focusY)
        }
        func half(_ zoom: VideoProject.Zoom) -> Double {
            min(250, max(0, zoom.endMs - zoom.startMs) / 4)
        }
        func connected(_ left: VideoProject.Zoom, _ right: VideoProject.Zoom) -> Bool {
            let gap = right.startMs - left.endMs
            return abs(gap) <= half(left) + half(right)
        }
        func between(_ left: VideoProject.Zoom, _ right: VideoProject.Zoom) -> State? {
            let beginning = left.endMs - half(left)
            let ending = right.startMs + half(right)
            guard ending > beginning, timeMs >= beginning, timeMs <= ending else { return nil }
            return mix(
                state(left), state(right),
                fraction: (timeMs - beginning) / (ending - beginning))
        }
        for index in ordered.indices {
            let zoom = ordered[index]
            let previous = index > 0 ? ordered[index - 1] : nil
            let next = index + 1 < ordered.count ? ordered[index + 1] : nil
            let margin = half(zoom)
            if let previous, connected(previous, zoom) {
                if let blended = between(previous, zoom) { return blended }
            } else if margin > 0, timeMs >= zoom.startMs - margin,
                timeMs <= zoom.startMs + margin
            {
                return mix(
                    .identity, state(zoom),
                    fraction: (timeMs - zoom.startMs + margin) / (2 * margin))
            }
            if let next, connected(zoom, next) {
                if let blended = between(zoom, next) { return blended }
            } else if margin > 0, timeMs >= zoom.endMs - margin,
                timeMs <= zoom.endMs + margin
            {
                return mix(
                    state(zoom), .identity,
                    fraction: (timeMs - zoom.endMs + margin) / (2 * margin))
            }
            if timeMs >= zoom.startMs && timeMs <= zoom.endMs { return state(zoom) }
        }
        return .identity
    }
}

struct VideoRenderPipeline {
    private struct CursorSample: Sendable {
        let timeMs: Double
        let x: Double
        let y: Double
        let visible: Bool
        let click: Bool
    }

    private static func cursorSamples(for url: URL) -> [CursorSample] {
        let sidecar = URL(fileURLWithPath: url.path + ".cursor.json")
        guard let data = try? Data(contentsOf: sidecar),
            let document = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let samples = document["samples"] as? [[String: Any]]
        else { return [] }
        return samples.compactMap { sample -> CursorSample? in
            guard let time = (sample["timeMs"] as? NSNumber)?.doubleValue,
                let x = (sample["cx"] as? NSNumber)?.doubleValue,
                let y = (sample["cy"] as? NSNumber)?.doubleValue,
                time.isFinite, x.isFinite, y.isFinite
            else { return nil }
            let interaction = sample["interactionType"] as? String ?? ""
            return CursorSample(
                timeMs: time, x: min(1, max(0, x)),
                y: min(1, max(0, y)),
                visible: sample["visible"] as? Bool ?? true,
                click: interaction.contains("click"))
        }.sorted { $0.timeMs < $1.timeMs }
    }

    private static func cursorSample(
        at timeMs: Double, in samples: [CursorSample]
    ) -> (current: CursorSample?, clicked: Bool) {
        var low = 0
        var high = samples.count
        while low < high {
            let middle = (low + high) / 2
            if samples[middle].timeMs <= timeMs { low = middle + 1 } else { high = middle }
        }
        guard low > 0 else { return (nil, false) }
        let current = samples[low - 1]
        var index = low - 1
        var clicked = false
        while index >= 0 && timeMs - samples[index].timeMs <= 300 {
            if samples[index].click { clicked = true; break }
            index -= 1
        }
        return (timeMs - current.timeMs <= 150 ? current : nil, clicked)
    }

    private final class CameraFrameSource {
        let generator: AVAssetImageGenerator
        let offset: Double
        private let lock = NSLock()
        private var lastFrameIndex = -1
        private var lastImage: CIImage?

        init(url: URL, offset: Double) {
            generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            self.offset = offset
        }

        func frame(at sourceTime: Double) -> CIImage? {
            let time = sourceTime - offset
            guard time >= 0 else { return nil }
            let frameIndex = Int(time * 30)
            lock.lock()
            defer { lock.unlock() }
            if lastFrameIndex == frameIndex { return lastImage }
            let image = try? generator.copyCGImage(
                at: CMTime(seconds: time, preferredTimescale: 600), actualTime: nil)
            lastFrameIndex = frameIndex
            lastImage = image.map(CIImage.init(cgImage:))
            return lastImage
        }
    }

    struct Segment {
        let clip: VideoProject.Clip
        let sourceStart: Double
        let sourceEnd: Double
        let rate: Double
        let outputStart: Double
        let outputDuration: Double
        var outputEnd: Double { outputStart + outputDuration }
        func sourceTime(at outputTime: Double) -> Double {
            sourceStart + (outputTime - outputStart) * rate
        }
        func rulerTime(at outputTime: Double) -> Double {
            clip.timelineStart + sourceTime(at: outputTime) - clip.start
        }
    }

    private struct TransitionEdge {
        let time: Double
        let halfDuration: Double
        let kind: String
    }

    let composition: AVMutableComposition
    let videoComposition: AVVideoComposition
    let audioMix: AVAudioMix?
    let segments: [Segment]
    let canvas: CGSize

    var duration: Double { segments.last?.outputEnd ?? 0 }

    static func make(
        project: VideoProject, maxDimension: Int? = nil
    ) async throws -> VideoRenderPipeline {
        let composition = AVMutableComposition()
        guard
            let video = composition.addMutableTrack(
                withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw RenderError.noVideo }
        var audio: AVMutableCompositionTrack?

        var segments: [Segment] = []
        var frameGenerators: [String: AVAssetImageGenerator] = [:]
        var cameras: [String: CameraFrameSource] = [:]
        var cursors: [String: [CursorSample]] = [:]
        var cursor = 0.0
        var firstSize: CGSize?
        var firstFrameRate: Float?
        for clip in project.clips where clip.duration > 0 {
            guard let source = project.assets.first(where: { $0.id == clip.assetID }) else {
                throw RenderError.missingAsset(clip.assetID)
            }
            guard FileManager.default.fileExists(atPath: source.url.path) else {
                throw RenderError.missingAsset(source.url.path)
            }
            let asset = AVURLAsset(url: source.url)
            if cursors[clip.assetID] == nil {
                cursors[clip.assetID] = cursorSamples(for: source.url)
            }
            if let camera = source.cameraTrack,
                camera["visible"] as? Bool != false,
                let cameraPath = camera["sourcePath"] as? String,
                FileManager.default.fileExists(atPath: cameraPath),
                cameras[clip.assetID] == nil
            {
                let start = (camera["startMs"] as? NSNumber)?.doubleValue ?? 0
                let offset = (camera["offsetMs"] as? NSNumber)?.doubleValue ?? 0
                cameras[clip.assetID] = CameraFrameSource(
                    url: URL(fileURLWithPath: cameraPath), offset: (start + offset) / 1000)
            }
            if frameGenerators[clip.assetID] == nil {
                frameGenerators[clip.assetID] = AVAssetImageGenerator(asset: asset)
            }
            guard let sourceVideo = try await asset.loadTracks(withMediaType: .video).first else {
                throw RenderError.noVideo
            }
            let naturalSize = try await sourceVideo.load(.naturalSize)
            let preferredTransform = try await sourceVideo.load(.preferredTransform)
            if firstSize == nil {
                let transformed = naturalSize.applying(preferredTransform)
                firstSize = CGSize(width: abs(transformed.width), height: abs(transformed.height))
                firstFrameRate = try await sourceVideo.load(.nominalFrameRate)
                video.preferredTransform = preferredTransform
            }
            let sourceAudio = try await asset.loadTracks(withMediaType: .audio).first
            for slice in speedSlices(
                for: clip, regions: project.speedRegions, trims: project.trimRanges
            ) {
                let sourceRange = CMTimeRange(
                    start: CMTime(seconds: slice.start, preferredTimescale: 600),
                    duration: CMTime(seconds: slice.end - slice.start, preferredTimescale: 600))
                let insertion = CMTime(seconds: cursor, preferredTimescale: 600)
                try video.insertTimeRange(sourceRange, of: sourceVideo, at: insertion)
                if let sourceAudio {
                    if audio == nil {
                        audio = composition.addMutableTrack(
                            withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
                    }
                    try audio?.insertTimeRange(sourceRange, of: sourceAudio, at: insertion)
                }
                let outputDuration = (slice.end - slice.start) / slice.rate
                if slice.rate != 1 {
                    let inserted = CMTimeRange(start: insertion, duration: sourceRange.duration)
                    let scaled = CMTime(seconds: outputDuration, preferredTimescale: 600)
                    video.scaleTimeRange(inserted, toDuration: scaled)
                    audio?.scaleTimeRange(inserted, toDuration: scaled)
                }
                segments.append(
                    Segment(
                        clip: clip, sourceStart: slice.start, sourceEnd: slice.end,
                        rate: slice.rate, outputStart: cursor, outputDuration: outputDuration))
                cursor += outputDuration
            }
        }
        guard !segments.isEmpty, let firstSize else { throw RenderError.noVideo }
        let transitions = transitionEdges(project: project, segments: segments)

        let mix = AVMutableAudioMix()
        var parameters: [AVMutableAudioMixInputParameters] = []
        for track in project.audioTracks where !track.muted && track.endMs > track.startMs {
            guard let source = project.assets.first(where: { $0.id == track.assetID }) else {
                throw RenderError.missingAsset(track.assetID)
            }
            guard FileManager.default.fileExists(atPath: source.url.path) else {
                throw RenderError.missingAsset(source.url.path)
            }
            let asset = AVURLAsset(url: source.url)
            guard let sourceAudio = try await asset.loadTracks(withMediaType: .audio).first,
                let mixTrack = composition.addMutableTrack(
                    withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            else { continue }
            let sourceDuration = try await asset.load(.duration).seconds
            let start = outputTime(for: track.startMs / 1000, segments: segments)
            let end = outputTime(for: track.endMs / 1000, segments: segments)
            for segment in segments {
                let rulerStart =
                    segment.clip.timelineStart + segment.sourceStart - segment.clip.start
                let rulerEnd = segment.clip.timelineStart + segment.sourceEnd - segment.clip.start
                let overlapStart = max(track.startMs / 1000, rulerStart)
                let overlapEnd = min(track.endMs / 1000, rulerEnd)
                guard overlapEnd > overlapStart else { continue }
                var cursor = segment.outputStart + (overlapStart - rulerStart) / segment.rate
                let outputEnd = segment.outputStart + (overlapEnd - rulerStart) / segment.rate
                var offset = track.offsetMs / 1000 + overlapStart - track.startMs / 1000
                if track.loop, sourceDuration > 0 {
                    offset.formTruncatingRemainder(dividingBy: sourceDuration)
                }
                while cursor < outputEnd - 0.001 && sourceDuration > offset {
                    let length = min(outputEnd - cursor, sourceDuration - offset)
                    let range = CMTimeRange(
                        start: CMTime(seconds: offset, preferredTimescale: 600),
                        duration: CMTime(seconds: length, preferredTimescale: 600))
                    try mixTrack.insertTimeRange(
                        range, of: sourceAudio,
                        at: CMTime(seconds: cursor, preferredTimescale: 600))
                    cursor += length
                    if !track.loop { break }
                    offset = 0
                }
            }
            let level = Float(pow(10, track.gainDb / 20))
            let input = AVMutableAudioMixInputParameters(track: mixTrack)
            let fadeIn =
                min(
                    (track.raw["fadeInMs"] as? NSNumber)?.doubleValue ?? 0,
                    (end - start) * 500) / 1000
            let fadeOut =
                min(
                    (track.raw["fadeOutMs"] as? NSNumber)?.doubleValue ?? 0,
                    (end - start) * 500) / 1000
            let startTime = CMTime(seconds: start, preferredTimescale: 600)
            input.setVolume(fadeIn > 0 ? 0 : level, at: startTime)
            if fadeIn > 0 {
                input.setVolumeRamp(
                    fromStartVolume: 0, toEndVolume: level,
                    timeRange: CMTimeRange(
                        start: startTime,
                        duration: CMTime(seconds: fadeIn, preferredTimescale: 600)))
            }
            if fadeOut > 0 {
                input.setVolumeRamp(
                    fromStartVolume: level, toEndVolume: 0,
                    timeRange: CMTimeRange(
                        start: CMTime(seconds: end - fadeOut, preferredTimescale: 600),
                        duration: CMTime(seconds: fadeOut, preferredTimescale: 600)))
            }
            parameters.append(input)
        }
        if let audio, !parameters.isEmpty || !transitions.isEmpty {
            let input = AVMutableAudioMixInputParameters(track: audio)
            for edge in transitions {
                let half = CMTime(seconds: edge.halfDuration, preferredTimescale: 600)
                let midpoint = CMTime(seconds: edge.time, preferredTimescale: 600)
                input.setVolumeRamp(
                    fromStartVolume: 1, toEndVolume: 0,
                    timeRange: CMTimeRange(start: midpoint - half, duration: half))
                input.setVolumeRamp(
                    fromStartVolume: 0, toEndVolume: 1,
                    timeRange: CMTimeRange(start: midpoint, duration: half))
            }
            parameters.append(input)
        }
        mix.inputParameters = parameters

        let nativeCanvas = canvasSize(for: firstSize, ratio: project.aspectRatio)
        let canvas: CGSize
        if let maxDimension, maxDimension > 0,
            max(nativeCanvas.width, nativeCanvas.height) > CGFloat(maxDimension)
        {
            let factor = CGFloat(maxDimension) / max(nativeCanvas.width, nativeCanvas.height)
            canvas = CGSize(
                width: max(2, Int(nativeCanvas.width * factor) / 2 * 2),
                height: max(2, Int(nativeCanvas.height * factor) / 2 * 2))
        } else {
            canvas = nativeCanvas
        }
        let background = CIColor(hex: project.backgroundColor)
        let wallpaper = CIImage(contentsOf: URL(fileURLWithPath: project.backgroundColor))
        let padding = CGFloat(project.padding / 100)
        let zooms = project.zooms
        let annotations = project.annotations
        let cameraFullscreenRegions = project.cameraFullscreenRegions
        let finalSegments = segments
        let finalGenerators = frameGenerators
        let finalCameras = cameras
        let finalCursors = cursors
        let generatorLock = NSLock()
        let size = canvas
        let baseComposition = AVVideoComposition(asset: composition) { request in
            let time = request.compositionTime.seconds
            guard let segment = finalSegments.last(where: { $0.outputStart <= time }) else {
                request.finish(with: request.sourceImage, context: nil)
                return
            }
            var sourceImage = request.sourceImage
            if sourceImage.extent.isInfinite || sourceImage.extent.isEmpty
                || sourceImage.extent.isNull
            {
                guard let generator = finalGenerators[segment.clip.assetID] else {
                    request.finish(with: RenderError.noVideo)
                    return
                }
                generatorLock.lock()
                let frame = try? generator.copyCGImage(
                    at: CMTime(seconds: segment.sourceTime(at: time), preferredTimescale: 600),
                    actualTime: nil)
                generatorLock.unlock()
                guard let frame else {
                    request.finish(
                        with: RenderError.exportFailed(
                            "Could not decode the source frame at \(time)s"))
                    return
                }
                sourceImage = CIImage(cgImage: frame)
            }
            let rulerMs = segment.rulerTime(at: time) * 1000
            let cursor = cursorSample(
                at: segment.sourceTime(at: time) * 1000,
                in: finalCursors[segment.clip.assetID] ?? [])
            let webcam = finalCameras[segment.clip.assetID]?.frame(
                at: segment.sourceTime(at: time))
            var image = render(
                sourceImage, clip: segment.clip, at: rulerMs, size: size,
                zooms: zooms, annotations: annotations, background: background,
                wallpaper: wallpaper, padding: padding,
                webcam: webcam, webcamLayout: project.webcamLayout,
                webcamSize: project.webcamSize,
                webcamPosition: project.webcamPosition,
                webcamMask: project.webcamMaskShape,
                webcamMirrored: project.webcamMirrored,
                cameraFullscreenRegions: cameraFullscreenRegions,
                cursor: cursor.current,
                cursorClicked: project.cursorHighlight && cursor.clicked)
            if let edge = transitions.first(where: {
                abs(time - $0.time) < $0.halfDuration
            }) {
                let opacity = 1 - abs(time - edge.time) / edge.halfDuration
                let color = CIColor(
                    red: edge.kind == "flash" ? 1 : 0,
                    green: edge.kind == "flash" ? 1 : 0,
                    blue: edge.kind == "flash" ? 1 : 0)
                let overlay = CIImage(color: color).cropped(to: image.extent)
                image = image.applyingFilter(
                    "CIDissolveTransition",
                    parameters: [
                        kCIInputTargetImageKey: overlay, kCIInputTimeKey: opacity,
                    ])
            }
            guard !image.extent.isEmpty, !image.extent.isNull else {
                request.finish(with: RenderError.exportFailed("The rendered video frame is empty"))
                return
            }
            request.finish(with: image, context: nil)
        }
        let videoComposition = baseComposition.mutableCopy() as! AVMutableVideoComposition
        videoComposition.renderSize = canvas
        let frameRate = Double(firstFrameRate ?? 30)
        videoComposition.frameDuration = CMTime(
            seconds: 1 / (frameRate.isFinite && frameRate > 0 ? frameRate : 30),
            preferredTimescale: 60_000)
        return VideoRenderPipeline(
            composition: composition, videoComposition: videoComposition,
            audioMix: parameters.isEmpty ? nil : mix,
            segments: segments, canvas: canvas)
    }

    private static func transitionEdges(
        project: VideoProject, segments: [Segment]
    ) -> [TransitionEdge] {
        guard segments.count > 1 else { return [] }
        return segments.indices.dropFirst().compactMap { index in
            let incoming = segments[index]
            let outgoing = segments[index - 1]
            guard incoming.clip.id != outgoing.clip.id,
                let transition = project.transitions.first(where: {
                    $0.clipID == incoming.clip.id
                })
            else { return nil }
            let outgoingDuration = segments[..<index].reversed()
                .prefix { $0.clip.id == outgoing.clip.id }
                .reduce(0) { $0 + $1.outputDuration }
            let incomingDuration = segments[index...]
                .prefix { $0.clip.id == incoming.clip.id }
                .reduce(0) { $0 + $1.outputDuration }
            let half = min(
                transition.duration / 2, outgoingDuration / 2, incomingDuration / 2)
            guard half > 0 else { return nil }
            return TransitionEdge(
                time: incoming.outputStart, halfDuration: half, kind: transition.kind)
        }
    }

    private static func outputTime(for rulerTime: Double, segments: [Segment]) -> Double {
        guard
            let segment = segments.first(where: {
                rulerTime < $0.clip.timelineStart + $0.sourceEnd - $0.clip.start
            })
        else { return segments.last?.outputEnd ?? 0 }
        let source = segment.clip.start + rulerTime - segment.clip.timelineStart
        return min(
            segment.outputEnd,
            max(
                segment.outputStart,
                segment.outputStart + (source - segment.sourceStart) / segment.rate))
    }

    private static func speedSlices(
        for clip: VideoProject.Clip, regions: [[String: Any]], trims: [[String: Any]]
    ) -> [(start: Double, end: Double, rate: Double)] {
        let applicable = regions.compactMap { region -> (Double, Double, Double)? in
            if let id = region["clipId"] as? String, id != clip.id { return nil }
            let sourceStart =
                region["sourceStartSec"] as? Double
                ?? (region["startMs"] as? Double ?? 0) / 1000 - clip.timelineStart + clip.start
            let sourceEnd =
                region["sourceEndSec"] as? Double
                ?? (region["endMs"] as? Double ?? 0) / 1000 - clip.timelineStart + clip.start
            guard sourceEnd > clip.start, sourceStart < clip.end,
                let rate = (region["speed"] as? NSNumber)?.doubleValue,
                rate.isFinite, rate > 0
            else { return nil }
            return (max(clip.start, sourceStart), min(clip.end, sourceEnd), rate)
        }
        let excluded = trims.compactMap { trim -> (Double, Double)? in
            if let clipID = trim["clipId"] as? String {
                guard clipID == clip.id else { return nil }
            } else {
                guard trim["assetId"] as? String == clip.assetID else { return nil }
            }
            guard let start = (trim["startSec"] as? NSNumber)?.doubleValue,
                let end = (trim["endSec"] as? NSNumber)?.doubleValue,
                end > clip.start, start < clip.end
            else { return nil }
            return (max(start, clip.start), min(end, clip.end))
        }
        let boundaries = Array(
            Set(
                [clip.start, clip.end]
                    + applicable.flatMap { [$0.0, $0.1] }
                    + excluded.flatMap { [$0.0, $0.1] })
        ).sorted()
        return zip(boundaries, boundaries.dropFirst()).compactMap { start, end in
            guard end > start else { return nil }
            guard !excluded.contains(where: { $0.0 <= start && $0.1 >= end }) else {
                return nil
            }
            let rate = applicable.first { $0.0 <= start && $0.1 >= end }?.2 ?? 1
            return (start, end, max(0.25, min(5, rate)))
        }
    }

    private static func canvasSize(for source: CGSize, ratio: String) -> CGSize {
        let proportions = ratio.split(separator: ":").compactMap { Double($0) }
        guard proportions.count == 2, proportions[0] > 0, proportions[1] > 0 else {
            return CGSize(
                width: max(2, Int(source.width) / 2 * 2),
                height: max(2, Int(source.height) / 2 * 2))
        }
        let desired = proportions[0] / proportions[1]
        let width = desired >= 1 ? source.width : source.height * desired
        let height = desired >= 1 ? source.width / desired : source.height
        return CGSize(
            width: max(2, Int(width) / 2 * 2),
            height: max(2, Int(height) / 2 * 2))
    }

    func exportMP4(to url: URL, quality: String = "good") async throws {
        let preset =
            quality == "medium"
            ? AVAssetExportPresetMediumQuality
            : AVAssetExportPresetHighestQuality
        guard
            let session = AVAssetExportSession(
                asset: composition, presetName: preset)
        else { throw RenderError.exportFailed("Could not create an export session") }
        session.videoComposition = videoComposition
        session.audioMix = audioMix
        session.outputURL = url
        session.outputFileType = .mp4
        try? FileManager.default.removeItem(at: url)
        await withCheckedContinuation { continuation in
            session.exportAsynchronously { continuation.resume() }
        }
        guard session.status == .completed else {
            throw session.error ?? RenderError.exportFailed("MP4 export failed")
        }
    }

    func exportGIF(
        to url: URL, fps: Int = 15, maxWidth: Int = 0, loop: Bool = true
    ) throws {
        guard
            let destination = CGImageDestinationCreateWithURL(
                url as CFURL, UTType.gif.identifier as CFString,
                max(1, Int(ceil(duration * Double(fps)))), nil)
        else { throw RenderError.exportFailed("Could not create a GIF") }
        let generator = AVAssetImageGenerator(asset: composition)
        generator.videoComposition = videoComposition
        generator.appliesPreferredTrackTransform = true
        if maxWidth > 0, canvas.width > CGFloat(maxWidth) {
            let factor = CGFloat(maxWidth) / canvas.width
            generator.maximumSize = CGSize(
                width: CGFloat(maxWidth), height: max(1, canvas.height * factor))
        }
        let count = max(1, Int(ceil(duration * Double(fps))))
        for index in 0..<count {
            let time = CMTime(seconds: Double(index) / Double(fps), preferredTimescale: 600)
            let image = try generator.copyCGImage(at: time, actualTime: nil)
            let properties: [CFString: Any] = [
                kCGImagePropertyGIFDictionary: [
                    kCGImagePropertyGIFDelayTime: 1.0 / Double(fps)
                ]
            ]
            CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        }
        CGImageDestinationSetProperties(
            destination,
            [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: loop ? 0 : 1]
            ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw RenderError.exportFailed("Could not finish GIF export")
        }
    }

    private static func render(
        _ input: CIImage, clip: VideoProject.Clip, at timeMs: Double, size: CGSize,
        zooms: [VideoProject.Zoom], annotations: [VideoProject.Annotation],
        background: CIColor, wallpaper: CIImage?, padding: CGFloat,
        webcam: CIImage?, webcamLayout: String, webcamSize: Double,
        webcamPosition: [String: Double], webcamMask: String, webcamMirrored: Bool,
        cameraFullscreenRegions: [[String: Any]],
        cursor: CursorSample?, cursorClicked: Bool
    ) -> CIImage {
        let bounds = CGRect(origin: .zero, size: size)
        let full = input.extent
        let cropped: CIImage
        if let crop = clip.crop {
            let area = CGRect(
                x: full.minX + full.width * (crop["x"] ?? 0),
                y: full.minY + full.height * (1 - (crop["y"] ?? 0) - (crop["height"] ?? 1)),
                width: full.width * (crop["width"] ?? 1),
                height: full.height * (crop["height"] ?? 1))
            cropped = input.cropped(to: area.intersection(full))
        } else {
            cropped = input
        }
        let source = cropped.extent
        let fit =
            min(size.width / source.width, size.height / source.height)
            * (1 - 2 * padding)
        let zoom = ZoomAnimation.sample(
            at: timeMs, zooms: zooms,
            cursor: cursor.map { CGPoint(x: $0.x, y: $0.y) })
        let scale: CGFloat = fit * CGFloat(zoom.scale)
        let focusFractionX = zoom.x
        let focusFractionY = 1 - zoom.y
        let focusX: CGFloat = source.width * CGFloat(focusFractionX)
        let focusY: CGFloat = source.height * CGFloat(focusFractionY)
        let transform = CGAffineTransform(scaleX: scale, y: scale)
            .concatenating(
                CGAffineTransform(
                    translationX: size.width / 2 - focusX * scale,
                    y: size.height / 2 - focusY * scale))
        let image = cropped.transformed(
            by: CGAffineTransform(
                translationX: -source.minX, y: -source.minY)
        ).transformed(by: transform)
        var backdrop = CIImage(color: background).cropped(to: bounds)
        if let wallpaper, wallpaper.extent.width > 0, wallpaper.extent.height > 0 {
            let fill = max(
                size.width / wallpaper.extent.width,
                size.height / wallpaper.extent.height)
            let scaled = wallpaper.transformed(by: CGAffineTransform(scaleX: fill, y: fill))
            backdrop = scaled.transformed(
                by: CGAffineTransform(
                    translationX: (size.width - scaled.extent.width) / 2 - scaled.extent.minX,
                    y: (size.height - scaled.extent.height) / 2 - scaled.extent.minY)
            )
            .cropped(to: bounds)
        }
        var output = image.composited(over: backdrop)
            .cropped(to: bounds)
        if let webcam, webcamLayout != "no-webcam", webcam.extent.width > 0,
            webcam.extent.height > 0
        {
            let targetWidth = size.width * CGFloat(webcamSize / 100)
            let targetHeight = targetWidth * webcam.extent.height / webcam.extent.width
            let x = size.width * CGFloat(webcamPosition["cx"] ?? 0.84) - targetWidth / 2
            let y =
                size.height * (1 - CGFloat(webcamPosition["cy"] ?? 0.8))
                - targetHeight / 2
            let local = webcam.transformed(
                by: CGAffineTransform(
                    translationX: -webcam.extent.minX, y: -webcam.extent.minY))
            let flip =
                webcamMirrored
                ? CGAffineTransform(
                    a: -1, b: 0, c: 0, d: 1,
                    tx: webcam.extent.width, ty: 0)
                : .identity
            let scaled = local.transformed(by: flip).transformed(
                by: CGAffineTransform(
                    scaleX: targetWidth / webcam.extent.width,
                    y: targetHeight / webcam.extent.height)
            )
            .transformed(by: CGAffineTransform(translationX: x, y: y))
            let cameraRect = CGRect(x: x, y: y, width: targetWidth, height: targetHeight)
            if webcamMask == "circle",
                let circle = CIFilter(
                    name: "CIRadialGradient",
                    parameters: [
                        "inputCenter": CIVector(x: cameraRect.midX, y: cameraRect.midY),
                        "inputRadius0": min(targetWidth, targetHeight) / 2 - 1,
                        "inputRadius1": min(targetWidth, targetHeight) / 2 + 1,
                        "inputColor0": CIColor.white,
                        "inputColor1": CIColor.black,
                    ])?.outputImage
            {
                output = scaled.applyingFilter(
                    "CIBlendWithMask",
                    parameters: [
                        kCIInputBackgroundImageKey: output,
                        kCIInputMaskImageKey: circle,
                    ]
                ).cropped(to: bounds)
            } else if webcamMask == "square" || webcamMask == "rounded" {
                let maskRect: CGRect
                if webcamMask == "square" {
                    let side = min(targetWidth, targetHeight)
                    maskRect = CGRect(
                        x: cameraRect.midX - side / 2, y: cameraRect.midY - side / 2,
                        width: side, height: side)
                } else {
                    maskRect = cameraRect
                }
                let white: CIImage?
                if webcamMask == "rounded" {
                    white =
                        CIFilter(
                            name: "CIRoundedRectangleGenerator",
                            parameters: [
                                "inputExtent": CIVector(cgRect: maskRect),
                                "inputRadius": min(maskRect.width, maskRect.height) * 0.12,
                                "inputColor": CIColor.white,
                            ])?.outputImage
                } else {
                    white = CIImage(color: .white).cropped(to: maskRect)
                }
                if let white {
                    let mask = white.composited(over: CIImage(color: .black).cropped(to: bounds))
                        .cropped(to: bounds)
                    output = scaled.applyingFilter(
                        "CIBlendWithMask",
                        parameters: [
                            kCIInputBackgroundImageKey: output,
                            kCIInputMaskImageKey: mask,
                        ]
                    ).cropped(to: bounds)
                }
            } else {
                output = scaled.cropped(to: cameraRect).composited(over: output)
                    .cropped(to: bounds)
            }
        }
        if let webcam, webcam.extent.width > 0, webcam.extent.height > 0 {
            let fullscreenAmount = cameraFullscreenRegions.reduce(0.0) { amount, region in
                if let clipID = region["clipId"] as? String, clipID != clip.id { return amount }
                guard let start = (region["startMs"] as? NSNumber)?.doubleValue,
                    let end = (region["endMs"] as? NSNumber)?.doubleValue,
                    end > start
                else { return amount }
                let entering = min(1, max(0, (timeMs - start + 250) / 250))
                let leaving = min(1, max(0, (end + 250 - timeMs) / 250))
                let strength = min(entering, leaving)
                return max(amount, strength * strength * (3 - 2 * strength))
            }
            if fullscreenAmount > 0 {
                let scale = max(
                    size.width / webcam.extent.width,
                    size.height / webcam.extent.height)
                let source = webcam.transformed(
                    by: CGAffineTransform(
                        translationX: -webcam.extent.minX, y: -webcam.extent.minY))
                let flipped =
                    webcamMirrored
                    ? source.transformed(
                        by: CGAffineTransform(
                            a: -1, b: 0, c: 0, d: 1, tx: webcam.extent.width, ty: 0))
                    : source
                let scaled = flipped.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                let camera = scaled.transformed(
                    by: CGAffineTransform(
                        translationX: (size.width - scaled.extent.width) / 2 - scaled.extent.minX,
                        y: (size.height - scaled.extent.height) / 2 - scaled.extent.minY)
                )
                .cropped(to: bounds)
                let foreground = camera.applyingFilter(
                    "CIColorMatrix",
                    parameters: [
                        "inputAVector": CIVector(x: 0, y: 0, z: 0, w: fullscreenAmount)
                    ])
                output = foreground.composited(over: output).cropped(to: bounds)
            }
        }
        if cursorClicked, let cursor, cursor.visible {
            let location = CIVector(
                x: (full.width * CGFloat(cursor.x) - source.minX) * scale
                    + size.width / 2 - focusX * scale,
                y: (full.height * (1 - CGFloat(cursor.y)) - source.minY) * scale
                    + size.height / 2 - focusY * scale)
            if let halo = CIFilter(
                name: "CIRadialGradient",
                parameters: [
                    "inputCenter": location,
                    "inputRadius0": max(2, size.width / 120),
                    "inputRadius1": max(8, size.width / 40),
                    "inputColor0": CIColor(red: 1, green: 0.7, blue: 0.1, alpha: 0.8),
                    "inputColor1": CIColor(red: 1, green: 0.7, blue: 0.1, alpha: 0),
                ])?.outputImage
            {
                output = halo.composited(over: output).cropped(to: bounds)
            }
        }
        for annotation in annotations
        where timeMs >= annotation.startMs && timeMs <= annotation.endMs {
            let position = annotation.raw["position"] as? [String: Double] ?? [:]
            let proportions = annotation.raw["size"] as? [String: Double] ?? [:]
            let centerX = size.width * (position["x"] ?? 50) / 100
            let centerY = size.height * (1 - (position["y"] ?? 80) / 100)
            let region = CGRect(
                x: centerX - size.width * (proportions["width"] ?? 30) / 200,
                y: centerY - size.height * (proportions["height"] ?? 20) / 200,
                width: size.width * (proportions["width"] ?? 30) / 100,
                height: size.height * (proportions["height"] ?? 20) / 100)
            switch annotation.type {
            case "blur":
                let settings = annotation.raw["blurData"] as? [String: Any] ?? [:]
                let mosaic = settings["type"] as? String == "mosaic"
                let filtered = CIFilter(
                    name: mosaic ? "CIPixellate" : "CIGaussianBlur",
                    parameters: [
                        kCIInputImageKey: output,
                        mosaic ? "inputScale" : kCIInputRadiusKey:
                            settings[mosaic ? "blockSize" : "intensity"] as? Double ?? 16,
                    ])?.outputImage?.cropped(to: region)
                if let filtered { output = filtered.composited(over: output).cropped(to: bounds) }
            case "image":
                let content =
                    annotation.raw["imageContent"] as? String
                    ?? annotation.raw["content"] as? String ?? ""
                let picture: CIImage?
                if content.hasPrefix("data:"),
                    let data = Data(base64Encoded: String(content.split(separator: ",").last ?? ""))
                {
                    picture = CIImage(data: data)
                } else {
                    picture = CIImage(contentsOf: URL(fileURLWithPath: content))
                }
                if let picture, picture.extent.width > 0, picture.extent.height > 0 {
                    let scaled = picture.transformed(
                        by: CGAffineTransform(
                            scaleX: region.width / picture.extent.width,
                            y: region.height / picture.extent.height))
                    output = scaled.transformed(
                        by: CGAffineTransform(
                            translationX: region.minX - scaled.extent.minX,
                            y: region.minY - scaled.extent.minY)
                    )
                    .composited(over: output).cropped(to: bounds)
                }
            case "figure":
                let figure = annotation.raw["figureData"] as? [String: Any] ?? [:]
                let color = CIColor(hex: figure["color"] as? String ?? "#34B27B")
                if let line = arrowImage(size: size, region: region, color: color) {
                    output = line.composited(over: output).cropped(to: bounds)
                }
            default:
                let style = annotation.raw["style"] as? [String: Any] ?? [:]
                let requestedSize = (style["fontSize"] as? NSNumber)?.doubleValue ?? 32
                let fontSize =
                    max(18, size.width / 40)
                    * CGFloat(
                        min(4, max(0.5, requestedSize / 32)))
                guard !annotation.text.isEmpty,
                    let text = CIFilter(
                        name: "CITextImageGenerator",
                        parameters: [
                            "inputText": annotation.text,
                            "inputFontName": "HelveticaNeue-Bold",
                            "inputFontSize": fontSize,
                            "inputScaleFactor": 1,
                        ])?.outputImage
                else { continue }
                let x = centerX - text.extent.width / 2
                let y = centerY - text.extent.height / 2
                let plate = style["backgroundColor"] as? String ?? "transparent"
                if plate != "transparent" {
                    let padding = max(4, size.width / 160)
                    let area = CGRect(
                        x: x - padding, y: y - padding,
                        width: text.extent.width + padding * 2,
                        height: text.extent.height + padding * 2)
                    output = CIImage(color: CIColor(hex: plate)).cropped(to: area)
                        .composited(over: output).cropped(to: bounds)
                }
                let color = CIColor(hex: style["color"] as? String ?? "#FFFFFF")
                let tinted = text.applyingFilter(
                    "CIColorMatrix",
                    parameters: [
                        "inputRVector": CIVector(x: 0, y: 0, z: 0, w: color.red),
                        "inputGVector": CIVector(x: 0, y: 0, z: 0, w: color.green),
                        "inputBVector": CIVector(x: 0, y: 0, z: 0, w: color.blue),
                        "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                    ])
                output = tinted.transformed(by: CGAffineTransform(translationX: x, y: y))
                    .composited(over: output).cropped(to: bounds)
            }
        }
        return output
    }

    private static func arrowImage(size: CGSize, region: CGRect, color: CIColor) -> CIImage? {
        guard
            let context = CGContext(
                data: nil, width: Int(size.width), height: Int(size.height),
                bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.setStrokeColor(
            CGColor(
                red: color.red, green: color.green, blue: color.blue, alpha: 1))
        context.setLineWidth(max(2, size.width / 300))
        context.move(to: CGPoint(x: region.minX, y: region.midY))
        context.addLine(to: CGPoint(x: region.maxX, y: region.midY))
        context.move(
            to: CGPoint(
                x: region.maxX - region.width * 0.22,
                y: region.midY + region.height * 0.3))
        context.addLine(to: CGPoint(x: region.maxX, y: region.midY))
        context.addLine(
            to: CGPoint(
                x: region.maxX - region.width * 0.22,
                y: region.midY - region.height * 0.3))
        context.strokePath()
        guard let bitmap = context.makeImage() else { return nil }
        return CIImage(cgImage: bitmap)
    }

    enum RenderError: LocalizedError {
        case noVideo
        case missingAsset(String)
        case exportFailed(String)

        var errorDescription: String? {
            switch self {
            case .noVideo: "Add a video to the timeline first."
            case .missingAsset(let path): "Video file is missing: \(path)"
            case .exportFailed(let message): message
            }
        }
    }
}

private extension CIColor {
    convenience init(hex: String) {
        let value =
            Int(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0x171b25
        self.init(
            red: CGFloat((value >> 16) & 255) / 255,
            green: CGFloat((value >> 8) & 255) / 255,
            blue: CGFloat(value & 255) / 255, alpha: 1)
    }
}
