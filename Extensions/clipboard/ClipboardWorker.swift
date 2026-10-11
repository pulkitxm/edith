import EdithExtensionSupport
import EdithExtensionCommands
import EdithExtensionUI
import Foundation

@MainActor final class ClipboardWorker {
    let service: ClipboardService
    let client: ClipboardClient
    let store: ClipboardStore
    let history: ClipboardHistoryModel
    let panel = ClipboardPanel()
    private(set) var isStopped = false
    private let defaults: UserDefaults
    private let allowsSystemActions: Bool
    private let copyRecord: @MainActor (ClipboardCopyPayload) throws -> Void

    init(
        service: ClipboardService = .init(), defaults: UserDefaults = SharedDefaults.store,
        capturesPasteboard: Bool = true,
        allowsSystemActions: Bool = true,
        copyRecord: @escaping @MainActor (ClipboardCopyPayload) throws -> Void = {
            ClipboardRepository.copyToPasteboard($0, pasteboard: .general)
        }
    ) {
        self.defaults = defaults
        self.allowsSystemActions = allowsSystemActions
        self.copyRecord = copyRecord
        self.service = service
        client = ClipboardClient(service: service)
        store = ClipboardStore(client: client, capturesPasteboard: capturesPasteboard)
        history = ClipboardHistoryModel(client: client)
        panel.store = store
    }

    func execute(_ command: String, payload: Data) async throws -> Data {
        guard !isStopped else { throw ExtensionPeerError.unavailable }
        if [
            "clipboard.ui.snapshot", "clipboard.ui.thumbnail", "clipboard.ui.mutate",
            "clipboard.ui.copy", "clipboard.ui.palette",
        ].contains(command) {
            guard
                !SurfacePrivacyState.hides(
                    .ability("clipboard"),
                    values: ExtensionSharedState.current?.values(for: "presenter") ?? [:])
            else {
                throw ExtensionPeerError.rejected(
                    "Clipboard history is hidden by privacy settings.")
            }
        }
        if [
            "clipboard.ui.snapshot", "clipboard.ui.thumbnail", "clipboard.ui.mutate",
            "clipboard.ui.thumbnail.cancel",
        ].contains(command) {
            let operation = command.replacingOccurrences(of: "clipboard.ui.", with: "clipboard.")
            let value = try await service.perform(operation: operation, payload: payload)
            return value.isEmpty ? Data("{}".utf8) : value
        }
        if command == "clipboard.ui.preferences" {
            try validateEmpty(payload)
            return try ClipboardMessage.encode(ClipboardPreferences.read(defaults))
        }
        if command == "clipboard.ui.preferences.set" {
            guard payload.count <= 16_384 else { throw ExtensionPeerError.invalidRequest }
            try ClipboardMessage.decode(ClipboardPreferences.self, from: payload).save(
                defaults)
            return try ClipboardMessage.encode(ClipboardPreferences.read(defaults))
        }
        if command == "clipboard.ui.copy" {
            guard payload.count <= 128 else { throw ExtensionPeerError.invalidRequest }
            let id = try ClipboardMessage.decode(String.self, from: payload)
            guard UUID(uuidString: id) != nil else { throw ExtensionPeerError.invalidRequest }
            let plain = defaults.bool(forKey: AppStorageKeys.Clipboard.pastePlainText)
            let copy = try await client.copy(id: id, plainTextOnly: plain)
            try Task.checkCancellation()
            guard !isStopped else { throw ExtensionPeerError.unavailable }
            try copyRecord(copy)
            return try ClipboardMessage.encode(try await client.mutate(.init(.copied, ids: [id])))
        }
        if command == "clipboard.ui.palette" {
            guard allowsSystemActions else { throw ExtensionPeerError.unavailable }
            try validateEmpty(payload)
            panel.show()
            return Data("{}".utf8)
        }
        if command == "clipboard.ui.permission" {
            guard allowsSystemActions else { throw ExtensionPeerError.unavailable }
            try validateEmpty(payload)
            ClipboardPermission.request()
            return Data("{}".utf8)
        }
        if command == "cli.execute" {
            return try ClipboardMessage.encode(
                try await ClipboardCLIExecution.run(
                    ClipboardMessage.decode(ExtensionCLIRequest.self, from: payload),
                    client: client, defaults: defaults, copy: copyRecord
                ))
        }
        if command == "clipboard.captureStatus" {
            return try JSONSerialization.data(withJSONObject: [
                "enabled": defaults.bool(forKey: AppStorageKeys.Clipboard.enabled),
                "monitoring": store.isCapturing,
            ])
        }
        guard ClipboardServiceOperation.internalOperations.contains(command) else {
            throw ExtensionPeerError.invalidRequest
        }
        return try await service.perform(operation: command, payload: payload)
    }

    private func validateEmpty(_ payload: Data) throws {
        guard payload.isEmpty || payload == Data("{}".utf8) else {
            throw ExtensionPeerError.invalidRequest
        }
    }

    func cancelPendingCommands() {
        isStopped = true
        store.cancelPendingCommands()
        history.cancelPendingCommands()
    }

    func cancelAndWait() async {
        cancelPendingCommands()
        async let storeDrain: Void = store.cancelAndWait()
        async let historyDrain: Void = history.cancelAndWait()
        await service.cancelPendingCommands()
        await service.cancelAndWait()
        _ = await (storeDrain, historyDrain)
        await ClipboardPreviewCancellation.shared.shutdown()
    }

    func shutdown() async {
        await cancelAndWait()
        panel.shutdown()
        async let storeStop: Void = store.stop()
        async let historyStop: Void = history.shutdown()
        await service.stop()
        _ = await (storeStop, historyStop)
        await ClipboardPreviewCancellation.shared.shutdown()
        ClipboardThumbnail.clear()
    }
}

@MainActor
final class ClipboardTaskOwner {
    private struct Entry {
        let task: Task<Void, Never>
        let cancel: @Sendable () -> Void
    }

    private var entries: [UUID: Entry] = [:]
    private(set) var closed = false

    func launch(_ work: @escaping @MainActor () async -> Void) -> Task<Void, Never>? {
        guard !closed, entries.count < 64 else { return nil }
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
        guard !closed, entries.count < 64 else { throw CancellationError() }
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

    var activeCount: Int { entries.count }

    func wait() async {
        let active = Array(entries.values)
        for entry in active { await entry.task.value }
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
