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
    private var actionTask: Task<Void, Never>?
    private var generation = UUID()

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

    var available: Bool { invoke != nil && !stopped }

    func refresh() async {
        guard available, !busy, let invoke else { return }
        generation = UUID()
        let token = generation
        do {
            let data = try await invoke("notch.settings.read", Data("{}".utf8))
            try apply(data, token: token)
        } catch {
            if !stopped, generation == token, !Task.isCancelled {
                self.error = error.localizedDescription
            }
        }
    }

    func set(_ key: String, value: String) {
        let request = NotchPreferenceRequest(key: key, value: value)
        guard (try? request.validate()) != nil, let data = try? JSONEncoder().encode(request) else {
            return
        }
        perform("notch.settings.write", payload: data)
    }

    func perform(_ operation: String, payload: Data = Data("{}".utf8)) {
        guard available, !busy, let invoke,
            [
                "notch.settings.write", "notch.customize", "notch.browser.detach",
                "notch.bluetooth.settings",
            ].contains(operation)
        else { return }
        generation = UUID()
        let token = generation
        busy = true
        error = nil
        actionTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.generation == token { self.busy = false; self.actionTask = nil }
            }
            do {
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
        actionTask?.cancel()
        actionTask = nil
        busy = false
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
