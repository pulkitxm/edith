import AVFoundation
import Foundation

extension VideoProject.Asset {
    var audioURL: URL {
        (raw["edithAudioPath"] as? String).map { URL(fileURLWithPath: $0) } ?? url
    }
}

extension VideoProject {
    mutating func setClipAudio(clipID: String, gain: Double? = nil, muted: Bool? = nil) {
        var entries = clips
        guard let index = entries.firstIndex(where: { $0.id == clipID }) else { return }
        if let gain, gain.isFinite { entries[index].raw["audioGainDb"] = min(12, max(-60, gain)) }
        if let muted { entries[index].raw["audioMuted"] = muted }
        setClips(entries)
    }

    @discardableResult
    mutating func detachAudio(clipID: String) -> [String] {
        guard let clip = clips.first(where: { $0.id == clipID }),
            clip.raw["audioDetached"] as? Bool != true,
            let asset = assets.first(where: { $0.id == clip.assetID })
        else { return [] }
        let laneID = "audio_\(UUID().uuidString.lowercased())"
        let segments = VideoRenderPipeline.timingSegments(project: self)
        let clipSegments = segments.filter { $0.clip.id == clipID }
        guard let first = clipSegments.first, let last = clipSegments.last else { return [] }
        let envelope = VideoAudioAutomation.source(
            start: first.outputStart, end: last.outputEnd,
            transitions: VideoRenderPipeline.audioTransitions(project: self, segments: segments))
        var detached: [[String: Any]] = []
        for segment in clipSegments {
            let mutes = VideoAudioMix.muteIntervals(project: self, segment: segment)
            let boundaries = Set(
                [segment.outputStart, segment.outputEnd]
                    + mutes.flatMap { [$0.lowerBound, $0.upperBound] }
            ).sorted()
            for (start, end) in zip(boundaries, boundaries.dropFirst()) {
                detached.append([
                    "id": "audio_\(UUID().uuidString.lowercased())", "laneId": laneID,
                    "assetId": clip.assetID, "timebase": "output", "kind": "audio",
                    "startMs": start * 1000, "endMs": end * 1000,
                    "offsetMs": segment.sourceTime(at: start) * 1000, "rate": segment.rate,
                    "gainDb": (clip.raw["audioGainDb"] as? NSNumber)?.doubleValue ?? 0,
                    "muted": clip.raw["audioMuted"] as? Bool == true
                        || mutes.contains { $0.contains((start + end) / 2) },
                    "loop": false, "fadeInMs": 0, "fadeOutMs": 0,
                    "gainEnvelope": envelope.slice(
                        from: start - first.outputStart, to: end - first.outputStart
                    ).raw,
                    "label": "Detached · \(asset.label)", "origin": "user",
                ])
            }
        }
        guard !detached.isEmpty else { return [] }
        root["audioTracks"] = audioTracks.map(\.raw) + detached
        var entries = clips
        if let index = entries.firstIndex(where: { $0.id == clipID }) {
            entries[index].raw["audioMuted"] = true
            entries[index].raw["audioDetached"] = true
        }
        setClips(entries)
        return detached.compactMap { $0["id"] as? String }
    }

    @discardableResult
    mutating func splitAudio(_ id: String, at outputTime: Double) -> String? {
        guard outputTime.isFinite, let track = audioTracks.first(where: { $0.id == id }),
            outputTime > track.startMs / 1000 + 0.05,
            outputTime < track.endMs / 1000 - 0.05
        else { return nil }
        var right = track.raw
        let newID = "audio_\(UUID().uuidString.lowercased())"
        let laneID = track.raw["laneId"] as? String ?? id
        let leftDuration = outputTime - track.startMs / 1000
        let duration = (track.endMs - track.startMs) / 1000
        let rightDuration = duration - leftDuration
        let envelope = VideoAudioAutomation.track(track)
        let fadeLimit = duration * (track.raw["gainEnvelope"] == nil ? 500 : 1000)
        let fadeInMs = min(track.fadeInMs, fadeLimit)
        let fadeOutMs = min(track.fadeOutMs, fadeLimit)
        right["id"] = newID
        right["laneId"] = laneID
        right["startMs"] = outputTime * 1000
        right["offsetMs"] = track.offsetMs + (outputTime * 1000 - track.startMs) * track.rate
        right["fadeInMs"] = max(0, fadeInMs - leftDuration * 1000)
        right["fadeOutMs"] = min(fadeOutMs, rightDuration * 1000)
        right["gainEnvelope"] = envelope.slice(from: leftDuration, to: duration).raw
        editRegion("audioTracks", id: id) {
            $0["endMs"] = outputTime * 1000
            $0["fadeInMs"] = min(fadeInMs, leftDuration * 1000)
            $0["fadeOutMs"] = max(0, fadeOutMs - rightDuration * 1000)
            $0["gainEnvelope"] = envelope.slice(from: 0, to: leftDuration).raw
            $0["laneId"] = laneID
        }
        root["audioTracks"] = audioTracks.map(\.raw) + [right]
        return newID
    }

    mutating func moveAudio(_ id: String, to outputTime: Double) {
        guard let track = audioTracks.first(where: { $0.id == id }) else { return }
        retimeAudio(
            id, start: outputTime, end: outputTime + (track.endMs - track.startMs) / 1000,
            trimStart: false)
    }

    mutating func retimeAudio(_ id: String, start: Double, end: Double, trimStart: Bool) {
        guard start.isFinite, end.isFinite, start >= 0, end - start >= 0.05,
            let track = audioTracks.first(where: { $0.id == id }),
            let asset = assets.first(where: { $0.id == track.assetID })
        else { return }
        let offset = track.offsetMs + (trimStart ? (start * 1000 - track.startMs) * track.rate : 0)
        guard offset >= 0 else { return }
        let availableEnd =
            track.loop ? end : min(end, start + (asset.duration - offset / 1000) / track.rate)
        guard availableEnd - start >= 0.05 else { return }
        editRegion("audioTracks", id: id) {
            if track.raw["gainEnvelope"] != nil {
                let from = trimStart ? start - track.startMs / 1000 : 0
                $0["gainEnvelope"] =
                    VideoAudioAutomation.track(track).slice(
                        from: from, to: from + availableEnd - start
                    ).raw
            }
            $0["timebase"] = "output"
            $0["startMs"] = start * 1000
            $0["endMs"] = availableEnd * 1000
            $0["offsetMs"] = offset
        }
    }

    mutating func splitMuteRanges(left: Clip, right: Clip, at time: Double) {
        var result: [[String: Any]] = []
        for range in muteRanges {
            guard range["clipId"] as? String == left.id,
                let start = (range["startSec"] as? NSNumber)?.doubleValue,
                let end = (range["endSec"] as? NSNumber)?.doubleValue, end > time
            else { result.append(range); continue }
            if start < time {
                var before = range
                before["endSec"] = time
                result.append(before)
            }
            var after = range
            after["id"] = "mute_\(UUID().uuidString.lowercased())"
            after["clipId"] = right.id
            after["startSec"] = max(start, time)
            result.append(after)
        }
        var timeline = root["timeline"] as? [String: Any] ?? [:]
        timeline["muteRanges"] = result
        root["timeline"] = timeline
    }
}

extension VideoEditorModel {
    func detachAudio(clipID: String) {
        guard audioTask == nil else { return }
        guard let project,
            let clip = project.clips.first(where: { $0.id == clipID }),
            let asset = project.assets.first(where: { $0.id == clip.assetID })
        else { return }
        audioStatus = "Detaching source audio…"
        audioTask = Task {
            defer { audioTask = nil; audioStatus = nil }
            do {
                let tracks = try await AVURLAsset(url: asset.audioURL).loadTracks(
                    withMediaType: .audio)
                guard !Task.isCancelled, self.project?.id == project.id else { return }
                guard !tracks.isEmpty else {
                    errorMessage = "This source has no audio track."
                    return
                }
                var detached: [String] = []
                mutate { detached = $0.detachAudio(clipID: clipID) }
                if let id = detached.first { selection = .audio(id) }
                rebuild()
            } catch {
                if !Task.isCancelled { errorMessage = error.localizedDescription }
            }
        }
    }

    func moveAudio(_ id: String, to outputTime: Double) {
        mutate { $0.moveAudio(id, to: outputTime) }
        rebuild()
    }

    func trimAudio(_ id: String, start: Double, end: Double) {
        mutate { $0.retimeAudio(id, start: start, end: end, trimStart: true) }
        rebuild()
    }

    func splitAudio(_ id: String, at outputTime: Double) {
        mutate { $0.splitAudio(id, at: outputTime) }
        rebuild()
    }
}
