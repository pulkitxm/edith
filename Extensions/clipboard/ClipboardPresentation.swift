import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import Observation
import SwiftUI

@MainActor @Observable final class ClipboardPresentation {
    var preferences = ClipboardPreferences()
    private var baseline = ClipboardPreferences()
    let preferencesLoad = ContentLoad()
    private(set) var error: String?
    let client: ClipboardClient
    let history: ClipboardHistoryModel
    private let send: @MainActor (String, Data) async throws -> Data
    private let invalidate: @MainActor () -> Void
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var tail: Task<Void, Never>?
    private let commandTasks = ClipboardTaskOwner()
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
        _ = try? await commandTasks.perform { [self] in await refreshWork() }
    }

    private func refreshWork() async {
        guard !stopped else { return }
        let current = generation
        let send = send
        await preferencesLoad.perform(operation: {
            let data = try await send("clipboard.ui.preferences", Data("{}".utf8))
            return try ClipboardMessage.decode(ClipboardPreferences.self, from: data)
        }) { next in
            guard !stopped, generation == current else { return }
            baseline = next
            if preferenceTask == nil { preferences = next }
        }
        guard !Task.isCancelled, !stopped, generation == current else { return }
        error = preferencesLoad.errorMessage
    }

    func save() {
        guard !stopped else { return }
        preferenceTask?.cancel()
        preferenceTask = commandTasks.launch { [weak self] in
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            guard let self, !Task.isCancelled, !self.stopped else { return }
            let next = self.preferences
            guard let patch = try? next.changes(from: self.baseline), patch.count > 2 else {
                self.preferenceTask = nil
                return
            }
            self.perform {
                let data = try await self.send("clipboard.ui.preferences.patch", patch)
                let saved = try ClipboardMessage.decode(ClipboardPreferences.self, from: data)
                self.baseline = saved
                if self.preferences == next { self.preferences = saved }
            }
            self.preferenceTask = nil
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

    func stopAndWait() async {
        stop()
        await commandTasks.drain()
        while let task = tasks.values.first { await task.value }
        await tail?.value
        await history.cancelAndWait()
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        generation += 1
        tasks.values.forEach { $0.cancel() }
        commandTasks.cancel()
        tail?.cancel()
        preferenceTask?.cancel()
        preferencesLoad.cancel()
        history.cancelPendingCommands()
        invalidate()
    }
}
