import Foundation
import EdithKit

struct VideoProject {
    struct Transition: Identifiable {
        let clipID: String
        let kind: String
        let duration: Double
        var id: String { clipID }
    }

    struct Listing: Identifiable {
        let url: URL
        let title: String
        let isOpenScreenLibrary: Bool
        var id: URL { url }
    }

    static var libraryURL: URL {
        DataRoot.support.appendingPathComponent("video-projects", isDirectory: true)
    }

    static var openScreenLibraryURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("openscreen/projects", isDirectory: true)
    }

    static func listProjects() -> [Listing] {
        let isolated = ProcessInfo.processInfo.environment[DataRoot.devOverrideVariable] != nil
        let folders =
            isolated
            ? [(libraryURL, false)]
            : [
                (libraryURL, false), (openScreenLibraryURL, true),
            ]
        return folders.flatMap { folder, external -> [Listing] in
            let urls =
                (try? FileManager.default.contentsOfDirectory(
                    at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            return urls.filter { $0.pathExtension == "openscreen" }.compactMap { url in
                guard let project = try? open(url) else { return nil }
                return Listing(url: url, title: project.title, isOpenScreenLibrary: external)
            }
        }
        .sorted {
            let left =
                (try? $0.url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            let right =
                (try? $1.url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            return left > right
        }
    }

    struct Asset: Identifiable {
        var raw: [String: Any]
        var id: String { raw["id"] as? String ?? "" }
        var label: String { raw["label"] as? String ?? "Video" }
        var url: URL { URL(fileURLWithPath: raw["originalPath"] as? String ?? "") }
        var duration: Double { raw["durationSec"] as? Double ?? 0 }
        var cameraTrack: [String: Any]? { raw["cameraTrack"] as? [String: Any] }
    }

    struct Clip: Identifiable {
        var raw: [String: Any]
        var id: String { raw["id"] as? String ?? "" }
        var assetID: String { raw["assetId"] as? String ?? "" }
        var start: Double {
            get { raw["sourceStartSec"] as? Double ?? 0 }
            set { raw["sourceStartSec"] = newValue }
        }
        var end: Double {
            get { raw["sourceEndSec"] as? Double ?? 0 }
            set { raw["sourceEndSec"] = newValue }
        }
        var duration: Double { max(0, end - start) }
        var timelineStart: Double { raw["timelineStartSec"] as? Double ?? 0 }
        var rate: Double {
            get { raw["edithPlaybackRate"] as? Double ?? 1 }
            set { raw["edithPlaybackRate"] = newValue }
        }
        var crop: [String: Double]? { raw["cropRegion"] as? [String: Double] }
    }

    struct Zoom: Identifiable {
        var raw: [String: Any]
        var id: String { raw["id"] as? String ?? "" }
        var startMs: Double { raw["startMs"] as? Double ?? 0 }
        var endMs: Double { raw["endMs"] as? Double ?? 0 }
        var depth: Int { raw["depth"] as? Int ?? 2 }
        var focusX: Double { (raw["focus"] as? [String: Double])?["cx"] ?? 0.5 }
        var focusY: Double { (raw["focus"] as? [String: Double])?["cy"] ?? 0.5 }
    }

    struct Annotation: Identifiable {
        var raw: [String: Any]
        var id: String { raw["id"] as? String ?? "" }
        var type: String { raw["type"] as? String ?? "text" }
        var startMs: Double { raw["startMs"] as? Double ?? 0 }
        var endMs: Double { raw["endMs"] as? Double ?? 0 }
        var text: String { raw["content"] as? String ?? "" }
    }

    struct AudioTrack: Identifiable {
        var raw: [String: Any]
        var id: String { raw["id"] as? String ?? "" }
        var assetID: String { raw["assetId"] as? String ?? "" }
        var startMs: Double { raw["startMs"] as? Double ?? 0 }
        var endMs: Double { raw["endMs"] as? Double ?? 0 }
        var offsetMs: Double { (raw["offsetMs"] as? NSNumber)?.doubleValue ?? 0 }
        var gainDb: Double { (raw["gainDb"] as? NSNumber)?.doubleValue ?? 0 }
        var muted: Bool { raw["muted"] as? Bool ?? false }
        var loop: Bool { raw["loop"] as? Bool ?? false }
        var label: String { raw["label"] as? String ?? "Audio" }
    }

    struct TranscriptWord: Identifiable {
        let id: String
        let assetID: String
        let text: String
        let start: Double
        let end: Double
    }

    var root: [String: Any]
    var fileURL: URL?

    var title: String { (root["project"] as? [String: Any])?["title"] as? String ?? "Untitled" }
    var id: String { (root["project"] as? [String: Any])?["id"] as? String ?? "" }

    mutating func rename(_ title: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        var metadata = root["project"] as? [String: Any] ?? [:]
        metadata["title"] = title
        root["project"] = metadata
    }
    var assets: [Asset] { (root["assets"] as? [[String: Any]] ?? []).map { Asset(raw: $0) } }
    var clips: [Clip] {
        let timeline = root["timeline"] as? [String: Any] ?? [:]
        let legacy = root["legacyEditor"] as? [String: Any] ?? [:]
        let speedRanges = legacy["speedRegions"] as? [[String: Any]] ?? []
        return (timeline["clips"] as? [[String: Any]] ?? []).map { source in
            var clip = Clip(raw: source)
            if source["sourceEndSec"] == nil,
                let asset = assets.first(where: { $0.id == clip.assetID })
            {
                clip.end = asset.duration
            }
            let start = clip.timelineStart * 1000
            let end = (clip.timelineStart + clip.duration) * 1000
            if let speed = speedRanges.first(where: {
                abs(($0["startMs"] as? Double ?? -1) - start) < 1
                    && abs(($0["endMs"] as? Double ?? -1) - end) < 1
            })?["speed"] as? Double {
                clip.rate = speed
            }
            return clip
        }
    }
    var zooms: [Zoom] { (root["zoomRanges"] as? [[String: Any]] ?? []).map { Zoom(raw: $0) } }
    var speedRegions: [[String: Any]] {
        (root["legacyEditor"] as? [String: Any])?["speedRegions"] as? [[String: Any]] ?? []
    }
    var trimRanges: [[String: Any]] {
        (root["timeline"] as? [String: Any])?["trimRanges"] as? [[String: Any]] ?? []
    }

    var transitions: [Transition] {
        (root["edithTransitions"] as? [[String: Any]] ?? []).compactMap { item in
            guard let clipID = item["clipId"] as? String,
                let kind = item["kind"] as? String,
                ["fade", "flash"].contains(kind),
                let duration = (item["durationSec"] as? NSNumber)?.doubleValue,
                duration.isFinite, duration > 0
            else { return nil }
            return Transition(clipID: clipID, kind: kind, duration: duration)
        }
    }

    mutating func setTransition(before clipID: String, kind: String, duration: Double) {
        guard let index = clips.firstIndex(where: { $0.id == clipID }), index > 0 else {
            return
        }
        var entries = root["edithTransitions"] as? [[String: Any]] ?? []
        entries.removeAll { $0["clipId"] as? String == clipID }
        if ["fade", "flash"].contains(kind), duration.isFinite {
            entries.append([
                "clipId": clipID, "kind": kind,
                "durationSec": min(2, max(0.2, duration)),
            ])
        }
        root["edithTransitions"] = entries
    }
    var cameraFullscreenRegions: [[String: Any]] {
        (root["legacyEditor"] as? [String: Any])?["cameraFullscreenRegions"]
            as? [[String: Any]] ?? []
    }
    var audioTracks: [AudioTrack] {
        (root["audioTracks"] as? [[String: Any]] ?? []).map { AudioTrack(raw: $0) }
    }
    var transcriptWords: [TranscriptWord] {
        let transcripts =
            root["transcripts"] as? [[String: Any]]
            ?? (root["transcript"] as? [String: Any]).map { [$0] } ?? []
        return transcripts.flatMap { transcript -> [TranscriptWord] in
            guard let assetID = transcript["assetId"] as? String else { return [] }
            let words = transcript["words"] as? [[String: Any]] ?? []
            return words.compactMap { word in
                guard let id = word["id"] as? String,
                    let text = word["text"] as? String,
                    let start = word["startSec"] as? Double,
                    let end = word["endSec"] as? Double
                else { return nil }
                return TranscriptWord(
                    id: id, assetID: assetID,
                    text: text, start: start, end: end)
            }
        }
    }

    mutating func editTranscriptWord(_ id: String, text: String) {
        var transcripts =
            root["transcripts"] as? [[String: Any]]
            ?? (root["transcript"] as? [String: Any]).map { [$0] } ?? []
        for index in transcripts.indices {
            var words = transcripts[index]["words"] as? [[String: Any]] ?? []
            guard let wordIndex = words.firstIndex(where: { $0["id"] as? String == id })
            else { continue }
            let original = words[wordIndex]["text"] as? String ?? ""
            if words[wordIndex]["originalText"] == nil {
                words[wordIndex]["originalText"] = original
            }
            if words[wordIndex]["originalText"] as? String == text {
                words[wordIndex].removeValue(forKey: "originalText")
                words[wordIndex].removeValue(forKey: "source")
            } else {
                words[wordIndex]["source"] = "user"
            }
            words[wordIndex]["text"] = text
            transcripts[index]["words"] = words
            let segments = transcripts[index]["segments"] as? [[String: Any]] ?? []
            transcripts[index]["segments"] = segments.map { segment -> [String: Any] in
                var updated = segment
                if (segment["wordIds"] as? [String])?.contains(id) == true {
                    let ids = segment["wordIds"] as? [String] ?? []
                    updated["text"] = ids.compactMap { wordID in
                        words.first { $0["id"] as? String == wordID }?["text"] as? String
                    }.joined(separator: " ")
                }
                return updated
            }
            root["transcripts"] = transcripts
            if (root["transcript"] as? [String: Any])?["assetId"] as? String
                == transcripts[index]["assetId"] as? String
            {
                root["transcript"] = transcripts[index]
            }
            var annotations = root["annotations"] as? [[String: Any]] ?? []
            for annotationIndex in annotations.indices {
                guard
                    annotations[annotationIndex]["annotationSource"] as? String
                        == "auto-caption",
                    let caption = annotations[annotationIndex]["content"] as? String,
                    caption.contains(original),
                    let startMs = annotations[annotationIndex]["startMs"] as? Double,
                    let endMs = annotations[annotationIndex]["endMs"] as? Double,
                    let startSec = words[wordIndex]["startSec"] as? Double,
                    let endSec = words[wordIndex]["endSec"] as? Double,
                    clips.contains(where: { clip in
                        clip.assetID == transcripts[index]["assetId"] as? String
                            && startMs <= (clip.timelineStart + startSec - clip.start) * 1000
                            && endMs >= (clip.timelineStart + endSec - clip.start) * 1000
                    })
                else { continue }
                annotations[annotationIndex]["content"] =
                    caption.replacingOccurrences(
                        of: original, with: text,
                        range: caption.range(of: original))
            }
            root["annotations"] = annotations
            return
        }
    }
    var annotations: [Annotation] {
        (root["annotations"] as? [[String: Any]] ?? [])
            .map { Annotation(raw: $0) }
    }
    var backgroundColor: String {
        get {
            let legacy = root["legacyEditor"] as? [String: Any] ?? [:]
            return legacy["wallpaper"] as? String ?? "#171b25"
        }
        set {
            var legacy = root["legacyEditor"] as? [String: Any] ?? [:]
            legacy["wallpaper"] = newValue
            root["legacyEditor"] = legacy
        }
    }
    var aspectRatio: String {
        get {
            let legacy = root["legacyEditor"] as? [String: Any] ?? [:]
            return legacy["aspectRatio"] as? String ?? "native"
        }
        set {
            var legacy = root["legacyEditor"] as? [String: Any] ?? [:]
            legacy["aspectRatio"] = newValue
            root["legacyEditor"] = legacy
        }
    }
    var webcamLayout: String {
        get {
            (root["legacyEditor"] as? [String: Any])?["webcamLayoutPreset"] as? String
                ?? "picture-in-picture"
        }
        set {
            var legacy = root["legacyEditor"] as? [String: Any] ?? [:]
            legacy["webcamLayoutPreset"] = newValue
            root["legacyEditor"] = legacy
        }
    }
    var webcamSize: Double {
        get {
            (root["legacyEditor"] as? [String: Any])?["webcamSizePreset"] as? Double ?? 25
        }
        set {
            var legacy = root["legacyEditor"] as? [String: Any] ?? [:]
            legacy["webcamSizePreset"] = min(50, max(10, newValue))
            root["legacyEditor"] = legacy
        }
    }
    var webcamPosition: [String: Double] {
        get {
            (root["legacyEditor"] as? [String: Any])?["webcamPosition"]
                as? [String: Double] ?? ["cx": 0.84, "cy": 0.8]
        }
        set {
            var legacy = root["legacyEditor"] as? [String: Any] ?? [:]
            legacy["webcamPosition"] = [
                "cx": min(1, max(0, newValue["cx"] ?? 0.84)),
                "cy": min(1, max(0, newValue["cy"] ?? 0.8)),
            ]
            root["legacyEditor"] = legacy
        }
    }

    var webcamMaskShape: String {
        get {
            (root["legacyEditor"] as? [String: Any])?["webcamMaskShape"] as? String
                ?? "rectangle"
        }
        set {
            var legacy = root["legacyEditor"] as? [String: Any] ?? [:]
            legacy["webcamMaskShape"] = newValue
            root["legacyEditor"] = legacy
        }
    }

    var webcamMirrored: Bool {
        get { (root["legacyEditor"] as? [String: Any])?["webcamMirrored"] as? Bool ?? false }
        set {
            var legacy = root["legacyEditor"] as? [String: Any] ?? [:]
            legacy["webcamMirrored"] = newValue
            root["legacyEditor"] = legacy
        }
    }

    var cursorHighlight: Bool {
        get {
            (root["legacyEditor"] as? [String: Any])?["edithCursorHighlight"] as? Bool ?? false
        }
        set {
            var legacy = root["legacyEditor"] as? [String: Any] ?? [:]
            legacy["edithCursorHighlight"] = newValue
            root["legacyEditor"] = legacy
        }
    }

    mutating func attachCamera(_ url: URL, to assetID: String, offsetMs: Int = 0) {
        var entries = root["assets"] as? [[String: Any]] ?? []
        guard let index = entries.firstIndex(where: { $0["id"] as? String == assetID }) else {
            return
        }
        entries[index]["cameraTrack"] = [
            "sourcePath": url.path, "startMs": 0, "offsetMs": offsetMs,
            "visible": true,
        ]
        root["assets"] = entries
    }

    mutating func setCameraVisible(_ visible: Bool, for assetID: String) {
        var entries = root["assets"] as? [[String: Any]] ?? []
        guard let index = entries.firstIndex(where: { $0["id"] as? String == assetID }),
            var camera = entries[index]["cameraTrack"] as? [String: Any]
        else { return }
        camera["visible"] = visible
        entries[index]["cameraTrack"] = camera
        root["assets"] = entries
    }
    mutating func relinkCamera(assetID: String, to url: URL) {
        var entries = root["assets"] as? [[String: Any]] ?? []
        guard let index = entries.firstIndex(where: { $0["id"] as? String == assetID }),
            var camera = entries[index]["cameraTrack"] as? [String: Any]
        else { return }
        camera["sourcePath"] = url.path
        entries[index]["cameraTrack"] = camera
        root["assets"] = entries
    }
    var padding: Double {
        get {
            let legacy = root["legacyEditor"] as? [String: Any] ?? [:]
            return legacy["padding"] as? Double ?? 0
        }
        set {
            var legacy = root["legacyEditor"] as? [String: Any] ?? [:]
            legacy["padding"] = min(25, max(0, newValue))
            root["legacyEditor"] = legacy
        }
    }

    static func create(title: String = "Untitled video") -> VideoProject {
        let now = ISO8601DateFormatter().string(from: Date())
        return VideoProject(root: [
            "schemaVersion": 7,
            "project": [
                "id": "proj_\(UUID().uuidString.lowercased())", "title": title,
                "createdAt": now, "updatedAt": now,
            ],
            "assets": [], "transcript": NSNull(), "transcripts": [],
            "timeline": [
                "clips": [], "gaps": [], "trimRanges": [], "muteRanges": [],
                "speedRanges": [], "captionRanges": [],
            ],
            "annotations": [], "zoomRanges": [], "audioTracks": [],
            "legacyEditor": ["wallpaper": "#171b25", "speedRegions": []],
        ])
    }

    static func open(_ url: URL) throws -> VideoProject {
        let data = try Data(contentsOf: url)
        guard let source = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw ProjectError.unsupportedFormat }
        let root = try migratedDocument(source)
        guard root["schemaVersion"] as? Int == 7,
            root["project"] is [String: Any], root["timeline"] is [String: Any]
        else { throw ProjectError.unsupportedFormat }
        let wasMigrated = source["schemaVersion"] as? Int != 7
        return VideoProject(root: root, fileURL: wasMigrated ? nil : url)
    }

    mutating func save(to url: URL) throws {
        var project = root["project"] as? [String: Any] ?? [:]
        project["updatedAt"] = ISO8601DateFormatter().string(from: Date())
        root["project"] = project
        let data = try JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
        fileURL = url
    }

    mutating func relinkMedia(assetID: String, to url: URL) {
        var entries = root["assets"] as? [[String: Any]] ?? []
        guard let index = entries.firstIndex(where: { $0["id"] as? String == assetID }) else {
            return
        }
        entries[index]["originalPath"] = url.path
        root["assets"] = entries
    }

    mutating func relinkMediaNextToProject() {
        guard let directory = fileURL?.deletingLastPathComponent() else { return }
        for asset in assets where !FileManager.default.fileExists(atPath: asset.url.path) {
            let candidate = directory.appendingPathComponent(asset.url.lastPathComponent)
            if FileManager.default.fileExists(atPath: candidate.path) {
                relinkMedia(assetID: asset.id, to: candidate)
            }
        }
        for asset in assets {
            guard let path = asset.cameraTrack?["sourcePath"] as? String,
                !FileManager.default.fileExists(atPath: path)
            else { continue }
            let candidate = directory.appendingPathComponent(
                URL(fileURLWithPath: path).lastPathComponent)
            if FileManager.default.fileExists(atPath: candidate.path) {
                relinkCamera(assetID: asset.id, to: candidate)
            }
        }
    }

    mutating func setClips(_ newClips: [Clip]) {
        var cursor = 0.0
        var timeline = root["timeline"] as? [String: Any] ?? [:]
        var legacy = root["legacyEditor"] as? [String: Any] ?? [:]
        let existingSpeeds = legacy["speedRegions"] as? [[String: Any]] ?? []
        let originalClips = clips
        let unmatched = existingSpeeds.filter { region in
            !originalClips.contains { clip in
                let start = clip.timelineStart * 1000
                let end = (clip.timelineStart + clip.duration) * 1000
                return abs((region["startMs"] as? Double ?? -1) - start) < 1
                    && abs((region["endMs"] as? Double ?? -1) - end) < 1
            }
        }
        var speeds = unmatched
        timeline["clips"] = newClips.map { clip -> [String: Any] in
            var raw = clip.raw
            raw.removeValue(forKey: "edithPlaybackRate")
            raw["timelineStartSec"] = cursor
            let startMs = cursor * 1000
            cursor += clip.duration
            raw["timelineEndSec"] = cursor
            if clip.rate != 1 {
                if let existing = speeds.firstIndex(where: {
                    $0["clipId"] as? String == clip.id
                        && abs(($0["sourceStartSec"] as? Double ?? -1) - clip.start) < 0.001
                        && abs(($0["sourceEndSec"] as? Double ?? -1) - clip.end) < 0.001
                }) {
                    speeds[existing]["speed"] = clip.rate
                } else {
                    speeds.append([
                        "id": "speed_\(UUID().uuidString.lowercased())",
                        "startMs": startMs, "endMs": cursor * 1000,
                        "speed": clip.rate,
                        "clipId": clip.id,
                        "sourceStartSec": clip.start, "sourceEndSec": clip.end,
                    ])
                }
            }
            return raw
        }
        root["timeline"] = timeline
        legacy["speedRegions"] = speeds
        root["legacyEditor"] = legacy
        let relocated = clips
        for key in [
            "zoomRanges", "annotations", "speedRegions",
            "cameraFullscreenRegions", "audioTracks",
        ] {
            let regions =
                key == "speedRegions"
                ? speeds
                : key == "cameraFullscreenRegions"
                    ? cameraFullscreenRegions : root[key] as? [[String: Any]] ?? []
            let adjusted = regions.compactMap { region -> [String: Any]? in
                guard let clipID = region["clipId"] as? String else { return region }
                guard let newClip = relocated.first(where: { $0.id == clipID }) else { return nil }
                guard let sourceStart = region["sourceStartSec"] as? Double,
                    let sourceEnd = region["sourceEndSec"] as? Double
                else { return region }
                let start = max(sourceStart, newClip.start)
                let end = min(sourceEnd, newClip.end)
                guard end > start else { return nil }
                var result = region
                result["sourceStartSec"] = start
                result["sourceEndSec"] = end
                result["startMs"] = (newClip.timelineStart + start - newClip.start) * 1000
                result["endMs"] = (newClip.timelineStart + end - newClip.start) * 1000
                if key == "audioTracks", start > sourceStart {
                    let offset = (region["offsetMs"] as? NSNumber)?.doubleValue ?? 0
                    result["offsetMs"] = Int(offset + (start - sourceStart) * 1000)
                }
                return result
            }
            if key == "speedRegions" || key == "cameraFullscreenRegions" {
                legacy[key] = adjusted
                root["legacyEditor"] = legacy
            } else {
                root[key] = adjusted
            }
        }
        var updatedTimeline = root["timeline"] as? [String: Any] ?? [:]
        updatedTimeline["trimRanges"] = trimRanges.compactMap { trim -> [String: Any]? in
            guard let clipID = trim["clipId"] as? String else { return trim }
            guard let clip = clips.first(where: { $0.id == clipID }) else { return nil }
            let start = max(clip.start, (trim["startSec"] as? NSNumber)?.doubleValue ?? 0)
            let end = min(clip.end, (trim["endSec"] as? NSNumber)?.doubleValue ?? 0)
            guard end > start else { return nil }
            var adjusted = trim
            adjusted["startSec"] = start
            adjusted["endSec"] = end
            return adjusted
        }
        root["timeline"] = updatedTimeline
        let incomingIDs = Set(clips.dropFirst().map(\.id))
        if let transitions = root["edithTransitions"] as? [[String: Any]] {
            root["edithTransitions"] = transitions.filter {
                guard let id = $0["clipId"] as? String else { return false }
                return incomingIDs.contains(id)
            }
        }
    }

    mutating func addTrim(clipID: String, start: Double, end: Double) {
        guard let clip = clips.first(where: { $0.id == clipID }) else { return }
        let start = max(clip.start, start)
        let end = min(clip.end, end)
        guard end > start else { return }
        var timeline = root["timeline"] as? [String: Any] ?? [:]
        var trims = trimRanges
        trims.append([
            "id": "trim_\(UUID().uuidString.lowercased())", "assetId": clip.assetID,
            "clipId": clipID, "startSec": start, "endSec": end,
            "reason": "", "origin": "user",
        ])
        timeline["trimRanges"] = trims
        root["timeline"] = timeline
    }

    mutating func removeTrim(_ id: String) {
        var timeline = root["timeline"] as? [String: Any] ?? [:]
        timeline["trimRanges"] = trimRanges.filter { $0["id"] as? String != id }
        root["timeline"] = timeline
    }

    mutating func addAsset(
        _ url: URL, duration: Double, width: Int, height: Int,
        label: String? = nil, sourceImage: URL? = nil
    ) {
        let id = "asset_\(UUID().uuidString.lowercased())"
        var assets = root["assets"] as? [[String: Any]] ?? []
        var entry: [String: Any] = [
            "id": id, "kind": "video", "label": label ?? url.lastPathComponent,
            "originalPath": url.path, "durationSec": duration,
            "video": ["codec": "unknown", "width": width, "height": height, "fps": 30],
            "cameraTrack": NSNull(),
        ]
        if let sourceImage { entry["edithSourceImagePath"] = sourceImage.path }
        assets.append(entry)
        root["assets"] = assets
        var project = root["project"] as? [String: Any] ?? [:]
        if project["primaryAssetId"] == nil { project["primaryAssetId"] = id }
        root["project"] = project
        var clips = self.clips
        clips.append(
            Clip(raw: [
                "id": "clip_\(UUID().uuidString.lowercased())", "assetId": id,
                "sourceStartSec": 0, "sourceEndSec": duration,
                "timelineStartSec": 0, "timelineEndSec": duration,
                "wordRefs": [], "origin": "user", "reason": "",
            ]))
        setClips(clips)
    }

    mutating func addAudio(
        _ url: URL, duration: Double, at startMs: Double,
        sourceOffsetMs: Double = 0
    ) {
        guard duration > 0 else { return }
        let id = "asset_\(UUID().uuidString.lowercased())"
        var assets = root["assets"] as? [[String: Any]] ?? []
        assets.append([
            "id": id, "kind": "audio", "label": url.lastPathComponent,
            "originalPath": url.path, "durationSec": duration,
            "audio": ["codec": "unknown", "sampleRate": 0, "channels": 0],
            "cameraTrack": NSNull(),
        ])
        root["assets"] = assets
        let end = (clips.last.map { $0.timelineStart + $0.duration } ?? 0) * 1000
        let start = min(max(0, startMs), end)
        guard start < end else { return }
        var tracks = root["audioTracks"] as? [[String: Any]] ?? []
        let trackID = "audio_\(UUID().uuidString.lowercased())"
        let sourceOffsetMs = max(0, sourceOffsetMs)
        let audioEnd = min(end, start + max(0, duration * 1000 - sourceOffsetMs))
        for clip in clips {
            let pieceStart = max(start, clip.timelineStart * 1000)
            let pieceEnd = min(audioEnd, (clip.timelineStart + clip.duration) * 1000)
            guard pieceEnd > pieceStart else { continue }
            var fragment: [String: Any] = [
                "id": "audio_\(UUID().uuidString.lowercased())", "trackId": trackID,
                "assetId": id, "startMs": pieceStart, "endMs": pieceEnd,
                "kind": "music", "durationSec": duration,
                "offsetMs": Int(sourceOffsetMs + pieceStart - start),
                "gainDb": 0, "loop": false, "fadeInMs": 0, "fadeOutMs": 0,
                "muted": false, "label": url.lastPathComponent, "origin": "user",
            ]
            anchor(&fragment)
            tracks.append(fragment)
        }
        root["audioTracks"] = tracks
    }

    mutating func removeAudioTrack(_ id: String) {
        guard let selected = audioTracks.first(where: { $0.id == id }) else { return }
        let groupID = selected.raw["trackId"] as? String ?? id
        root["audioTracks"] = audioTracks.filter {
            ($0.raw["trackId"] as? String ?? $0.id) != groupID
        }.map(\.raw)
    }

    mutating func setAudioGain(_ id: String, decibels: Double) {
        var tracks = audioTracks.map(\.raw)
        guard let selected = tracks.first(where: { $0["id"] as? String == id }) else { return }
        let groupID = selected["trackId"] as? String ?? id
        for index in tracks.indices {
            let currentGroupID =
                tracks[index]["trackId"] as? String
                ?? tracks[index]["id"] as? String
            if currentGroupID == groupID {
                tracks[index]["gainDb"] = max(-60, min(12, decibels))
            }
        }
        root["audioTracks"] = tracks
    }

    mutating func setAudioOptions(
        _ id: String, muted: Bool? = nil, loop: Bool? = nil,
        fadeInMs: Int? = nil, fadeOutMs: Int? = nil
    ) {
        var tracks = audioTracks.map(\.raw)
        guard let selected = tracks.first(where: { $0["id"] as? String == id }) else { return }
        let groupID = selected["trackId"] as? String ?? id
        for index in tracks.indices {
            let current =
                tracks[index]["trackId"] as? String
                ?? tracks[index]["id"] as? String
            guard current == groupID else { continue }
            if let muted { tracks[index]["muted"] = muted }
            if let loop { tracks[index]["loop"] = loop }
            if let fadeInMs { tracks[index]["fadeInMs"] = max(0, fadeInMs) }
            if let fadeOutMs { tracks[index]["fadeOutMs"] = max(0, fadeOutMs) }
        }
        root["audioTracks"] = tracks
    }

    mutating func split(clipID: String, at sourceTime: Double) {
        var clips = self.clips
        guard let index = clips.firstIndex(where: { $0.id == clipID }),
            sourceTime > clips[index].start + 0.05,
            sourceTime < clips[index].end - 0.05
        else { return }
        var left = clips[index]
        var right = clips[index]
        left.end = sourceTime
        right.start = sourceTime
        right.raw["id"] = "clip_\(UUID().uuidString.lowercased())"
        right.raw["timelineStartSec"] = left.timelineStart + left.duration
        reanchorRegionsAfterSplit(left: left, right: right, at: sourceTime)
        clips.replaceSubrange(index...index, with: [left, right])
        setClips(clips)
    }

    mutating func duplicate(clipID: String) -> String? {
        var entries = clips
        guard let index = entries.firstIndex(where: { $0.id == clipID }) else { return nil }
        var duplicate = entries[index]
        let newID = "clip_\(UUID().uuidString.lowercased())"
        duplicate.raw["id"] = newID
        entries.insert(duplicate, at: index + 1)
        setClips(entries)

        let delta = (clips[index + 1].timelineStart - clips[index].timelineStart) * 1000
        for key in [
            "zoomRanges", "annotations", "audioTracks", "speedRegions", "cameraFullscreenRegions",
        ] {
            var regions: [[String: Any]]
            switch key {
            case "speedRegions": regions = speedRegions
            case "cameraFullscreenRegions": regions = cameraFullscreenRegions
            default: regions = root[key] as? [[String: Any]] ?? []
            }
            let copies = regions.filter { region in
                guard region["clipId"] as? String == clipID else { return false }
                if key == "speedRegions", region["sourceStartSec"] != nil,
                    region["sourceEndSec"] != nil,
                    regions.contains(where: {
                        $0["clipId"] as? String == newID
                            && ($0["sourceStartSec"] as? NSNumber)?.doubleValue
                                == (region["sourceStartSec"] as? NSNumber)?.doubleValue
                            && ($0["sourceEndSec"] as? NSNumber)?.doubleValue
                                == (region["sourceEndSec"] as? NSNumber)?.doubleValue
                            && ($0["speed"] as? NSNumber)?.doubleValue
                                == (region["speed"] as? NSNumber)?.doubleValue
                    })
                {
                    return false
                }
                return true
            }.map {
                original -> [String: Any] in
                var copy = original
                copy["id"] = "\(key)_\(UUID().uuidString.lowercased())"
                copy["clipId"] = newID
                copy["startMs"] = ((original["startMs"] as? NSNumber)?.doubleValue ?? 0) + delta
                copy["endMs"] = ((original["endMs"] as? NSNumber)?.doubleValue ?? 0) + delta
                if key == "audioTracks" {
                    copy["trackId"] = "audio_\(UUID().uuidString.lowercased())"
                }
                return copy
            }
            regions.append(contentsOf: copies)
            if key == "speedRegions" || key == "cameraFullscreenRegions" {
                var legacy = root["legacyEditor"] as? [String: Any] ?? [:]
                legacy[key] = regions
                root["legacyEditor"] = legacy
            } else {
                root[key] = regions
            }
        }
        var timeline = root["timeline"] as? [String: Any] ?? [:]
        var trims = trimRanges
        let copies = trims.filter { $0["clipId"] as? String == clipID }.map { trim in
            var copy = trim
            copy["id"] = "trim_\(UUID().uuidString.lowercased())"
            copy["clipId"] = newID
            return copy
        }
        trims.append(contentsOf: copies)
        timeline["trimRanges"] = trims
        root["timeline"] = timeline
        return newID
    }

    private mutating func reanchorRegionsAfterSplit(
        left: Clip, right: Clip, at splitTime: Double
    ) {
        var timeline = root["timeline"] as? [String: Any] ?? [:]
        var trims: [[String: Any]] = []
        for var trim in trimRanges {
            guard trim["clipId"] as? String == left.id,
                let start = (trim["startSec"] as? NSNumber)?.doubleValue,
                let end = (trim["endSec"] as? NSNumber)?.doubleValue,
                end > splitTime
            else {
                trims.append(trim)
                continue
            }
            if start < splitTime {
                trim["endSec"] = splitTime
                trims.append(trim)
            }
            var rightTrim = trim
            rightTrim["id"] = "trim_\(UUID().uuidString.lowercased())"
            rightTrim["clipId"] = right.id
            rightTrim["startSec"] = max(start, splitTime)
            rightTrim["endSec"] = end
            trims.append(rightTrim)
        }
        timeline["trimRanges"] = trims
        root["timeline"] = timeline
        for key in [
            "zoomRanges", "annotations", "speedRegions",
            "cameraFullscreenRegions", "audioTracks",
        ] {
            var regions: [[String: Any]]
            if key == "speedRegions" {
                regions = speedRegions
            } else if key == "cameraFullscreenRegions" {
                regions = cameraFullscreenRegions
            } else {
                regions = root[key] as? [[String: Any]] ?? []
            }
            var fragments: [[String: Any]] = []
            for var region in regions {
                guard region["clipId"] as? String == left.id,
                    let start = region["sourceStartSec"] as? Double,
                    let end = region["sourceEndSec"] as? Double,
                    end > splitTime
                else {
                    fragments.append(region)
                    continue
                }
                var rightRegion = region
                if start < splitTime {
                    region["sourceEndSec"] = splitTime
                    region["endMs"] = (left.timelineStart + left.duration) * 1000
                    fragments.append(region)
                    rightRegion["id"] = "\(key)_\(UUID().uuidString.lowercased())"
                    rightRegion["sourceStartSec"] = splitTime
                    rightRegion["startMs"] = right.timelineStart * 1000
                    if key == "audioTracks" {
                        let offset = (rightRegion["offsetMs"] as? NSNumber)?.doubleValue ?? 0
                        rightRegion["offsetMs"] = Int(offset + (splitTime - start) * 1000)
                    }
                } else {
                    rightRegion["startMs"] =
                        (right.timelineStart + start - splitTime) * 1000
                }
                rightRegion["clipId"] = right.id
                rightRegion["endMs"] =
                    (right.timelineStart + end - splitTime) * 1000
                fragments.append(rightRegion)
            }
            if key == "speedRegions" || key == "cameraFullscreenRegions" {
                var legacy = root["legacyEditor"] as? [String: Any] ?? [:]
                legacy[key] = fragments
                root["legacyEditor"] = legacy
            } else {
                root[key] = fragments
            }
        }
    }

    mutating func trim(clipID: String, start: Double, end: Double) {
        var clips = self.clips
        guard let index = clips.firstIndex(where: { $0.id == clipID }),
            start >= 0, end > start + 0.05,
            end <= (assets.first { $0.id == clips[index].assetID }?.duration ?? 0)
        else { return }
        clips[index].start = start
        clips[index].end = end
        setClips(clips)
    }

    mutating func crop(clipID: String, x: Double, y: Double, width: Double, height: Double) {
        var clips = self.clips
        guard let index = clips.firstIndex(where: { $0.id == clipID }) else { return }
        let x = min(0.95, max(0, x))
        let y = min(0.95, max(0, y))
        clips[index].raw["cropRegion"] = [
            "x": x, "y": y,
            "width": min(1 - x, max(0.05, width)),
            "height": min(1 - y, max(0.05, height)),
        ]
        setClips(clips)
    }

    mutating func resetCrop(clipID: String) {
        var clips = self.clips
        guard let index = clips.firstIndex(where: { $0.id == clipID }) else { return }
        clips[index].raw.removeValue(forKey: "cropRegion")
        setClips(clips)
    }

    mutating func addZoom(
        startMs: Double, endMs: Double, depth: Int, x: Double, y: Double,
        automatic: Bool = false
    ) {
        var ranges = root["zoomRanges"] as? [[String: Any]] ?? []
        var region: [String: Any] = [
            "id": "zoom_\(UUID().uuidString.lowercased())",
            "startMs": startMs, "endMs": endMs,
            "depth": min(6, max(1, depth)),
            "focus": ["cx": min(1, max(0, x)), "cy": min(1, max(0, y))],
            "focusMode": automatic ? "auto" : "manual",
            "source": automatic ? "auto" : "manual",
        ]
        anchor(&region)
        ranges.append(region)
        root["zoomRanges"] = ranges
    }

    mutating func updateZoom(
        _ id: String, depth: Int? = nil, duration: Double? = nil,
        x: Double? = nil, y: Double? = nil
    ) {
        var ranges = root["zoomRanges"] as? [[String: Any]] ?? []
        guard let index = ranges.firstIndex(where: { $0["id"] as? String == id }) else {
            return
        }
        if let depth { ranges[index]["depth"] = min(6, max(1, depth)) }
        if let duration, duration.isFinite,
            let start = (ranges[index]["startMs"] as? NSNumber)?.doubleValue
        {
            let clipEnd =
                clips.first(where: { $0.id == ranges[index]["clipId"] as? String })
                .map { ($0.timelineStart + $0.duration) * 1000 }
                ?? Double.greatestFiniteMagnitude
            let end = min(clipEnd, start + max(0.1, duration) * 1000)
            ranges[index]["endMs"] = end
            if let clip = clips.first(where: { $0.id == ranges[index]["clipId"] as? String }) {
                ranges[index]["sourceEndSec"] = clip.start + end / 1000 - clip.timelineStart
            }
        }
        if x != nil || y != nil {
            var focus = ranges[index]["focus"] as? [String: Double] ?? [:]
            if let x, x.isFinite { focus["cx"] = min(1, max(0, x)) }
            if let y, y.isFinite { focus["cy"] = min(1, max(0, y)) }
            ranges[index]["focus"] = focus
            ranges[index]["focusMode"] = "manual"
        }
        root["zoomRanges"] = ranges
    }

    mutating func updateZoomTiming(_ id: String, startMs: Double, endMs: Double) {
        guard startMs.isFinite, endMs.isFinite else { return }
        var ranges = root["zoomRanges"] as? [[String: Any]] ?? []
        guard let index = ranges.firstIndex(where: { $0["id"] as? String == id }) else {
            return
        }
        let anchoredID = ranges[index]["clipId"] as? String
        let originalStart = (ranges[index]["startMs"] as? NSNumber)?.doubleValue ?? startMs
        guard
            let clip = clips.first(where: { $0.id == anchoredID })
                ?? clips.first(where: {
                    originalStart >= $0.timelineStart * 1000
                        && originalStart < ($0.timelineStart + $0.duration) * 1000
                })
        else { return }
        let lower = clip.timelineStart * 1000
        let upper = (clip.timelineStart + clip.duration) * 1000
        guard upper - lower >= 100 else { return }
        let start = max(lower, min(upper - 100, startMs))
        let end = max(start + 100, min(upper, endMs))
        ranges[index]["startMs"] = start
        ranges[index]["endMs"] = end
        ranges[index]["clipId"] = clip.id
        ranges[index]["assetId"] = clip.assetID
        ranges[index]["sourceStartSec"] = clip.start + start / 1000 - clip.timelineStart
        ranges[index]["sourceEndSec"] = clip.start + end / 1000 - clip.timelineStart
        root["zoomRanges"] = ranges
    }

    mutating func addSpeed(startMs: Double, endMs: Double, rate: Double) {
        guard startMs >= 0, endMs > startMs else { return }
        var legacy = root["legacyEditor"] as? [String: Any] ?? [:]
        var ranges = speedRegions
        var region: [String: Any] = [
            "id": "speed_\(UUID().uuidString.lowercased())",
            "startMs": startMs, "endMs": endMs,
            "speed": max(0.25, min(5, rate)),
        ]
        anchor(&region)
        ranges.append(region)
        legacy["speedRegions"] = ranges
        root["legacyEditor"] = legacy
    }

    mutating func removeSpeed(_ id: String) {
        var legacy = root["legacyEditor"] as? [String: Any] ?? [:]
        legacy["speedRegions"] = speedRegions.filter { $0["id"] as? String != id }
        root["legacyEditor"] = legacy
    }

    mutating func addCameraFullscreen(startMs: Double, endMs: Double) {
        guard endMs > startMs else { return }
        var legacy = root["legacyEditor"] as? [String: Any] ?? [:]
        var regions = cameraFullscreenRegions
        var region: [String: Any] = [
            "id": "camfull_\(UUID().uuidString.lowercased())",
            "startMs": startMs, "endMs": endMs,
        ]
        anchor(&region)
        regions.append(region)
        legacy["cameraFullscreenRegions"] = regions
        root["legacyEditor"] = legacy
    }

    mutating func removeCameraFullscreen(_ id: String) {
        var legacy = root["legacyEditor"] as? [String: Any] ?? [:]
        legacy["cameraFullscreenRegions"] = cameraFullscreenRegions.filter {
            $0["id"] as? String != id
        }
        root["legacyEditor"] = legacy
    }

    mutating func addAutomaticZooms() -> Int {
        var count = 0
        for clip in clips {
            guard let asset = assets.first(where: { $0.id == clip.assetID }) else { continue }
            let sidecar = URL(fileURLWithPath: asset.url.path + ".cursor.json")
            guard let data = try? Data(contentsOf: sidecar),
                let json = try? JSONSerialization.jsonObject(with: data),
                let document = json as? [String: Any],
                let samples = document["samples"] as? [[String: Any]]
            else { continue }
            var lastZoomMs = -Double.infinity
            for sample in samples {
                guard let kind = sample["interactionType"] as? String,
                    kind == "click" || kind == "double-click",
                    let sampleMs = sample["timeMs"] as? Double,
                    sampleMs >= clip.start * 1000, sampleMs < clip.end * 1000
                else { continue }
                let timelineMs = clip.timelineStart * 1000 + sampleMs - clip.start * 1000
                guard timelineMs - lastZoomMs >= 1500 else { continue }
                addZoom(
                    startMs: timelineMs,
                    endMs: min(
                        (clip.timelineStart + clip.duration) * 1000, timelineMs + 1600),
                    depth: 3,
                    x: sample["cx"] as? Double ?? 0.5,
                    y: sample["cy"] as? Double ?? 0.5,
                    automatic: true)
                lastZoomMs = timelineMs
                count += 1
            }
        }
        return count
    }

    mutating func addText(_ text: String, startMs: Double, endMs: Double) {
        var regions = root["annotations"] as? [[String: Any]] ?? []
        var region: [String: Any] = [
            "id": "annotation_\(UUID().uuidString.lowercased())",
            "startMs": startMs, "endMs": endMs,
            "type": "text", "content": text,
            "position": ["x": 50, "y": 80], "size": ["width": 60, "height": 12],
            "style": [
                "color": "#ffffff", "backgroundColor": "transparent",
                "fontSize": 32, "fontFamily": "Helvetica Neue", "fontWeight": "bold",
                "fontStyle": "normal", "textDecoration": "none", "textAlign": "center",
            ],
            "zIndex": regions.count,
        ]
        anchor(&region)
        regions.append(region)
        root["annotations"] = regions
    }

    mutating func setAnnotationStyle(_ id: String, key: String, value: Any) {
        guard ["color", "backgroundColor", "fontSize"].contains(key) else { return }
        var regions = root["annotations"] as? [[String: Any]] ?? []
        guard let index = regions.firstIndex(where: { $0["id"] as? String == id }),
            regions[index]["type"] as? String == "text"
        else { return }
        var style = regions[index]["style"] as? [String: Any] ?? [:]
        style[key] = value
        regions[index]["style"] = style
        root["annotations"] = regions
    }

    mutating func setAnnotationPosition(_ id: String, axis: String, value: Double) {
        guard axis == "x" || axis == "y", value.isFinite else { return }
        var regions = root["annotations"] as? [[String: Any]] ?? []
        guard let index = regions.firstIndex(where: { $0["id"] as? String == id }) else {
            return
        }
        var position = regions[index]["position"] as? [String: Double] ?? [:]
        position[axis] = min(100, max(0, value))
        regions[index]["position"] = position
        root["annotations"] = regions
    }

    private func anchor(_ region: inout [String: Any]) {
        guard let start = region["startMs"] as? Double,
            let end = region["endMs"] as? Double,
            let clip = clips.first(where: {
                start >= $0.timelineStart * 1000 && end <= ($0.timelineStart + $0.duration) * 1000
            })
        else { return }
        region["clipId"] = clip.id
        region["sourceStartSec"] = clip.start + start / 1000 - clip.timelineStart
        region["sourceEndSec"] = clip.start + end / 1000 - clip.timelineStart
    }

    mutating func addOverlay(
        type: String, startMs: Double, endMs: Double,
        x: Double, y: Double, content: String = ""
    ) {
        var regions = root["annotations"] as? [[String: Any]] ?? []
        var annotation: [String: Any] = [
            "id": "annotation_\(UUID().uuidString.lowercased())",
            "startMs": startMs, "endMs": endMs,
            "type": type, "content": content,
            "position": [
                "x": min(100, max(0, x * 100)),
                "y": min(100, max(0, y * 100)),
            ],
            "size": ["width": 25, "height": 16],
            "style": [
                "color": "#ffffff", "backgroundColor": "transparent",
                "fontSize": 32, "fontFamily": "Helvetica Neue", "fontWeight": "bold",
                "fontStyle": "normal", "textDecoration": "none", "textAlign": "center",
            ],
            "zIndex": regions.count,
        ]
        if type == "blur" {
            annotation["blurData"] = [
                "type": "mosaic", "shape": "rectangle",
                "color": "white", "intensity": 16, "blockSize": 16,
            ]
        }
        if type == "figure" {
            annotation["figureData"] = [
                "arrowDirection": "right", "color": "#34B27B",
                "strokeWidth": 4,
            ]
        }
        if type == "image" { annotation["imageContent"] = content }
        anchor(&annotation)
        regions.append(annotation)
        root["annotations"] = regions
    }

    mutating func addTranscription(
        assetID: String, words: [VideoTranscription.Word], language: String = "en"
    ) {
        guard !words.isEmpty else { return }
        let segmentID = "segment_\(UUID().uuidString.lowercased())"
        let wordObjects: [[String: Any]] = words.map { word in
            [
                "id": "word_\(UUID().uuidString.lowercased())", "segmentId": segmentID,
                "startSec": word.start, "endSec": word.end, "text": word.text,
            ]
        }
        let transcript: [String: Any] = [
            "assetId": assetID, "language": language,
            "segments": [
                [
                    "id": segmentID, "kind": "speech",
                    "startSec": words.first!.start, "endSec": words.last!.end,
                    "text": words.map(\.text).joined(separator: " "),
                    "wordIds": wordObjects.compactMap { $0["id"] as? String },
                ]
            ],
            "words": wordObjects,
        ]
        var transcripts = root["transcripts"] as? [[String: Any]] ?? []
        transcripts.removeAll { $0["assetId"] as? String == assetID }
        transcripts.append(transcript)
        root["transcripts"] = transcripts
        root["transcript"] = transcript

        for clip in clips where clip.assetID == assetID {
            for group in stride(from: 0, to: words.count, by: 4) {
                let phrase = Array(words[group..<min(group + 4, words.count)])
                guard let first = phrase.first, let last = phrase.last,
                    first.start >= clip.start, first.start < clip.end
                else { continue }
                let startMs = (clip.timelineStart + first.start - clip.start) * 1000
                let endMs = (clip.timelineStart + min(last.end, clip.end) - clip.start) * 1000
                addText(
                    phrase.map(\.text).joined(separator: " "),
                    startMs: startMs, endMs: endMs)
                var annotations = root["annotations"] as? [[String: Any]] ?? []
                annotations[annotations.count - 1]["annotationSource"] = "auto-caption"
                root["annotations"] = annotations
            }
        }
    }

    enum ProjectError: LocalizedError {
        case unsupportedFormat
        var errorDescription: String? {
            "This project is not an OpenScreen v7 .openscreen document."
        }
    }
}
