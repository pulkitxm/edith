import EdithKit
import Foundation

enum StudioRecordInstaller {
    @MainActor
    static func install() {
        if #available(macOS 15.0, *) {
            StudioRecordBridge.shared.install()
        } else {
            StudioRecordFallback.install()
        }
    }
}

private enum StudioRecordFallback {
    static var token: NSObjectProtocol?

    static func install() {
        guard token == nil else { return }
        token = IPC.observe(
            IPC.Name.requestStudioRecord,
            info: { info in
                MainActor.assumeIsolated {
                    guard let runtime = StudioRecordRuntimeRequest(payload: info) else { return }
                    StudioRecordReply.send(
                        requestID: runtime.requestID, ok: false, snapshot: nil,
                        error: "Screen recording needs macOS 15 or later.")
                }
            })
    }
}

@available(macOS 15.0, *)
@MainActor
final class StudioRecordBridge {
    static let shared = StudioRecordBridge()

    private let recorder = VideoRecorder()
    private var token: NSObjectProtocol?
    private var finishedURL: URL?
    private var stopWait: CheckedContinuation<Void, Never>?
    private var settled = false

    func install() {
        guard token == nil else { return }
        token = IPC.observe(
            IPC.Name.requestStudioRecord,
            info: { [weak self] info in
                Task { @MainActor in await self?.receive(info) }
            })
    }

    private func receive(_ info: [AnyHashable: Any]) async {
        guard let runtime = StudioRecordRuntimeRequest(payload: info) else { return }
        guard runtime.isLive(at: Date()) else {
            StudioRecordReply.send(
                requestID: runtime.requestID, ok: false, snapshot: nil,
                error: "The recording request expired before it ran.")
            return
        }
        switch runtime.request {
        case .sources:
            await recorder.loadSources()
            let failure = recorder.error
            StudioRecordReply.send(
                requestID: runtime.requestID, ok: failure == nil,
                snapshot: snapshot(changed: false),
                error: failure)
        case .status:
            StudioRecordReply.send(
                requestID: runtime.requestID, ok: true, snapshot: snapshot(changed: false),
                error: nil)
        case .start:
            await begin(runtime)
        case .stop:
            await end(runtime.requestID)
        }
    }

    private func begin(_ runtime: StudioRecordRuntimeRequest) async {
        if recorder.recording {
            StudioRecordReply.send(
                requestID: runtime.requestID, ok: false, snapshot: snapshot(changed: false),
                error: "A recording is already in progress.")
            return
        }
        if recorder.displays.isEmpty && recorder.windows.isEmpty {
            await recorder.loadSources()
        }
        recorder.systemAudio = runtime.systemAudio
        recorder.microphone = runtime.microphone
        recorder.showCursor = runtime.showCursor
        recorder.source = resolve(runtime.source)
        finishedURL = nil
        settled = false
        await recorder.start { [weak self] url in
            MainActor.assumeIsolated { self?.complete(url) }
        }
        StudioRecordReply.send(
            requestID: runtime.requestID, ok: recorder.error == nil && recorder.recording,
            snapshot: snapshot(changed: recorder.recording), error: recorder.error)
    }

    private func end(_ requestID: String) async {
        guard recorder.recording else {
            StudioRecordReply.send(
                requestID: requestID, ok: false, snapshot: snapshot(changed: false),
                error: "Nothing is recording.")
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            stopWait = continuation
            Task { @MainActor in
                await self.recorder.stop()
                if self.recorder.error != nil { self.complete(nil) }
            }
        }
        StudioRecordReply.send(
            requestID: requestID, ok: finishedURL != nil,
            snapshot: snapshot(changed: finishedURL != nil),
            error: finishedURL == nil ? recorder.error ?? "The recording did not finish." : nil)
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

enum StudioRecordReply {
    static func send(
        requestID: String, ok: Bool, snapshot: StudioRecordSnapshot?, error: String?
    ) {
        var payload: [String: Any] = [
            StudioRecordIPC.requestIDKey: requestID, StudioRecordIPC.okKey: ok,
        ]
        if let encoded = snapshot?.encoded() { payload[StudioRecordIPC.snapshotKey] = encoded }
        if let error { payload[StudioRecordIPC.errorKey] = error }
        IPC.post(IPC.Name.studioRecordResult, userInfo: payload)
    }
}
