@preconcurrency import AVFoundation
import CoreImage

extension VideoEditorService {
    public struct ReviewBorderSegment: Codable, Sendable {
        public let segmentIndex: Int
        public let clipID: String
        public let status: ReviewStatus
        public let reason: String?
        public let checkedFrames: [Int64]
        public let unexpectedBorderFrames: [Int64]
        public let uncoveredCanvasFrames: [Int64]
        public let intentionalPresentation: [String]
    }

    public struct ReviewBorders: Codable, Sendable {
        public let status: ReviewStatus
        public let coverage: String
        public let totalFrames: Int64?
        public let checkedFrameCount: Int
        public let mandatorySamplesComplete: Bool
        public let segments: [ReviewBorderSegment]
    }

    static func reviewBorders(project: VideoProject, pipeline: VideoRenderPipeline?, limit: Int)
        async throws -> ReviewBorders
    {
        guard let pipeline else {
            return ReviewBorders(
                status: .notAssessed, coverage: "unavailable", totalFrames: nil,
                checkedFrameCount: 0, mandatorySamplesComplete: false, segments: [])
        }
        let cadence = pipeline.videoComposition.frameDuration
        let zooms = project.zooms
        let total = reviewFrameCeiling(pipeline.composition.duration, frameDuration: cadence)
        var cursors: [String: [VideoRenderPipeline.CursorSample]] = [:]
        for asset in project.assets {
            cursors[asset.id] = VideoRenderPipeline.cursorSamples(for: asset.url)
        }
        let selection = borderFrames(
            project: project, pipeline: pipeline, cursors: cursors, total: total, limit: limit)
        var extentCache: [String: CGRect] = [:]
        var failures: [String: String] = [:]
        var results: [ReviewBorderSegment] = []
        var selectedIndex = 0
        for (index, segment) in pipeline.segments.enumerated() {
            try Task.checkCancellation()
            let start = reviewFrameCeiling(segment.outputRange.start, frameDuration: cadence)
            let end = reviewFrameCeiling(segment.outputRange.end, frameDuration: cadence)
            let first = selectedIndex
            while selectedIndex < selection.frames.count && selection.frames[selectedIndex] < end {
                selectedIndex += 1
            }
            let frames = Array(selection.frames[first..<selectedIndex]).filter { $0 >= start }
            let asset = project.assets.first { $0.id == segment.clip.assetID }!
            let effects = segment.clip.visualEffects
            var flags = [
                "framing_\(effects.framing.rawValue)",
                "background_\(project.backgroundColor.hasPrefix("#") ? "color" : "image")",
            ]
            if project.padding > 0 { flags.append("padding") }
            if project.presentation.cornerRadius > 0 { flags.append("rounded_corners") }
            if project.presentation.shadow > 0 { flags.append("shadow") }
            var reason: String?
            let cameraRegions = project.cameraFullscreenRegions.contains {
                ($0["clipId"] as? String).map { $0 == segment.clip.id } ?? true
            }
            if (asset.cameraTrack != nil && asset.cameraTrack?["visible"] as? Bool != false
                && project.webcamLayout != "no-webcam") || cameraRegions
            {
                reason = "Webcam composite geometry is not assessed."
            } else if frames.isEmpty {
                reason = "No output frames in this segment were selected."
            }
            if extentCache[asset.id] == nil && failures[asset.id] == nil && reason == nil {
                do {
                    if asset.isStill {
                        extentCache[asset.id] = try VideoStillMedia.image(at: asset.url).extent
                    } else {
                        let media = AVURLAsset(url: asset.url)
                        guard let track = try await media.loadTracks(withMediaType: .video).first
                        else {
                            throw Failure("unsupported_media", "No source video track.")
                        }
                        let natural = try await track.load(.naturalSize)
                        let preferred = try await track.load(.preferredTransform)
                        let generator = AVAssetImageGenerator(asset: media)
                        let decoded = try await generator.image(
                            at: CMTime(seconds: segment.sourceStart, preferredTimescale: 60000)
                        ).image
                        let extent = CGRect(
                            x: 0, y: 0, width: decoded.width, height: decoded.height)
                        extentCache[asset.id] = extent.applying(
                            VideoSourceGeometry.orientation(size: natural, preferred: preferred))
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    failures[asset.id] = error.localizedDescription
                }
            }
            reason = reason ?? failures[asset.id]
            var unexpected: [Int64] = []
            var uncovered: [Int64] = []
            if let extent = extentCache[asset.id], reason == nil {
                for frame in frames {
                    try Task.checkCancellation()
                    let time = CMTime(value: frame * cadence.value, timescale: cadence.timescale)
                        .seconds
                    let cursor = VideoRenderPipeline.cursorSample(
                        at: segment.sourceTime(at: time) * 1000, in: cursors[asset.id] ?? []
                    ).current
                    let geometry = VideoSourceGeometry(
                        extent: extent, clip: segment.clip, effects: effects,
                        timeMs: segment.rulerTime(at: time) * 1000, canvas: pipeline.canvas,
                        padding: CGFloat(project.padding / 100), zooms: zooms,
                        cursor: cursor.map { CGPoint(x: $0.x, y: $0.y) })
                    if !geometry.covers(CGRect(origin: .zero, size: pipeline.canvas)) {
                        uncovered.append(frame)
                    }
                    let intended = geometry.intendedRegion(
                        effects: effects, canvas: pipeline.canvas,
                        padding: CGFloat(project.padding / 100))
                    if !geometry.covers(intended) { unexpected.append(frame) }
                }
            }
            let assessed = reason == nil ? frames : []
            let status: ReviewStatus =
                reason != nil
                ? .notAssessed
                : !unexpected.isEmpty
                    ? .failed : Int64(assessed.count) == end - start ? .passed : .sampled
            results.append(
                ReviewBorderSegment(
                    segmentIndex: index, clipID: segment.clip.id, status: status, reason: reason,
                    checkedFrames: assessed, unexpectedBorderFrames: unexpected,
                    uncoveredCanvasFrames: uncovered, intentionalPresentation: flags))
        }
        let status: ReviewStatus =
            results.contains { $0.status == .failed }
            ? .failed
            : results.contains { $0.status == .notAssessed }
                ? .notAssessed : Int64(selection.frames.count) < total ? .sampled : .passed
        let checked = results.reduce(0) { $0 + $1.checkedFrames.count }
        let unknown = results.contains { $0.status == .notAssessed }
        return ReviewBorders(
            status: status,
            coverage: Int64(checked) == total
                ? "all_frames" : checked == 0 ? "unavailable" : unknown ? "partial" : "sampled",
            totalFrames: total,
            checkedFrameCount: checked,
            mandatorySamplesComplete: selection.complete && !unknown, segments: results)
    }

    private static func borderFrames(
        project: VideoProject, pipeline: VideoRenderPipeline,
        cursors: [String: [VideoRenderPipeline.CursorSample]], total: Int64, limit: Int
    ) -> (frames: [Int64], complete: Bool) {
        if total <= limit { return (Array(0..<total), true) }
        let cadence = pipeline.videoComposition.frameDuration
        var mandatory = Set<Int64>()
        for segment in pipeline.segments {
            let start = reviewFrameCeiling(segment.outputRange.start, frameDuration: cadence)
            let end = reviewFrameCeiling(segment.outputRange.end, frameDuration: cadence)
            guard end > start else { continue }
            mandatory.insert(start)
            mandatory.insert(end - 1)
            func addSource(_ source: Double) {
                guard source >= segment.sourceStart && source <= segment.sourceEnd else { return }
                let time = segment.outputStart + (source - segment.sourceStart) / segment.rate
                let frame = reviewFrameCeiling(
                    CMTime(seconds: time, preferredTimescale: cadence.timescale),
                    frameDuration: cadence)
                for candidate in (frame - 1)...(frame + 1)
                where candidate >= start && candidate < end {
                    mandatory.insert(candidate)
                }
            }
            for key in segment.clip.visualEffects.keyframes { addSource(key.time) }
            for sample in cursors[segment.clip.assetID] ?? [] {
                addSource(sample.timeMs / 1000)
                addSource((sample.timeMs + 150) / 1000)
            }
            for zoom in project.zooms {
                let half = min(250, max(0, zoom.endMs - zoom.startMs) / 4)
                for rulerMs in [
                    zoom.startMs - half, zoom.startMs, zoom.startMs + half, zoom.endMs - half,
                    zoom.endMs, zoom.endMs + half,
                ] {
                    addSource(segment.clip.start + rulerMs / 1000 - segment.clip.timelineStart)
                }
            }
        }
        let ordered = mandatory.sorted()
        if ordered.count > limit {
            return ((0..<limit).map { ordered[$0 * (ordered.count - 1) / (limit - 1)] }, false)
        }
        var selected = mandatory
        for index in 0..<limit where selected.count < limit {
            selected.insert(Int64(index) * (total - 1) / Int64(limit - 1))
        }
        return (selected.sorted(), true)
    }
}
