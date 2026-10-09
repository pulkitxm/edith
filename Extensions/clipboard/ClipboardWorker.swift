import EdithExtensionSupport
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
