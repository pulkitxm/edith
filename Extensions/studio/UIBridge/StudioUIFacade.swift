import EdithExtensionSupport
import Foundation
import Observation

@MainActor @Observable final class StudioUIFacade {
    typealias Invoke = @MainActor (String, Data) async throws -> Data
    private let invoke: Invoke
    private let invalidate: @MainActor () -> Void
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var versions: [String: UUID] = [:]
    private(set) var isStopped = false
    private(set) var state: StudioUIState?
    private(set) var failure: String?

    init(client: ExtensionEngineClient) {
        invoke = { operation, payload in try await client.invoke(operation, payload: payload) }
        invalidate = { client.invalidate() }
    }

    init(invoke: @escaping Invoke, invalidate: @escaping @MainActor () -> Void = {}) {
        self.invoke = invoke
        self.invalidate = invalidate
    }

    func refresh() {
        submit("state") { [weak self] in
            guard let self else { return nil }
            let value: StudioUIState = try await self.read("studio.ui.state")
            return {
                self.state = value; self.failure = nil
            }
        }
    }

    func add(_ urls: [URL]) {
        mutate("studio.library.add", object: ["paths": urls.map(\.path)])
    }

    func remove(_ urls: Set<URL>) {
        mutate("studio.library.remove", object: ["paths": urls.map(\.path)])
    }

    func clearMissing() {
        mutate("studio.ui.clearMissing")
    }

    func facts(_ url: URL) async throws -> StudioFileFacts {
        let value: StudioUIFileFacts = try await read("studio.ui.facts", object: ["path": url.path])
        return value.value
    }

    func read<Value: Decodable>(_ operation: String, object: [String: Any] = [:]) async throws
        -> Value
    {
        guard !isStopped else { throw ExtensionEngineError.unavailable }
        let payload = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard payload.count <= StudioCommands.maximumRequestBytes else {
            throw ExtensionEngineError.rejected
        }
        let data = try await invoke(operation, payload)
        try Task.checkCancellation()
        guard !isStopped, data.count <= ExtensionEngineWire.maximumPayloadBytes else {
            throw ExtensionEngineError.unavailable
        }
        return try JSONDecoder().decode(Value.self, from: data)
    }

    func stop() {
        guard !isStopped else { return }
        isStopped = true
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
        versions.removeAll()
        invalidate()
    }

    private func mutate(_ operation: String, object: [String: Any] = [:]) {
        submit(UUID().uuidString) { [weak self] in
            guard let self else { return nil }
            let _: [StudioMediaItem] = try await self.read(operation, object: object)
            return { self.refresh() }
        }
    }

    private func submit(
        _ key: String, work: @escaping @MainActor () async throws -> (@MainActor () -> Void)?
    ) {
        guard !isStopped else { return }
        let version = UUID()
        if let previous = versions[key] { tasks[previous]?.cancel(); tasks[previous] = nil }
        versions[key] = version
        tasks[version] = Task { [weak self] in
            defer {
                self?.tasks[version] = nil
                if self?.versions[key] == version { self?.versions[key] = nil }
            }
            do {
                let apply = try await work()
                guard let self, !self.isStopped, !Task.isCancelled, self.versions[key] == version
                else { return }
                apply?()
            } catch {
                guard let self, !self.isStopped, !Task.isCancelled, self.versions[key] == version
                else { return }
                self.failure = error.localizedDescription
            }
        }
    }
}
