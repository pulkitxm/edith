import EdithExtensionSupport
import Foundation
import Observation

@MainActor @Observable final class NotchSettingsModel {
    typealias Invoke = @MainActor (String, Data) async throws -> Data
    private(set) var snapshot: NotchSettingsSnapshot
    private(set) var error: String?
    private(set) var busy = false
    private(set) var stopped = false
    private let invoke: Invoke?
    private var requests: [UUID: Task<Void, Never>] = [:]
    private var generation = UUID()
    private var pendingWrites = 0
    private var writeTail: Task<Void, Never>?

    init(client: ExtensionEngineClient?) {
        snapshot = .empty
        invoke = client.map { client in
            { operation, payload in try await client.invoke(operation, payload: payload) }
        }
    }

    init(snapshot: NotchSettingsSnapshot = .empty, invoke: @escaping Invoke) {
        self.snapshot = snapshot
        self.invoke = invoke
    }

    var saving: Bool { pendingWrites > 0 }
    var available: Bool { invoke != nil && !stopped }

    func refresh() async {
        guard available, !busy, requests.count < 8, let invoke else { return }
        generation = UUID()
        let token = generation
        let task = Task { [self] in
            defer { requests[token] = nil }
            do {
                try Task.checkCancellation()
                let data = try await invoke("notch.settings.read", Data("{}".utf8))
                try apply(data, token: token)
            } catch {
                if !stopped, generation == token, !Task.isCancelled {
                    self.error = error.localizedDescription
                }
            }
        }
        requests[token] = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func set(_ key: String, value: String) {
        let request = NotchPreferenceRequest(key: key, value: value)
        guard (try? request.validate()) != nil, let payload = try? JSONEncoder().encode(request),
            available, requests.count < 8, let invoke
        else { return }
        generation = UUID()
        snapshot.preferences[key] = value
        pendingWrites += 1
        let token = UUID()
        let previous = writeTail
        let task = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            defer {
                self.requests[token] = nil
                self.pendingWrites -= 1
            }
            do {
                try Task.checkCancellation()
                guard !self.stopped else { return }
                let data = try await invoke("notch.settings.write", payload)
                guard self.pendingWrites == 1, !self.stopped else { return }
                try self.applyLatest(data)
            } catch {
                guard !self.stopped, !Task.isCancelled else { return }
                self.error = error.localizedDescription
                if self.pendingWrites == 1 { Task { await self.refresh() } }
            }
        }
        writeTail = task
        requests[token] = task
    }

    func perform(_ operation: String, payload: Data = Data("{}".utf8)) {
        guard available, !busy, requests.count < 8, let invoke,
            [
                "notch.settings.write", "notch.customize", "notch.browser.detach",
                "notch.bluetooth.settings",
            ].contains(operation)
        else { return }
        generation = UUID()
        let token = generation
        busy = true
        error = nil
        requests[token] = Task { [weak self] in
            guard let self else { return }
            defer {
                self.requests[token] = nil
                if self.generation == token { self.busy = false }
            }
            do {
                try Task.checkCancellation()
                guard !self.stopped else { return }
                let data = try await invoke(operation, payload)
                try self.apply(data, token: token)
            } catch {
                if !self.stopped, self.generation == token, !Task.isCancelled {
                    self.error = error.localizedDescription
                }
            }
        }
    }

    func stop() {
        stopped = true
        generation = UUID()
        for task in requests.values { task.cancel() }
        busy = false
        error = nil
    }

    func stopAndWait() async {
        stop()
        let pending = Array(requests.values)
        for task in pending { await task.value }
    }

    private func applyLatest(_ data: Data) throws {
        try Task.checkCancellation()
        guard !stopped, data.count <= 65_536 else { return }
        let snapshot = try JSONDecoder().decode(NotchSettingsSnapshot.self, from: data)
        try snapshot.validate()
        self.snapshot = snapshot
        error = nil
    }

    private func apply(_ data: Data, token: UUID) throws {
        try Task.checkCancellation()
        guard !stopped, generation == token, data.count <= 65_536 else { return }
        let snapshot = try JSONDecoder().decode(NotchSettingsSnapshot.self, from: data)
        try snapshot.validate()
        self.snapshot = snapshot
        error = nil
    }
}
