import EdithExtensionSupport
import EdithExtensionCommands
import Foundation

@available(macOS 15.0, *)
@MainActor
final class StudioRecordBridge {
    static let shared = StudioRecordBridge()

    private let recorder = VideoRecorder()
    var startedAt: Date? { recorder.startedAt }
    var busy: Bool { recorder.busy }
    var error: String? { recorder.error }
    private var finishedURL: URL?
    private var stopWait: CheckedContinuation<Void, Never>?
    private var settled = false

    func shutdown() async {
        await recorder.shutdown()
        complete(nil)
    }

    func perform(
        _ request: StudioRecordRequest, source: String = "", systemAudio: Bool = true,
        microphone: Bool = false, showCursor: Bool = true
    ) async throws -> StudioRecordSnapshot {
        try Task.checkCancellation()
        switch request {
        case .sources:
            await recorder.loadSources()
            if let error = recorder.error { throw CLIFailure(error) }
            return snapshot(changed: false)
        case .status:
            return snapshot(changed: false)
        case .start:
            guard !recorder.recording else {
                throw CLIFailure("A recording is already in progress.")
            }
            if recorder.displays.isEmpty && recorder.windows.isEmpty {
                await recorder.loadSources()
            }
            try Task.checkCancellation()
            recorder.systemAudio = systemAudio
            recorder.microphone = microphone
            recorder.showCursor = showCursor
            recorder.source = resolve(source)
            finishedURL = nil
            settled = false
            await recorder.start { [weak self] url in
                MainActor.assumeIsolated { self?.complete(url) }
            }
            if Task.isCancelled {
                await recorder.shutdown()
                complete(nil)
                throw CancellationError()
            }
            guard recorder.recording, recorder.error == nil else {
                throw CLIFailure(recorder.error ?? "The recording did not start.")
            }
            return snapshot(changed: true)
        case .stop:
            guard recorder.recording else { throw CLIFailure("Nothing is recording.") }
            guard stopWait == nil else { throw CLIFailure("The recording is already stopping.") }
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    stopWait = continuation
                    Task { @MainActor in
                        await self.recorder.stop()
                        if self.recorder.error != nil { self.complete(nil) }
                    }
                }
            } onCancel: {
                Task { @MainActor in await self.shutdown() }
            }
            try Task.checkCancellation()
            guard finishedURL != nil else {
                throw CLIFailure(recorder.error ?? "The recording did not finish.")
            }
            return snapshot(changed: true)
        }
    }

    private func complete(_ url: URL?) {
        guard !settled else { return }
        settled = true
        finishedURL = url
        stopWait?.resume()
        stopWait = nil
    }

    private func resolve(_ requested: String) -> String {
        let trimmed = requested.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty, let display = recorder.displays.first {
            return "display:\(display.displayID)"
        }
        if trimmed.hasPrefix("display:") || trimmed.hasPrefix("window:") { return trimmed }
        if recorder.displays.contains(where: { "\($0.displayID)" == trimmed }) {
            return "display:\(trimmed)"
        }
        if recorder.windows.contains(where: { "\($0.windowID)" == trimmed }) {
            return "window:\(trimmed)"
        }
        return trimmed
    }

    private func snapshot(changed: Bool) -> StudioRecordSnapshot {
        var sources: [StudioRecordSource] = []
        for (index, display) in recorder.displays.enumerated() {
            sources.append(
                StudioRecordSource(
                    id: "display:\(display.displayID)", kind: "display",
                    title: "Display \(index + 1)"))
        }
        for window in recorder.windows {
            let owner = window.owningApplication?.applicationName ?? "App"
            let title = window.title ?? "Window"
            sources.append(
                StudioRecordSource(
                    id: "window:\(window.windowID)", kind: "window", title: "\(owner): \(title)"))
        }
        return StudioRecordSnapshot(
            sources: sources, recording: recorder.recording, source: recorder.source,
            systemAudio: recorder.systemAudio, microphone: recorder.microphone,
            showCursor: recorder.showCursor, output: finishedURL?.path, changed: changed)
    }
}
