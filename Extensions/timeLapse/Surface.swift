import EdithExtensionSupport
import Foundation

@available(macOS 15.0, *)
@MainActor
enum TimeLapseSurface {
    static func snapshot(
        _ recorder: TimeLapseRecorder, recordings: [TimeLapseRecording], tile: SurfaceTile,
        now: Date = Date()
    ) -> SurfaceSnapshot {
        let showActive =
            (tile.contentKinds?.contains("active") ?? true)
            && (tile.sourceIDs?.contains(recorder.settings.mode.rawValue) ?? true)
        let showRecordings = (tile.contentKinds?.contains("recordings") ?? true)
        var metrics: [SurfaceMetric] =
            showActive
            ? [
                .init(
                    "state", "Recorder",
                    recorder.recording ? "Recording" : recorder.busy ? "Finishing" : "Ready"),
                .init("frames", "Frames", recorder.frames.description),
                .init(
                    "size", "Captured",
                    ByteCountFormatter.string(fromByteCount: recorder.bytes, countStyle: .file)),
            ] : []
        if showActive, let start = recorder.startedAt {
            metrics.append(
                .init(
                    "elapsed", "Elapsed",
                    Int(max(0, now.timeIntervalSince(start))).description + " s"))
        }
        let selected = recordings.filter {
            tile.sourceIDs?.contains($0.session.settings.mode.rawValue) ?? true
        }
        if showRecordings {
            metrics.append(.init("recordings", "Saved recordings", selected.count.description))
        }
        let rows: [SurfaceDataRow] =
            showRecordings
            ? selected.prefix(100).map {
                .init(
                    $0.id.uuidString, sourceID: $0.session.settings.mode.rawValue,
                    title: $0.session.startedAt.formatted(date: .abbreviated, time: .shortened),
                    detail: $0.session.settings.mode.rawValue,
                    value: $0.session.frames.description + " frames", icon: "record.circle",
                    actions: [.init("reveal:" + $0.id.uuidString, "Show recording", "folder")])
            } : []
        let actions: [SurfaceAction] =
            showActive && recorder.recording && !recorder.busy
            ? [.init("stop", "Stop recording", "stop.fill")] : []
        return .init(
            providerID: "timeLapse", metrics: metrics, rows: rows, actions: actions,
            sources: ScreenRecordingMode.allCases.map { .init($0.rawValue, $0.rawValue) },
            message: recorder.error.map { String($0.prefix(2048)) }, updatedAt: now)
    }
}
