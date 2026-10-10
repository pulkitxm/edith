import EdithExtensionSupport
import Foundation
import Observation
import SwiftUI

@MainActor @Observable final class ClipboardPresentation {
    var preferences = ClipboardPreferences()
    private(set) var error: String?
    let client: ClipboardClient
    let history: ClipboardHistoryModel
    private let send: @MainActor (String, Data) async throws -> Data
    private let invalidate: @MainActor () -> Void
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var tail: Task<Void, Never>?
    private var generation = 0
    private(set) var stopped = false
    let available: Bool

    convenience init(engine: ExtensionEngineClient) {
        self.init(
            send: { try await engine.invoke($0, payload: $1) }, invalidate: { engine.invalidate() })
    }

    init(
        send: @escaping @MainActor (String, Data) async throws -> Data,
        invalidate: @escaping @MainActor () -> Void = {}, available: Bool = true
    ) {
        self.available = available
        self.send = send
        self.invalidate = invalidate
        let client = ClipboardClient(send: { operation, payload in
            let permitted = [
                ClipboardServiceOperation.snapshot, ClipboardServiceOperation.thumbnail,
                ClipboardServiceOperation.mutate, ClipboardServiceOperation.cancelThumbnail,
            ]
            guard permitted.contains(operation) else { throw ExtensionPeerError.invalidRequest }
            return try await send(
                "clipboard.ui." + operation.dropFirst("clipboard.".count), payload)
        })
        self.client = client
        history = ClipboardHistoryModel(
            client: client, observesNotifications: false,
            copyRecord: { id in
                _ = try await send("clipboard.ui.copy", ClipboardMessage.encode(id))
            })
    }

    func refresh() async {
        let current = generation
        do {
            let data = try await send("clipboard.ui.preferences", Data("{}".utf8))
            let next = try ClipboardMessage.decode(ClipboardPreferences.self, from: data)
            guard !Task.isCancelled, !stopped, generation == current else { return }
            preferences = next
            error = nil
        } catch {
            guard !Task.isCancelled, !stopped, generation == current else { return }
            self.error = error.localizedDescription
        }
    }

    func save() {
        let next = preferences
        perform {
            _ = try await self.send("clipboard.ui.preferences.set", ClipboardMessage.encode(next))
        }
    }

    func action(_ name: String) {
        guard ["clipboard.ui.palette", "clipboard.ui.permission"].contains(name) else { return }
        perform {
            _ = try await self.send(name, Data("{}".utf8)); await self.refresh()
        }
    }

    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        guard !stopped else { return }
        let id = UUID()
        let current = generation
        let previous = tail
        let task = Task { [weak self] in
            defer { self?.tasks[id] = nil }
            await previous?.value
            do {
                try Task.checkCancellation()
                try await action()
                guard !Task.isCancelled, self?.generation == current, self?.stopped == false else {
                    return
                }
                self?.error = nil
            } catch {
                guard !Task.isCancelled, self?.generation == current, self?.stopped == false else {
                    return
                }
                self?.error = error.localizedDescription
            }
        }
        tasks[id] = task
        tail = task
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        generation += 1
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
        tail?.cancel(); tail = nil
        history.stop()
        invalidate()
    }
}
