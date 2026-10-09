import EdithExtensionUI
import Foundation
import Observation

@MainActor
@Observable
final class JevSettingsModel {
    var status: JevStatus?
    var draft = ""
    let loading = ContentLoad()
    private let engine: JevEngine
    private var task: Task<Void, Never>?
    private var stopped = false

    init(engine: JevEngine) { self.engine = engine }

    func load(probe: Bool) { begin { await self.engine.status(probe: probe) } }

    func save() {
        let value = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        begin {
            await self.engine.setKey(value)
            return await self.engine.status(probe: false)
        }
        draft = ""
    }

    func remove() {
        begin {
            await self.engine.setKey(nil)
            return await self.engine.status(probe: false)
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

    private func begin(_ operation: @escaping @MainActor () async -> JevStatus) {
        guard !stopped else { return }
        cancel()
        let generation = loading.begin()
        task = Task { [weak self] in
            let status = await operation()
            guard let self, !self.stopped, self.loading.isCurrent(generation) else { return }
            self.status = status
            self.loading.complete(generation)
            self.task = nil
        }
    }
}
