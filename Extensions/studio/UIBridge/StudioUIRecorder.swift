import EdithExtensionSupport
import Foundation
import Observation

struct StudioUIRecordingState: Codable, Sendable {
    let snapshot: StudioRecordSnapshot
    let startedAt: Date?
    let busy: Bool
    let error: String?
    let owned: Bool
}

@MainActor final class StudioUIRecorderCommands {
    private var owner: UUID?
    private let fields: [String: Set<String>] = [
        "studio.ui.record.status": ["id"], "studio.ui.record.sources": ["id"],
        "studio.ui.record.start": ["id", "source", "systemAudio", "microphone", "showCursor"],
        "studio.ui.record.stop": ["id"], "studio.ui.record.close": ["id"],
    ]
    func execute(_ operation: String, payload: Data, work: StudioUILongOperations) async throws
        -> Data
    {
        try await StudioUILongOperations.scoped(payload: payload) { body in
            try await self.executeBody(operation, payload: body, work: work)
        }
    }

    private func executeBody(_ operation: String, payload: Data, work: StudioUILongOperations)
        async throws
        -> Data
    {
        guard #available(macOS 15.0, *) else {
            throw StudioUIOperationFailure(message: "Screen recording requires macOS 15 or newer.")
        }
        guard let allowed = fields[operation], payload.count <= StudioCommands.maximumRequestBytes,
            let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
            Set(object.keys).isSubset(of: allowed),
            let text = object["id"] as? String, let id = UUID(uuidString: text)
        else { throw ExtensionPeerError.invalidRequest }
        let bridge = StudioRecordBridge.shared
        let encoder = JSONEncoder()
        if operation == "studio.ui.record.close" {
            if owner == id { await bridge.shutdown(); owner = nil }
            return Data("{}".utf8)
        }
        if operation == "studio.ui.record.status" {
            let snapshot = try await bridge.perform(.status)
            return try encoder.encode(
                StudioUIRecordingState(
                    snapshot: snapshot, startedAt: bridge.startedAt, busy: bridge.busy,
                    error: bridge.error, owned: owner == id))
        }
        var source = ""; var systemAudio = true; var microphone = false; var showCursor = true
        if operation == "studio.ui.record.start" {
            guard owner == nil, let selected = object["source"] as? String,
                selected.utf8.count <= 4096,
                let system = object["systemAudio"] as? Bool,
                let mic = object["microphone"] as? Bool,
                let cursor = object["showCursor"] as? Bool
            else { throw ExtensionPeerError.invalidRequest }
            source = selected; systemAudio = system; microphone = mic; showCursor = cursor
            owner = id
        }
        if operation == "studio.ui.record.stop", owner != id {
            throw ExtensionPeerError.invalidRequest
        }
        let request: StudioRecordRequest =
            operation == "studio.ui.record.sources"
            ? .sources : operation == "studio.ui.record.start" ? .start : .stop
        do {
            let state = try work.start { _ in
                do {
                    let snapshot = try await bridge.perform(
                        request, source: source, systemAudio: systemAudio, microphone: microphone,
                        showCursor: showCursor)
                    if request == .stop { self.owner = nil }
                    return try encoder.encode(
                        StudioUIRecordingState(
                            snapshot: snapshot, startedAt: bridge.startedAt, busy: bridge.busy,
                            error: bridge.error, owned: self.owner == id))
                } catch {
                    if request != .sources, self.owner == id { self.owner = nil }
                    throw error
                }
            }
            return try encoder.encode(state)
        } catch {
            if request == .start, owner == id { owner = nil }
            throw error
        }
    }
}

@MainActor @Observable final class StudioUIRecorder {
    var sources: [StudioRecordSource] = []
    var source = ""
    var systemAudio = true
    var microphone = false
    var showCursor = true
    var recording = false
    var busy = false
    var error: String?
    var startedAt: Date?
    private let id = UUID()
    private var facade: StudioUIFacade?
    @ObservationIgnored nonisolated(unsafe) private var task: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) private var polling: Task<Void, Never>?
    private var closed = false
    private var completion: ((URL) -> Void)?
    deinit { task?.cancel(); polling?.cancel() }
    func configure(_ facade: StudioUIFacade?) { self.facade = facade }
    func loadSources() async { await perform("sources") }
    func start(finished: @escaping (URL) -> Void) async {
        completion = finished; await perform("start")
    }
    func stop() async { await perform("stop") }
    func shutdown() async {
        closed = true; task?.cancel(); polling?.cancel(); completion = nil
        facade?.cleanup("studio.ui.record.close", object: ["id": id.uuidString])
    }
    private func perform(_ action: String) async {
        guard let facade, !closed, !busy else { return }
        busy = true
        let owned = Task {
            try await facade.perform(
                "studio.ui.record.\(action)",
                object: action == "start"
                    ? [
                        "id": id.uuidString, "source": source, "systemAudio": systemAudio,
                        "microphone": microphone, "showCursor": showCursor,
                    ] : ["id": id.uuidString]) as StudioUIRecordingState
        }
        task = Task { [weak self] in
            await withTaskCancellationHandler {
                do {
                    let state = try await owned.value
                    try Task.checkCancellation()
                    guard let self, !self.closed else { return }
                    self.apply(state); self.busy = false; self.error = state.error
                    if action == "stop", let output = state.snapshot.output {
                        self.completion?(URL(fileURLWithPath: output)); self.completion = nil
                    }
                    if self.recording { self.observe() }
                } catch {
                    if let self, !self.closed, !Task.isCancelled {
                        self.busy = false; self.error = error.localizedDescription
                    }
                }
            } onCancel: {
                owned.cancel()
            }
        }
        await withTaskCancellationHandler {
            await task?.value
        } onCancel: {
            owned.cancel()
        }
    }
    private func apply(_ state: StudioUIRecordingState) {
        sources = state.snapshot.sources
        if source.isEmpty { source = state.snapshot.source }
        recording = state.snapshot.recording && state.owned
        startedAt = state.startedAt
    }
    private func observe() {
        guard polling == nil else { return }
        polling = Task { [weak self] in
            guard let self else { return }
            defer { polling = nil }
            while !Task.isCancelled, !closed, recording {
                do {
                    try await Task.sleep(for: .milliseconds(500))
                    guard let facade else { return }
                    let state: StudioUIRecordingState = try await facade.read(
                        "studio.ui.record.status", object: ["id": id.uuidString])
                    guard !Task.isCancelled, !closed else { return }
                    apply(state); error = state.error
                } catch { if !Task.isCancelled { self.error = error.localizedDescription }; return }
            }
        }
    }
}
