import EdithExtensionSupport
import EdithExtensionUI
import Foundation

@MainActor
final class CompanionWorkspaceSession {
    let home = CompanionHomeModel()
    let chat = CompanionChatModel()
    let capture: CompanionCaptureModel
    let library = CompanionLibraryModel()
    let mind = CompanionMindModel()
    let desk = CompanionDeskModel()
    let backend: CompanionBackendModel
    let settings = CompanionSettingsModel()
    let privacy: SurfacePrivacyState?
    let preferences: CompanionUIPreferences?
    private(set) var isStopped = false

    init(privacy: SurfacePrivacyState? = nil, remote: CompanionUIBridge? = nil) {
        self.privacy = privacy
        preferences = remote.map(CompanionUIPreferences.init)
        capture = CompanionCaptureModel(remote: remote)
        backend = CompanionBackendModel(remote: remote)
    }

    func shutdown() {
        guard !isStopped else { return }
        isStopped = true
        preferences?.shutdown()
        home.loading.reset(); chat.loading.reset(); chat.messageLoad.reset()
        library.shutdown(); mind.loading.reset(); desk.loading.reset(); settings.loading.reset()
        chat.stop()
        capture.shutdown()
        backend.shutdown()
        CompanionGeneration.stopAll()
        privacy?.shutdown()
    }

    deinit {
        let chat = chat
        Task { @MainActor in chat.stop() }
    }
}

@MainActor
final class CompanionTaskOwner {
    private struct Entry {
        let task: Task<Void, Never>
        let cancel: @Sendable () -> Void
    }

    private var entries: [UUID: Entry] = [:]
    private(set) var closed = false

    func launch(_ work: @escaping @MainActor () async -> Void) -> Task<Void, Never>? {
        guard !closed, entries.count < 256 else { return nil }
        let id = UUID()
        let task = Task {
            defer { entries[id] = nil }
            await work()
        }
        entries[id] = Entry(task: task, cancel: { task.cancel() })
        return task
    }

    func perform<Value: Sendable>(
        _ work: @escaping @MainActor () async throws -> Value
    ) async throws -> Value {
        guard !closed, entries.count < 256 else { throw CancellationError() }
        let id = UUID()
        let task = Task { try await work() }
        let joined = Task {
            _ = await task.result
            entries[id] = nil
        }
        entries[id] = Entry(task: joined, cancel: { task.cancel() })
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func cancel() {
        closed = true
        for entry in entries.values { entry.cancel() }
    }

    func drain() async {
        cancel()
        while let entry = entries.values.first { await entry.task.value }
    }
}
