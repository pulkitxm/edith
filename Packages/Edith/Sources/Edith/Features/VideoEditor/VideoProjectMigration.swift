import AVFoundation
import Foundation

extension VideoProject {
    func probingMissingMedia() async -> VideoProject {
        var result = self
        var assets = root["assets"] as? [[String: Any]] ?? []
        for index in assets.indices {
            guard assets[index]["kind"] as? String != "audio",
                (assets[index]["durationSec"] as? Double ?? 0) <= 0,
                let path = assets[index]["originalPath"] as? String,
                FileManager.default.fileExists(atPath: path)
            else { continue }
            let asset = AVURLAsset(url: URL(fileURLWithPath: path))
            guard let duration = try? await asset.load(.duration).seconds,
                duration.isFinite, duration > 0
            else { continue }
            assets[index]["durationSec"] = duration
            if let video = try? await asset.loadTracks(withMediaType: .video).first {
                let size = (try? await video.load(.naturalSize)) ?? .zero
                assets[index]["video"] = [
                    "codec": "unknown", "width": Int(abs(size.width)),
                    "height": Int(abs(size.height)), "fps": 30,
                ]
            }
        }
        result.root["assets"] = assets
        var timeline = root["timeline"] as? [String: Any] ?? [:]
        var cursor = 0.0
        let clips = timeline["clips"] as? [[String: Any]] ?? []
        guard clips.contains(where: { $0["sourceEndSec"] == nil }) else { return result }
        timeline["clips"] = clips.map { clip -> [String: Any] in
            var copy = clip
            let sourceStart = copy["sourceStartSec"] as? Double ?? 0
            if copy["sourceEndSec"] == nil,
                let asset = assets.first(where: {
                    $0["id"] as? String == copy["assetId"] as? String
                })
            {
                copy["sourceEndSec"] = asset["durationSec"] as? Double ?? 0
            }
            let sourceEnd = copy["sourceEndSec"] as? Double ?? sourceStart
            copy["timelineStartSec"] = cursor
            cursor += max(0, sourceEnd - sourceStart)
            copy["timelineEndSec"] = cursor
            return copy
        }
        result.root["timeline"] = timeline
        return result
    }

    static func migratedDocument(_ source: [String: Any]) throws -> [String: Any] {
        if source["version"] as? Int == 2 {
            return try migratedDocument(migrateLegacyProject(source))
        }
        guard let version = source["schemaVersion"] as? Int, (3...7).contains(version)
        else { throw ProjectError.unsupportedFormat }
        var document = source
        if version < 4 {
            let project = document["project"] as? [String: Any] ?? [:]
            let primary = project["primaryAssetId"] as? String
            let camera = document.removeValue(forKey: "cameraTrack")
            var assets = document["assets"] as? [[String: Any]] ?? []
            if let camera, !(camera is NSNull),
                let index = assets.firstIndex(where: { $0["id"] as? String == primary })
                    ?? assets.indices.first,
                assets[index]["cameraTrack"] == nil
            {
                assets[index]["cameraTrack"] = camera
                document["assets"] = assets
            }
        }
        if version < 5 {
            for key in ["zoomRanges", "annotations"] {
                let ranges = document[key] as? [[String: Any]] ?? []
                document[key] = anchorLegacyRegions(ranges, in: document)
            }
            var legacy = document["legacyEditor"] as? [String: Any] ?? [:]
            for key in ["speedRegions", "cameraFullscreenRegions"] {
                let ranges = legacy[key] as? [[String: Any]] ?? []
                legacy[key] = anchorLegacyRegions(ranges, in: document)
            }
            document["legacyEditor"] = legacy
        }
        if version < 6 {
            var legacy = document["legacyEditor"] as? [String: Any] ?? [:]
            if legacy["aspectRatio"] as? String == "native",
                let clips = (document["timeline"] as? [String: Any])?["clips"]
                    as? [[String: Any]],
                let assets = document["assets"] as? [[String: Any]],
                let largest = clips.compactMap({ clip -> (Int, Int)? in
                    guard
                        let asset = assets.first(where: {
                            $0["id"] as? String == clip["assetId"] as? String
                        }), let video = asset["video"] as? [String: Any],
                        let width = video["width"] as? Int,
                        let height = video["height"] as? Int,
                        width > 0, height > 0
                    else { return nil }
                    let crop = clip["cropRegion"] as? [String: Double] ?? [:]
                    let w = max(2, Int((Double(width) * (crop["width"] ?? 1)).rounded()) / 2 * 2)
                    let h = max(2, Int((Double(height) * (crop["height"] ?? 1)).rounded()) / 2 * 2)
                    return (w, h)
                }).max(by: { $0.0 * $0.1 < $1.0 * $1.1 })
            {
                let divisor = gcd(largest.0, largest.1)
                legacy["aspectRatio"] = "\(largest.0 / divisor):\(largest.1 / divisor)"
            }
            document["legacyEditor"] = legacy
        }
        if version < 7 {
            var timeline = document["timeline"] as? [String: Any] ?? [:]
            let clips = timeline["clips"] as? [[String: Any]] ?? []
            let trims =
                timeline["trimRanges"] as? [[String: Any]]
                ?? timeline["skipRanges"] as? [[String: Any]] ?? []
            timeline["trimRanges"] = trims.flatMap { trim -> [[String: Any]] in
                guard trim["clipId"] == nil,
                    let asset = trim["assetId"] as? String,
                    let start = number(trim["startSec"]),
                    let end = number(trim["endSec"])
                else { return [trim] }
                let matches = clips.filter { clip in
                    guard clip["assetId"] as? String == asset else { return false }
                    let clipStart = number(clip["sourceStartSec"]) ?? 0
                    let clipEnd = number(clip["sourceEndSec"]) ?? clipStart
                    return max(clipStart, start) < min(clipEnd, end)
                }
                guard !matches.isEmpty else { return [trim] }
                return matches.enumerated().map { index, clip in
                    var fragment = trim
                    if index > 0 { fragment["id"] = "trim_\(UUID().uuidString.lowercased())" }
                    fragment["clipId"] = clip["id"]
                    fragment["startSec"] = max(start, number(clip["sourceStartSec"]) ?? 0)
                    fragment["endSec"] = min(end, number(clip["sourceEndSec"]) ?? end)
                    return fragment
                }
            }
            document["timeline"] = timeline
        }
        document["schemaVersion"] = 7
        if let assets = document["assets"] as? [[String: Any]] {
            let audioIDs = Set(
                assets.filter { $0["kind"] as? String == "audio" }
                    .compactMap { $0["id"] as? String })
            var timeline = document["timeline"] as? [String: Any] ?? [:]
            let trims = timeline["trimRanges"] as? [[String: Any]] ?? []
            timeline["trimRanges"] = trims.filter {
                guard let assetID = $0["assetId"] as? String else { return true }
                return !audioIDs.contains(assetID)
            }
            document["timeline"] = timeline
        }
        func repair(_ value: Any?) -> Any? {
            guard var transcript = value as? [String: Any] else { return value }
            for key in ["words", "segments"] {
                guard let entries = transcript[key] as? [[String: Any]] else { continue }
                transcript[key] = entries.map { entry -> [String: Any] in
                    var item = entry
                    if let start = number(item["startSec"]),
                        let end = number(item["endSec"]), end < start
                    {
                        item["endSec"] = start
                    }
                    return item
                }
            }
            return transcript
        }
        document["transcript"] = repair(document["transcript"])
        if let transcripts = document["transcripts"] as? [[String: Any]] {
            document["transcripts"] = transcripts.compactMap { repair($0) }
        }
        return document
    }

    private static func gcd(_ a: Int, _ b: Int) -> Int {
        var (x, y) = (a, b)
        while y != 0 { (x, y) = (y, x % y) }
        return max(1, x)
    }

    private static func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }

    private static func anchorLegacyRegions(
        _ regions: [[String: Any]], in document: [String: Any]
    ) -> [[String: Any]] {
        let timeline = document["timeline"] as? [String: Any] ?? [:]
        let clips = timeline["clips"] as? [[String: Any]] ?? []
        return regions.flatMap { region -> [[String: Any]] in
            guard region["clipId"] == nil,
                let from = number(region["startMs"]),
                let to = number(region["endMs"])
            else { return [region] }
            let fragments = clips.compactMap { clip -> [String: Any]? in
                let rulerStart = (number(clip["timelineStartSec"]) ?? 0) * 1000
                let sourceStart = number(clip["sourceStartSec"]) ?? 0
                let sourceEnd = number(clip["sourceEndSec"]) ?? sourceStart
                let rulerEnd = rulerStart + max(0, sourceEnd - sourceStart) * 1000
                let start = max(from, rulerStart)
                let end = min(to, rulerEnd)
                guard end > start else { return nil }
                var result = region
                result["startMs"] = start
                result["endMs"] = end
                result["clipId"] = clip["id"]
                result["sourceStartSec"] = sourceStart + (start - rulerStart) / 1000
                result["sourceEndSec"] = sourceStart + (end - rulerStart) / 1000
                return result
            }
            return fragments.isEmpty
                ? [region]
                : fragments.enumerated().map { index, item in
                    var copy = item
                    if index > 0 { copy["id"] = "region_\(UUID().uuidString.lowercased())" }
                    return copy
                }
        }
    }

    private static func migrateLegacyProject(_ source: [String: Any]) -> [String: Any] {
        let media = source["media"] as? [String: Any] ?? [:]
        let editor = source["editor"] as? [String: Any] ?? [:]
        let videoPath =
            media["screenVideoPath"] as? String
            ?? source["videoPath"] as? String ?? ""
        var document = create(
            title: URL(fileURLWithPath: videoPath)
                .deletingPathExtension().lastPathComponent
        ).root
        var timeline = document["timeline"] as? [String: Any] ?? [:]
        var legacy = editor
        if !videoPath.isEmpty {
            let assetID = "asset_\(UUID().uuidString.lowercased())"
            let clipID = "clip_\(UUID().uuidString.lowercased())"
            let cameraPath = media["webcamVideoPath"] as? String
            let camera: Any =
                cameraPath.map { path -> [String: Any] in
                    [
                        "sourcePath": path, "startMs": 0,
                        "offsetMs": Int(
                            ((media["webcamOffsetMs"] as? NSNumber)?.doubleValue ?? 0).rounded()),
                        "visible": true,
                    ]
                } ?? NSNull()
            document["assets"] = [
                [
                    "id": assetID, "kind": "video",
                    "label": URL(fileURLWithPath: videoPath).lastPathComponent,
                    "originalPath": videoPath, "cameraTrack": camera,
                ]
            ]
            var project = document["project"] as? [String: Any] ?? [:]
            project["primaryAssetId"] = assetID
            document["project"] = project
            var clip: [String: Any] = [
                "id": clipID, "assetId": assetID, "sourceStartSec": 0,
                "timelineStartSec": 0, "timelineEndSec": 0,
                "wordRefs": [], "origin": "system", "reason": "migrated from v2",
            ]
            if let crop = editor["cropRegion"] as? [String: Double],
                let x = crop["x"], let y = crop["y"],
                let width = crop["width"], let height = crop["height"],
                x.isFinite, y.isFinite, width.isFinite, height.isFinite
            {
                let left = min(1, max(0, x))
                let top = min(1, max(0, y))
                let w = min(1 - left, max(0, width))
                let h = min(1 - top, max(0, height))
                if w > 0, h > 0, left > 0 || top > 0 || w < 1 || h < 1 {
                    clip["cropRegion"] = ["x": left, "y": top, "width": w, "height": h]
                }
            }
            timeline["clips"] = [clip]
            timeline["trimRanges"] = (editor["trimRegions"] as? [[String: Any]] ?? []).map { trim in
                [
                    "id": "trim_\(UUID().uuidString.lowercased())", "assetId": assetID,
                    "clipId": clipID,
                    "startSec": max(0, ((trim["startMs"] as? NSNumber)?.doubleValue ?? 0) / 1000),
                    "endSec": max(0.001, ((trim["endMs"] as? NSNumber)?.doubleValue ?? 0) / 1000),
                    "origin": "user", "reason": "migrated from v2",
                ] as [String: Any]
            }
        }
        document["timeline"] = timeline
        document["annotations"] = editor["annotationRegions"] ?? []
        document["zoomRanges"] = editor["zoomRegions"] ?? []
        legacy.removeValue(forKey: "annotationRegions")
        legacy.removeValue(forKey: "zoomRegions")
        document["legacyEditor"] = legacy
        document["schemaVersion"] = 4
        return document
    }
}
