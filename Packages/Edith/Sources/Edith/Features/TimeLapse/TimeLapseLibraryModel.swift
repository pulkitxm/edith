import AppKit
import EdithKit
import Observation

@available(macOS 15.0, *)
@MainActor @Observable
final class TimeLapseLibraryModel {
    let loading = ContentLoad()
    var recordings: [TimeLapseRecording]
    let exportLoad = ContentLoad()
    var exporting: Bool { exportLoad.isRunning }
    var message: String?
    @ObservationIgnored private var exportTask: Task<Void, Never>?
    @ObservationIgnored private let read: @Sendable (URL) async throws -> [TimeLapseRecording]
    @ObservationIgnored private let write:
        @Sendable (TimeLapseRecording, TimeLapseExportQuality, URL) async throws -> Void

    init(
        recordings: [TimeLapseRecording] = [],
        read: @escaping @Sendable (URL) async throws -> [TimeLapseRecording] = {
            try TimeLapseRecording.load(in: $0)
        },
        write:
            @escaping @Sendable (TimeLapseRecording, TimeLapseExportQuality, URL) async throws ->
            Void = {
                try await TimeLapseExporter.export($0, quality: $1, to: $2)
            }
    ) {
        self.recordings = recordings
        self.read = read
        self.write = write
        if !recordings.isEmpty { loading.setContent() }
    }

    func refresh(root: URL? = nil, excluding active: URL? = nil) async {
        let root = root ?? TimeLapseRecorder.libraryURL
        let read = read
        await loading.perform {
            try await read(root).filter { $0.directory != active }
        } apply: { [weak self] in
            self?.recordings = $0
        }
    }

    func export(
        _ recording: TimeLapseRecording, quality: TimeLapseExportQuality, to destination: URL
    ) {
        guard exportTask == nil else { return }
        let request = exportLoad.begin(preservingContent: false)
        message = nil
        let write = write
        exportTask = Task { [self] in
            defer {
                if exportLoad.isRunning { exportLoad.cancel(request) }
                exportTask = nil
            }
            do {
                try await write(recording, quality, destination)
                try Task.checkCancellation()
                guard exportLoad.isCurrent(request) else { return }
                message = "Saved \(destination.lastPathComponent)."
                exportLoad.complete(request)
            } catch is CancellationError {
                message = "Export cancelled."
                exportLoad.cancel(request)
            } catch {
                if Task.isCancelled {
                    message = "Export cancelled."
                    exportLoad.cancel(request)
                    return
                }
                guard exportLoad.isCurrent(request) else { return }
                message = error.localizedDescription
                exportLoad.fail(request, error: error)
            }
        }
    }

    func cancelExport() { exportTask?.cancel() }

    func finishExport() async { await exportTask?.value }
}
