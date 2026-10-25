import EdithExtensionSupport
import Foundation
import Observation

@MainActor
@Observable
final class JevSettingsModel {
    enum Phase: Equatable {
        case idle
        case loading
        case saving
        case failed(String)
    }

    var status: JevStatus?
    var phase: Phase = .idle
    var draft = ""
    private let read: (Bool) async throws -> JevStatus
    private let write: (String?) async throws -> JevStatus
    private var task: Task<Void, Never>?
    private var generation = 0
    private var stopped = false

    init(engine: JevEngine) {
        read = { await engine.status(probe: $0) }
        write = {
            await engine.setKey($0); return await engine.status(probe: $0 != nil)
        }
    }

    init(engineClient: ExtensionEngineClient) {
        read = { probe in
            let payload = try JSONEncoder().encode(JevStatusQuery(probe: probe))
            let data = try await engineClient.invoke("jev.status", payload: payload)
            return try JSONDecoder().decode(JevStatus.self, from: data)
        }
        write = { key in
            let payload = try JSONEncoder().encode(JevKeyUpdate(key: key))
            let data = try await engineClient.invoke("jev.key.set", payload: payload, timeout: 24)
            return try JSONDecoder().decode(JevStatus.self, from: data)
        }
    }

    var isBusy: Bool { phase == .loading || phase == .saving }

    func load(probe: Bool) {
        guard !stopped, phase != .saving else { return }
        run(.loading, clearsDraft: false) { try await self.read(probe) }
    }

    func save() {
        let value = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !stopped else { return }
        run(.saving, clearsDraft: true) { try await self.write(value) }
    }

    func remove() {
        guard !stopped else { return }
        run(.saving, clearsDraft: false) { try await self.write(nil) }
    }

    func cancel() {
        guard phase == .loading else { return }
        task?.cancel()
        task = nil
        generation += 1
        phase = .idle
    }

    func shutdown() {
        stopped = true
        task?.cancel()
        task = nil
        generation += 1
        draft = ""
    }

    private func run(
        _ next: Phase, clearsDraft: Bool,
        _ operation: @escaping @MainActor () async throws -> JevStatus
    ) {
        if phase == .loading { task?.cancel() }
        generation += 1
        let current = generation
        phase = next
        task = Task { [weak self] in
            do {
                let status = try await operation()
                guard let self, !self.stopped, self.generation == current else { return }
                self.status = status
                if clearsDraft { self.draft = "" }
                self.phase = .idle
            } catch {
                guard let self, !self.stopped, self.generation == current else { return }
                self.phase = .failed(error.localizedDescription)
            }
            if let self, self.generation == current { self.task = nil }
        }
    }
}
