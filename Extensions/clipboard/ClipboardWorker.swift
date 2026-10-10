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

    init(service: ClipboardService = .init(), capturesPasteboard: Bool = true) {
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
            return try ClipboardMessage.encode(ClipboardPreferences.read(SharedDefaults.store))
        }
        if command == "clipboard.ui.preferences.set" {
            guard payload.count <= 16_384 else { throw ExtensionPeerError.invalidRequest }
            try ClipboardMessage.decode(ClipboardPreferences.self, from: payload).save(
                SharedDefaults.store)
            return try ClipboardMessage.encode(ClipboardPreferences.read(SharedDefaults.store))
        }
        if command == "clipboard.ui.copy" {
            guard payload.count <= 128 else { throw ExtensionPeerError.invalidRequest }
            let id = try ClipboardMessage.decode(String.self, from: payload)
            guard UUID(uuidString: id) != nil else { throw ExtensionPeerError.invalidRequest }
            let plain = SharedDefaults.store.bool(forKey: AppStorageKeys.Clipboard.pastePlainText)
            let copy = try await client.copy(id: id, plainTextOnly: plain)
            try Task.checkCancellation()
            guard !isStopped else { throw ExtensionPeerError.unavailable }
            ClipboardRepository.copyToPasteboard(copy, pasteboard: .general)
            return try ClipboardMessage.encode(try await client.mutate(.init(.copied, ids: [id])))
        }
        if command == "clipboard.ui.palette" {
            try validateEmpty(payload)
            panel.show()
            return Data("{}".utf8)
        }
        if command == "clipboard.ui.permission" {
            try validateEmpty(payload)
            ClipboardPermission.request()
            return Data("{}".utf8)
        }
        if command == "cli.execute" {
            return try ClipboardMessage.encode(
                try await ClipboardCLIExecution.run(
                    ClipboardMessage.decode(ExtensionCLIRequest.self, from: payload), client: client
                ))
        }
        if command == "clipboard.captureStatus" {
            return try JSONSerialization.data(withJSONObject: [
                "enabled": SharedDefaults.store.bool(forKey: AppStorageKeys.Clipboard.enabled),
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

    func shutdown() async {
        guard !isStopped else { return }
        isStopped = true
        panel.shutdown()
        async let storeStop: Void = store.stop()
        async let historyStop: Void = history.shutdown()
        await service.stop()
        _ = await (storeStop, historyStop)
        await ClipboardPreviewCancellation.shared.shutdown()
        ClipboardThumbnail.clear()
    }
}
