import EdithCore
import Foundation

public struct SurfaceRecordingRecord: Identifiable, Sendable {
    public let session: TimeLapseSession
    public let directory: URL
    public var id: UUID { session.id }
    public init(session: TimeLapseSession, directory: URL) {
        self.session = session; self.directory = directory
    }
}

public struct SurfaceRecordingLibrary: Sendable {
    public static var root: URL {
        DataRoot.support.appendingPathComponent("video-projects/TimeLapses", isDirectory: true)
    }
    public var records: [SurfaceRecordingRecord]
    public var truncated: Bool
    public init(records: [SurfaceRecordingRecord] = [], truncated: Bool = false) {
        self.records = records; self.truncated = truncated
    }
    public static func read(root: URL) throws -> Self {
        guard FileManager.default.fileExists(atPath: root.path) else { return .init() }
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        guard
            let entries = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])
        else { return .init() }
        var value = Self()
        var inspected = 0
        for case let directory as URL in entries {
            inspected += 1
            if inspected > 512 { value.truncated = true; break }
            try Task.checkCancellation()
            guard let properties = try? directory.resourceValues(forKeys: Set(keys)),
                properties.isDirectory == true, properties.isSymbolicLink != true
            else { continue }
            let file = directory.appendingPathComponent("session.json")
            guard let info = try? file.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey]),
                info.isSymbolicLink != true, let bytes = info.fileSize, bytes <= 262_144,
                let data = try? Data(contentsOf: file), data.count <= 262_144,
                let session = try? JSONDecoder().decode(TimeLapseSession.self, from: data),
                (try? session.validate()) != nil, session.startedAt.timeIntervalSince1970.isFinite,
                session.segments.count <= 2048
            else { continue }
            var frames = 0
            var valid = true
            for segment in session.segments where segment.kind == "video" {
                let sum = frames.addingReportingOverflow(segment.frames)
                if sum.overflow { valid = false; break }
                frames = sum.partialValue
            }
            guard valid else { continue }
            value.records.append(.init(session: session, directory: directory))
        }
        value.records.sort { $0.session.startedAt > $1.session.startedAt }
        return value
    }
}

public enum SurfaceMediaProjection {
    public static func audio(
        _ snapshot: AudioMixerListSnapshot, tile: SurfaceTile, now: Date = Date()
    )
        -> SurfaceExtensionSnapshot
    {
        let apps = snapshot.apps.filter { tile.sourceIDs?.contains($0.bundleID) ?? true }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let sources = Dictionary(grouping: snapshot.apps, by: \.bundleID).compactMap {
            id, records in
            records.first.map { SurfaceSourceChoice(id, $0.name) }
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        return .init(
            metrics: [
                .init("apps", "Playing apps", "\(apps.count)"),
                .init("muted", "Muted", "\(apps.filter(\.muted).count)"),
            ],
            rows: apps.map { app in
                .init(
                    app.target.id, source: app.bundleID, title: app.name,
                    detail: app.bundleID, value: app.muted ? "Muted" : "\(app.percent)%",
                    icon: app.muted ? "speaker.slash" : "speaker.wave.2",
                    actions: [
                        .init(
                            app.muted ? "Restore volume" : "Mute",
                            app.muted ? "speaker.wave.2" : "speaker.slash",
                            .audioVolume(app.target, app.muted ? 1 : 0))
                    ],
                    volume: .init(app))
            }, message: apps.isEmpty ? "No app is producing audio in this selection." : nil,
            updatedAt: now, sources: sources)
    }
    public static func recorder(
        _ status: SurfaceRecorderSnapshot?, library: SurfaceRecordingLibrary, tile: SurfaceTile,
        now: Date = Date()
    ) -> SurfaceExtensionSnapshot {
        let kinds = tile.contentKinds
        let includeStatus = kinds?.contains("active") ?? true
        let includeSaved = kinds?.contains("recordings") ?? true
        let records = library.records.filter {
            $0.id != status?.sessionID
                && (tile.sourceIDs?.contains($0.session.settings.mode.rawValue) ?? true)
                && includeSaved
        }
        var value = SurfaceExtensionSnapshot(
            metrics: [.init("recordings", "Saved recordings", "\(records.count)")],
            actions: [.init("Open recorder", "arrow.up.right", .navigate("timeLapse"))],
            updatedAt: now,
            sources: ScreenRecordingMode.allCases.map { .init($0.rawValue, $0.rawValue) })
        if includeStatus, let status, tile.sourceIDs?.contains(status.mode.rawValue) ?? true {
            let state =
                status.busy
                ? (status.recording ? "Finishing" : "Starting")
                : status.recording ? "Recording" : "Ready"
            value.metrics.insert(.init("state", "Recorder", state), at: 0)
            if status.recording || status.busy {
                let elapsed = status.startedAt.map { max(0, now.timeIntervalSince($0)) } ?? 0
                value.metrics += [
                    .init("elapsed", "Elapsed", duration(elapsed)),
                    .init("frames", "Captured frames", "\(max(0, status.frames))"),
                    .init("size", "Captured size", bytes(status.bytes)),
                ]
                let audio = [
                    status.systemAudio ? "System audio" : nil,
                    status.microphone ? "Microphone" : nil,
                ].compactMap { $0 }
                var actions: [SurfaceRowAction] = []
                if status.recording, !status.busy, let id = status.sessionID {
                    actions = [.init("Stop recording", "stop.fill", .stopRecording(id))]
                }
                value.rows.append(
                    .init(
                        "active", source: status.mode.rawValue,
                        title: status.mode.rawValue + " recording",
                        detail: "\(status.sources) \(status.sourceMode) · \(status.frameRate) fps"
                            + (audio.isEmpty ? "" : " · " + audio.joined(separator: " + ")),
                        value: state, icon: "record.circle", actions: actions))
            }
            value.message = status.error
        } else if includeStatus, status == nil {
            value.message = "Open Screen Recorder to see live recording status."
        }
        value.rows += records.map { record in
            let session = record.session
            return .init(
                session.id.uuidString, source: session.settings.mode.rawValue,
                title: session.startedAt.formatted(.dateTime.month().day().hour().minute()),
                detail:
                    "\(session.width) × \(session.height) · \(session.settings.outputFPS) fps · "
                    + duration(playback(session)),
                value: session.failure != nil
                    ? "Needs attention" : session.endedAt != nil ? "Saved" : "Incomplete",
                icon: session.failure == nil ? "video" : "exclamationmark.circle",
                actions: [.init("Show recording", "folder", .reveal(record.directory))])
        }
        if library.truncated {
            value.message = [
                value.message,
                "Showing metadata from up to 512 recordings. Open Recorder for the complete library.",
            ]
            .compactMap { $0 }.joined(separator: " ")
        }
        return value
    }
    private static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "Unavailable" }
        let bounded = Int(min(31_536_000, max(0, seconds)))
        return bounded >= 3600
            ? "\(bounded / 3600)h \(bounded % 3600 / 60)m"
            : "\(bounded / 60)m \(bounded % 60)s"
    }
    private static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, count), countStyle: .file)
    }
    private static func playback(_ session: TimeLapseSession) -> Double {
        let video = session.segments.filter { $0.kind == "video" }
        if session.settings.mode == .standard, let first = video.map(\.startedAt).min() {
            return video.map { $0.startedAt.timeIntervalSince(first) + $0.duration }
                .filter(\.isFinite).max() ?? 0
        }
        return video.reduce(0) { $0 + Double(max(0, $1.frames)) }
            / Double(TimeLapseSettings.playbackFPS)
    }
}
