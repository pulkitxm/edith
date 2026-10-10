import EdithExtensionSupport
import Foundation

struct StudioUIOperationState: Codable, Sendable {
    let token: UUID
    let phase: String
    let progress: Double
    let result: Data?
    let failure: String?
}

@MainActor final class StudioUILongOperations {
    @TaskLocal nonisolated static var requestedToken: UUID?
    private var cancelled: [UUID: ContinuousClock.Instant] = [:]

    static func scoped<Value>(payload: Data, operation: @MainActor (Data) async throws -> Value)
        async throws -> Value
    {
        guard payload.count <= StudioCommands.maximumRequestBytes,
            var object = try JSONSerialization.jsonObject(with: payload) as? [String: Any]
        else { throw ExtensionPeerError.invalidRequest }
        guard let value = object.removeValue(forKey: "workToken") else {
            return try await operation(payload)
        }
        guard let text = value as? String, let token = UUID(uuidString: text) else {
            throw ExtensionPeerError.invalidRequest
        }
        let body = try JSONSerialization.data(
            withJSONObject: object, options: [.withoutEscapingSlashes])
        return try await $requestedToken.withValue(token) { try await operation(body) }
    }

    private struct Entry {
        let task: Task<Void, Never>
        var state: StudioUIOperationState
        let started: ContinuousClock.Instant
        var accessed: ContinuousClock.Instant
        var ended = false
    }
    private var entries: [UUID: Entry] = [:]
    private var stopped = false
    private var timer: Task<Void, Never>?

    deinit {
        timer?.cancel()
        for entry in entries.values { entry.task.cancel() }
    }

    func start(
        _ work: @escaping @MainActor (@escaping @Sendable (Double) -> Void) async throws -> Data
    )
        throws -> StudioUIOperationState
    {
        try Task.checkCancellation()
        pruneCancelled()
        let token = Self.requestedToken ?? UUID()
        guard cancelled[token] == nil else { throw CancellationError() }
        guard !stopped, entries.count < 8, entries[token] == nil else {
            throw ExtensionPeerError.unavailable
        }
        let state = StudioUIOperationState(
            token: token, phase: "running", progress: 0,
            result: nil, failure: nil)
        let task = Task { [weak self] in
            do {
                let result = try await work { fraction in
                    Task { @MainActor [weak self] in self?.progress(token, fraction) }
                }
                try Task.checkCancellation()
                guard result.count <= ExtensionEngineWire.maximumPayloadBytes else {
                    throw ExtensionPeerError.invalidRequest
                }
                self?.finish(token, phase: "completed", result: result, failure: nil)
            } catch is CancellationError {
                self?.finish(token, phase: "cancelled", result: nil, failure: nil)
            } catch {
                self?.finish(
                    token, phase: "failed", result: nil, failure: error.localizedDescription)
            }
        }
        entries[token] = Entry(task: task, state: state, started: .now, accessed: .now)
        if timer == nil {
            timer = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(10)) } catch { return }
                    guard let self else { return }
                    self.pruneCancelled()
                    for (token, entry) in self.entries
                    where entry.accessed.duration(to: .now) >= .seconds(60)
                        || entry.started.duration(to: .now) >= .seconds(21_600)
                    {
                        self.end(token)
                    }
                }
            }
        }
        return state
    }

    func invoke(_ operation: String, payload: Data) throws -> Data {
        guard !stopped, payload.count <= 256,
            let object = try JSONSerialization.jsonObject(with: payload) as? [String: String],
            Set(object.keys) == ["token"], let text = object["token"],
            let token = UUID(uuidString: text)
        else { throw ExtensionPeerError.invalidRequest }
        pruneCancelled()
        switch operation {
        case "studio.ui.work.read":
            guard var entry = entries[token], !entry.ended else {
                throw ExtensionPeerError.invalidRequest
            }
            entry.accessed = .now; entries[token] = entry
            return try JSONEncoder().encode(entry.state)
        case "studio.ui.work.cancel", "studio.ui.work.end":
            if entries[token] == nil {
                guard cancelled[token] != nil || cancelled.count < 128 else {
                    throw ExtensionPeerError.unavailable
                }
                cancelled[token] = .now
            } else if operation == "studio.ui.work.cancel" {
                entries[token]?.task.cancel()
            } else {
                end(token)
            }
        default: throw ExtensionPeerError.invalidRequest
        }
        return Data("{}".utf8)
    }

    private func pruneCancelled() {
        cancelled = cancelled.filter { $0.value.duration(to: .now) < .seconds(60) }
    }

    func stopAndWait() async {
        stopped = true
        timer?.cancel()
        timer = nil
        let owned = entries.values.map(\.task)
        for token in Array(entries.keys) { end(token) }
        for task in owned { await task.value }
        entries.removeAll(); cancelled.removeAll()
    }

    private func progress(_ token: UUID, _ fraction: Double) {
        guard let entry = entries[token], !entry.ended, entry.state.phase == "running",
            fraction.isFinite
        else { return }
        entries[token]?.state = StudioUIOperationState(
            token: token, phase: "running",
            progress: max(entry.state.progress, min(max(fraction, 0), 1)), result: nil, failure: nil
        )
    }

    private func finish(_ token: UUID, phase: String, result: Data?, failure: String?) {
        guard let entry = entries[token] else { return }
        if entry.ended { entries[token] = nil; return }
        entries[token]?.state = StudioUIOperationState(
            token: token, phase: phase,
            progress: phase == "completed" ? 1 : entry.state.progress, result: result,
            failure: failure)
    }

    private func end(_ token: UUID) {
        guard var entry = entries[token] else { return }
        entry.task.cancel()
        if entry.state.phase == "running" {
            entry.ended = true; entries[token] = entry
        } else {
            entries[token] = nil
        }
    }
}

extension StudioUIFacade {
    func perform<Value: Decodable>(
        _ operation: String, object: [String: Any],
        progress: @escaping @MainActor (Double) -> Void = { _ in }
    ) async throws -> Value {
        let token = UUID()
        var request = object; request["workToken"] = token.uuidString
        let handle = ["token": token.uuidString]
        activeWork.insert(token)
        defer { activeWork.remove(token) }
        do {
            let started: StudioUIOperationState = try await read(operation, object: request)
            guard started.token == token else { throw ExtensionEngineError.rejected }
            var state = started
            while state.phase == "running" {
                try Task.checkCancellation()
                progress(state.progress)
                try await Task.sleep(for: .milliseconds(80))
                state = try await read("studio.ui.work.read", object: handle)
                guard state.token == token else { throw ExtensionEngineError.rejected }
            }
            let _: [String: String] = try await read("studio.ui.work.end", object: handle)
            guard state.phase == "completed", let result = state.result else {
                if state.phase == "cancelled" { throw CancellationError() }
                throw StudioUIOperationFailure(message: state.failure ?? "The operation failed.")
            }
            progress(1)
            return try JSONDecoder().decode(Value.self, from: result)
        } catch {
            cleanup("studio.ui.work.cancel", object: handle)
            cleanup("studio.ui.work.end", object: handle)
            throw error
        }
    }
}

struct StudioUIOperationFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
