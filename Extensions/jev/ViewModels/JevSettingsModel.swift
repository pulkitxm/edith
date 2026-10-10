import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import Observation

@MainActor
@Observable
final class JevSettingsModel {
    var status: JevStatus?
    var draft = ""
    let loading = ContentLoad()
    private let read: (Bool) async throws -> JevStatus
    private let write: (String?) async throws -> JevStatus
    private var task: Task<Void, Never>?
    private var stopped = false

    init(engine: JevEngine) {
        read = { await engine.status(probe: $0) }
        write = {
            await engine.setKey($0); return await engine.status(probe: false)
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
            let data = try await engineClient.invoke("jev.key.set", payload: payload)
            return try JSONDecoder().decode(JevStatus.self, from: data)
        }
    }

    func load(probe: Bool) { begin { try await self.read(probe) } }

    func save() {
        let value = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        begin {
            return try await self.write(value)
        }
        draft = ""
    }

    func remove() {
        begin {
            return try await self.write(nil)
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        loading.cancel()
    }

    func shutdown() {
        stopped = true
        cancel()
        draft = ""
    }

    private func begin(_ operation: @escaping @MainActor () async throws -> JevStatus) {
        guard !stopped else { return }
        cancel()
        let generation = loading.begin()
        task = Task { [weak self] in
            do {
                let status = try await operation()
                guard let self, !self.stopped, self.loading.isCurrent(generation) else { return }
                self.status = status
                self.loading.complete(generation)
                self.task = nil
            } catch {
                guard let self, !self.stopped, self.loading.owns(generation) else { return }
                self.loading.fail(generation, error: error)
                self.task = nil
            }
        }
    }
}
