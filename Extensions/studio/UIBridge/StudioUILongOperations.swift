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
    private struct Entry {
        let task: Task<Void, Never>
        var state: StudioUIOperationState
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
        guard !stopped, entries.count < 8 else { throw ExtensionPeerError.unavailable }
        let token = UUID()
        let state = StudioUIOperationState(
            token: token, phase: "running", progress: 0,
            result: nil, failure: nil)
        let task = Task { [weak self] in
            do {
                let result = try await work { fraction in
                    Task { @MainActor [weak self] in self?.progress(token, fraction) }
                }
                try Task.checkCancellation()
                self?.finish(token, phase: "completed", result: result, failure: nil)
            } catch is CancellationError {
                self?.finish(token, phase: "cancelled", result: nil, failure: nil)
            } catch {
                self?.finish(
                    token, phase: "failed", result: nil, failure: error.localizedDescription)
            }
        }
        entries[token] = Entry(task: task, state: state, accessed: .now)
        if timer == nil {
            timer = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(10)) } catch { return }
                    guard let self else { return }
                    for (token, entry) in self.entries
                    where entry.accessed.duration(to: .now) >= .seconds(60) {
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
            let token = UUID(uuidString: text),
            var entry = entries[token], !entry.ended
        else { throw ExtensionPeerError.invalidRequest }
        switch operation {
        case "studio.ui.work.read":
            entry.accessed = .now
            entries[token] = entry
            return try JSONEncoder().encode(entry.state)
        case "studio.ui.work.cancel": entry.task.cancel()
        case "studio.ui.work.end": end(token)
        default: throw ExtensionPeerError.invalidRequest
        }
        return Data("{}".utf8)
    }

    func stopAndWait() async {
        stopped = true
        timer?.cancel()
        timer = nil
        let owned = entries.values.map(\.task)
        for token in Array(entries.keys) { end(token) }
        for task in owned { await task.value }
        entries.removeAll()
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
        let started: StudioUIOperationState = try await read(operation, object: object)
        let handle = ["token": started.token.uuidString]
        do {
            var state = started
            while state.phase == "running" {
                try Task.checkCancellation()
                progress(state.progress)
                try await Task.sleep(for: .milliseconds(80))
                state = try await read("studio.ui.work.read", object: handle)
                guard state.token == started.token else { throw ExtensionEngineError.rejected }
            }
            let _: [String: String] = try await read("studio.ui.work.end", object: handle)
            guard state.phase == "completed", let result = state.result else {
                if state.phase == "cancelled" { throw CancellationError() }
                throw StudioUIOperationFailure(message: state.failure ?? "The operation failed.")
            }
            progress(1)
            return try JSONDecoder().decode(Value.self, from: result)
        } catch {
            Task {
                let _: [String: String]? = try? await self.read(
                    "studio.ui.work.cancel", object: handle)
                let _: [String: String]? = try? await self.read(
                    "studio.ui.work.end", object: handle)
            }
            throw error
        }
    }
}

struct StudioUIOperationFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
