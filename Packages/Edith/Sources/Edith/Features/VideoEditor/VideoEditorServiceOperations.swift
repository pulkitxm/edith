@preconcurrency import AVFoundation
import Foundation

extension VideoEditorService {
    static func apply(
        _ operation: VideoEditPlan.Operation, project: inout VideoProject,
        aliases: inout [String: String], audioAliases: inout [String: [String]], directory: URL
    ) async throws {
        func clip(_ reference: String) throws -> VideoProject.Clip {
            let id = aliases[reference] ?? reference
            guard let clip = project.clips.first(where: { $0.id == id }) else {
                throw Failure("not_found", "Unknown clip: \(reference)")
            }
            return clip
        }
        func newName(_ name: String) throws {
            try require(
                !name.isEmpty && name.count <= 100 && aliases[name] == nil
                    && audioAliases[name] == nil
                    && !project.clips.contains { $0.id == name }
                    && !project.audioTracks.contains { $0.id == name },
                "Clip alias must be unique and contain 1 to 100 characters.")
        }
        func range(_ start: Double, _ end: Double) throws {
            let duration = project.clips.last.map { $0.timelineStart + $0.duration } ?? 0
            try require(
                start.isFinite && end.isFinite && start >= 0 && end > start && end <= duration,
                "Range must be inside the source-time timeline.")
        }
        func gain(_ value: Double) throws {
            try require(
                value.isFinite && (-60...12).contains(value), "Gain must be between -60 and 12 dB.")
        }
        switch operation {
        case let .addStill(path, name, duration):
            try newName(name)
            try require(
                duration.isFinite && duration > 0 && duration <= 604800,
                "Still source duration must be positive and no longer than seven days.")
            let url = try mediaURL(path, directory: directory)
            try project.addStillAsset(
                url, duration: duration, metadata: VideoStillMedia.metadata(at: url))
            aliases[name] = project.clips.last!.id
        case let .stillDuration(reference, duration):
            let selected = try clip(reference)
            try require(
                project.assets.first { $0.id == selected.assetID }?.isStill == true,
                "Still duration requires an image clip.")
            try require(
                duration.isFinite && duration > 0 && duration <= 604800,
                "Still source duration must be positive and no longer than seven days.")
            try project.setStillDuration(duration, clipID: selected.id)
        case let .videoSettings(settings):
            try require(
                settings.isValid, "Invalid canvas pixels, rational frame rate, or color space.")
            project.videoSettings = settings
        case let .visualEffects(reference, effects):
            let selected = try clip(reference)
            try project.setVisualEffects(effects, clipID: selected.id)
        case let .frameSampling(reference, mode):
            try project.setFrameSampling(mode, clipID: clip(reference).id)
        case let .addMedia(path, name):
            try newName(name)
            let url = try mediaURL(path, directory: directory)
            let asset = AVURLAsset(url: url)
            guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                throw Failure("unsupported_media", "Expected media with a video track.")
            }
            let duration = try await asset.load(.duration).seconds
            let size = try await track.load(.naturalSize)
            try require(
                duration.isFinite && duration > 0 && duration <= 604800,
                "Media duration must be between zero and seven days.")
            try require(
                size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0
                    && size.width <= 16384 && size.height <= 16384, "Invalid media dimensions.")
            let metadata = try await VideoSourceMetadata.probe(track)
            project.addAsset(
                url, duration: duration, width: metadata["width"] as! Int,
                height: metadata["height"] as! Int, sourceMetadata: metadata)
            aliases[name] = project.clips.last!.id
        case let .split(reference, sourceTime, rightName):
            let selected = try clip(reference)
            try newName(rightName)
            try require(
                sourceTime.isFinite && sourceTime > selected.start + 0.05
                    && sourceTime < selected.end - 0.05,
                "Split must leave more than 0.05 seconds on each side.")
            let existing = Set(project.clips.map(\.id))
            project.split(clipID: selected.id, at: sourceTime)
            aliases[rightName] = project.clips.first { !existing.contains($0.id) }!.id
        case let .trim(reference, start, end):
            let selected = try clip(reference)
            let asset = project.assets.first { $0.id == selected.assetID }!
            try require(
                start.isFinite && end.isFinite && start >= 0 && end > start + 0.05
                    && (asset.isStill || end <= asset.duration),
                "Trim must be within the source and longer than 0.05 seconds.")
            project.trim(clipID: selected.id, start: start, end: end)
        case let .reorder(references):
            let ordered = try references.map { try clip($0) }
            try require(
                ordered.count == project.clips.count
                    && Set(ordered.map(\.id)).count == ordered.count,
                "Reorder must include every clip exactly once.")
            project.setClips(ordered)
        case let .remove(reference):
            let selected = try clip(reference)
            project.setClips(project.clips.filter { $0.id != selected.id })
        case let .speed(reference, rate):
            let selected = try clip(reference)
            try require(
                rate.isFinite && (0.25...5).contains(rate), "Speed must be between 0.25 and 5.")
            let lower = selected.timelineStart * 1000
            let upper = lower + selected.duration * 1000
            for region in project.speedRegions {
                let start = (region["startMs"] as? NSNumber)?.doubleValue ?? 0
                let end = (region["endMs"] as? NSNumber)?.doubleValue ?? 0
                if region["clipId"] as? String == selected.id || (start < upper && end > lower) {
                    try require(
                        region["clipId"] as? String == selected.id
                            || (start >= lower && end <= upper),
                        "Cannot replace a speed region spanning multiple clips.")
                    if let id = region["id"] as? String { project.removeSpeed(id) }
                }
            }
            if rate != 1 { project.addSpeed(startMs: lower, endMs: upper, rate: rate) }
        case let .sourceAudio(reference, gainDb, muted):
            let selected = try clip(reference)
            try gain(gainDb)
            var clips = project.clips
            let index = clips.firstIndex { $0.id == selected.id }!
            clips[index].raw["audioGainDb"] = gainDb
            clips[index].raw["audioMuted"] = muted
            project.setClips(clips)
        case let .crop(reference, x, y, width, height):
            let selected = try clip(reference)
            try require(
                [x, y, width, height].allSatisfy(\.isFinite) && x >= 0 && y >= 0 && width >= 0.05
                    && height >= 0.05 && x + width <= 1 && y + height <= 1,
                "Crop must fit in normalized bounds with dimensions at least 0.05.")
            project.crop(clipID: selected.id, x: x, y: y, width: width, height: height)
        case let .resetCrop(reference):
            let selected = try clip(reference)
            project.resetCrop(clipID: selected.id)
        case let .text(content, start, end, style):
            try range(start, end)
            try require(
                !content.isEmpty && content.count <= 10000,
                "Text must contain 1 to 10000 characters.")
            project.addText(content, startMs: start * 1000, endMs: end * 1000)
            if let style, let id = project.annotations.last?.id {
                try project.setCaptionStyle(id, style: style)
            }
        case let .outputCaption(id, content, anchor, style):
            try requireCaptionText(content)
            let duration =
                VideoRenderPipeline.timingSegments(project: project).last?.outputRange.end ?? .zero
            try require(
                CMTimeCompare(anchor.end.time, duration) <= 0,
                "Caption range must be within the output composition.")
            if let id {
                let caption = try requireCaption(id, project: project)
                var raw = caption.raw
                raw["content"] = content
                raw["textContent"] = content
                raw["captionWords"] = nil
                try anchor.store(in: &raw)
                try style?.store(in: &raw)
                project.editRegion("annotations", id: id) { $0 = raw }
            } else {
                try project.addOutputCaption(content, anchor: anchor, style: style)
            }
        case let .captionStyle(id, style):
            try project.setCaptionStyle(id, style: style)
        case let .transition(reference, kind, duration):
            let selected = try clip(reference)
            try require(
                project.clips.first?.id != selected.id, "A transition needs a preceding clip.")
            try require(
                (["none"] + VideoTransitionImage.kinds).contains(kind) && duration.isFinite
                    && (0.2...2).contains(duration),
                "Transition must be none, fade, flash, blur or zoom with duration 0.2 to 2 seconds.")
            project.setTransition(before: selected.id, kind: kind, duration: duration)
        case .addAudio, .audioOptions, .removeAudio, .detachAudio, .moveAudio, .splitAudio,
            .trimAudio, .audioFades:
            try await applyAudio(
                operation, project: &project, aliases: aliases,
                audioAliases: &audioAliases, directory: directory)
        case let .rename(title):
            try requireTitle(title)
            project.rename(title)
        case let .canvas(aspectRatio, padding, backgroundColor):
            try require(
                ["native", "16:9", "9:16", "1:1", "4:3", "3:4", "21:9"].contains(aspectRatio),
                "Unsupported aspect ratio.")
            try require(
                padding.isFinite && (0...25).contains(padding),
                "Padding must be between 0 and 25 percent.")
            try require(
                backgroundColor.range(of: "^#[0-9a-fA-F]{6}$", options: .regularExpression) != nil,
                "Background must be a six-digit hex color.")
            try project.setCanvasAspectRatio(aspectRatio)
            project.padding = padding
            project.backgroundColor = backgroundColor
        }
    }

    static func mediaURL(_ path: String, directory: URL) throws -> URL {
        try require(
            !path.isEmpty && !path.contains("://") && !path.contains("\0"),
            "Expected a local media path.")
        let expanded = (path as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded, relativeTo: directory).standardizedFileURL
        try requireLocalFile(url)
        return url
    }
}
