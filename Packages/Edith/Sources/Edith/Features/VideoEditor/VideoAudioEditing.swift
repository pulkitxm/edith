import Foundation

extension VideoProject {
    mutating func retimeAudio(_ id: String, start: Double, end: Double, trimStart: Bool) {
        guard start.isFinite, end.isFinite, start >= 0, end - start >= 0.05,
            let track = audioTracks.first(where: { $0.id == id }),
            let asset = assets.first(where: { $0.id == track.assetID })
        else { return }
        var offset = track.offsetMs + (trimStart ? (start * 1000 - track.startMs) * track.rate : 0)
        if track.loop, asset.duration > 0 {
            let length = asset.duration * 1000
            offset = (offset.truncatingRemainder(dividingBy: length) + length)
                .truncatingRemainder(dividingBy: length)
        }
        guard offset >= 0 else { return }
        let availableEnd =
            track.loop ? end : min(end, start + (asset.duration - offset / 1000) / track.rate)
        guard availableEnd - start >= 0.05 else { return }
        editRegion("audioTracks", id: id) {
            $0["timebase"] = "output"
            $0["startMs"] = start * 1000
            $0["endMs"] = availableEnd * 1000
            $0["offsetMs"] = offset
        }
    }
}
