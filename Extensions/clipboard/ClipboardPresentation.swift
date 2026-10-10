import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import Observation
import SwiftUI

@MainActor @Observable final class ClipboardPresentation {
    var preferences = ClipboardPreferences()
    let preferencesLoad = ContentLoad()
    private(set) var error: String?
    let client: ClipboardClient
    let history: ClipboardHistoryModel
    private let send: @MainActor (String, Data) async throws -> Data
    private let invalidate: @MainActor () -> Void
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var tail: Task<Void, Never>?
    private var preferenceTask: Task<Void, Never>?
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
        guard !stopped else { return }
        let current = generation
        let send = send
        await preferencesLoad.perform(operation: {
            let data = try await send("clipboard.ui.preferences", Data("{}".utf8))
            return try ClipboardMessage.decode(ClipboardPreferences.self, from: data)
        }) { next in
            guard !stopped, generation == current else { return }
            preferences = next
        }
        guard !Task.isCancelled, !stopped, generation == current else { return }
        error = preferencesLoad.errorMessage
    }

    func save() {
        guard !stopped else { return }
        preferenceTask?.cancel()
        let next = preferences
        preferenceTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            guard let self, !Task.isCancelled, !self.stopped else { return }
            self.perform {
                _ = try await self.send(
                    "clipboard.ui.preferences.set", ClipboardMessage.encode(next))
            }
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
        guard tasks.count < 8 else { error = "Clipboard changes are still being saved."; return }
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
        preferenceTask?.cancel(); preferenceTask = nil
        preferencesLoad.reset()
        history.stop(discardContent: true)
        invalidate()
    }
}
