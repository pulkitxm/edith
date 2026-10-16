import EdithExtensionSupport
import Foundation

@available(macOS 15.0, *)
@MainActor
enum TimeLapseSurface {
    static func snapshot(
        _ recorder: TimeLapseRecorder, recordings: [TimeLapseRecording], truncated: Bool = false,
        tile: SurfaceTile, now: Date = Date()
    ) -> SurfaceSnapshot {
        let includeStatus = tile.contentKinds?.contains("active") ?? true
        let includeSaved = tile.contentKinds?.contains("recordings") ?? true
        let activeID = recorder.recording || recorder.busy ? recorder.activeSession : nil
        let records = recordings.filter {
            $0.id != activeID
                && (tile.sourceIDs?.contains($0.session.settings.mode.rawValue) ?? true)
                && includeSaved
        }
        var metrics: [SurfaceMetric] = [
            .init("recordings", "Saved recordings", "\(records.count)")
        ]
        var rows: [SurfaceDataRow] = []
        var message: String?
        let mode = recorder.settings.mode
        if includeStatus, tile.sourceIDs?.contains(mode.rawValue) ?? true {
            let state =
                recorder.busy
                ? (recorder.recording ? "Finishing" : "Starting")
                : recorder.recording ? "Recording" : "Ready"
            metrics.insert(.init("state", "Recorder", state), at: 0)
            if recorder.recording || recorder.busy {
                let elapsed = recorder.startedAt.map { max(0, now.timeIntervalSince($0)) } ?? 0
                metrics += [
                    .init("elapsed", "Elapsed", duration(elapsed)),
                    .init("frames", "Captured frames", "\(max(0, recorder.frames))"),
                    .init("size", "Captured size", bytes(recorder.bytes)),
                ]
                let audio = [
                    recorder.settings.systemAudio ? "System audio" : nil,
                    recorder.settings.microphoneID != nil || !recorder.microphone.isEmpty
                        ? "Microphone" : nil,
                ].compactMap { $0 }
                var actions: [SurfaceAction] = []
                if recorder.recording, !recorder.busy, let id = recorder.activeSession {
                    actions = [.init("stop:" + id.uuidString, "Stop recording", "stop.fill")]
                }
                rows.append(
                    .init(
                        "active", sourceID: mode.rawValue, title: mode.rawValue + " recording",
                        detail: sourceDescription(recorder)
                            + " · \(recorder.settings.outputFPS) fps"
                            + (audio.isEmpty ? "" : " · " + audio.joined(separator: " + ")),
                        value: state, icon: "record.circle", actions: actions))
            }
            message = recorder.error.map { String($0.prefix(2048)) }
        }
        rows += records.prefix(100).map { record in
            let session = record.session
            return .init(
                session.id.uuidString, sourceID: session.settings.mode.rawValue,
                title: session.startedAt.formatted(.dateTime.month().day().hour().minute()),
                detail:
                    "\(session.width) × \(session.height) · \(session.settings.outputFPS) fps · "
                    + duration(session.playbackSeconds),
                value: session.failure != nil
                    ? "Needs attention" : session.endedAt != nil ? "Saved" : "Incomplete",
                icon: session.failure == nil ? "video" : "exclamationmark.circle",
                actions: [.init("reveal:" + session.id.uuidString, "Show recording", "folder")])
        }
        if truncated {
            message = [
                message,
                "Showing metadata from up to 512 recordings. Open Recorder for the complete library.",
            ].compactMap { $0 }.joined(separator: " ")
        }
        return .init(
            providerID: "timeLapse", metrics: metrics, rows: rows,
            actions: [.init("open", "Open recorder", "arrow.up.right")],
            sources: ScreenRecordingMode.allCases.map { .init($0.rawValue, $0.rawValue) },
            message: message, updatedAt: now)
    }

    private static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "Unavailable" }
        let bounded = Int(min(31_536_000, max(0, seconds)))
        return bounded >= 3600
            ? "\(bounded / 3600)h \(bounded % 3600 / 60)m"
            : "\(bounded / 60)m \(bounded % 60)s"
    }

    private static func sourceDescription(_ recorder: TimeLapseRecorder) -> String {
        let windows = recorder.sourceMode == "windows"
        let count = windows ? recorder.selectedWindows.count : recorder.selectedDisplays.count
        let singular = windows ? "window" : "display"
        return "\(count) \(singular)" + (count == 1 ? "" : "s")
    }

    private static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, count), countStyle: .file)
    }
}
