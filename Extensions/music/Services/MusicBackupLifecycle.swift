import EdithExtensionSupport
import Foundation

@MainActor final class MusicBackupLifecycle {
    private let provider: MusicBackupProvider
    private var restore: Task<Void, Never>?
    private var stopping = false

    init(provider: MusicBackupProvider) {
        self.provider = provider
        restore = Task { [weak self] in
            guard let self else { return }
            let restored = await provider.restoreOnEnable()
            guard !stopping else { return }
            provider.startScheduling(restorePending: !restored)
        }
    }

    func execute(_ command: String, payload: Data) async throws -> Data {
        guard !stopping else { throw ExtensionPeerError.unavailable }
        if command == "backup.cancel" { restore?.cancel(); await restore?.value }
        if command == "backup.synchronize" {
            let ownedRestore = restore
            await withTaskCancellationHandler {
                await ownedRestore?.value
            } onCancel: {
                ownedRestore?.cancel()
            }
        }
        try Task.checkCancellation()
        guard !stopping else { throw ExtensionPeerError.unavailable }
        let result = try await provider.execute(command, payload: payload)
        return result
    }

    func preferencesChanged() { guard !stopping else { return }; provider.preferencesChanged() }
    func beginShutdown() { stopping = true; restore?.cancel() }

    func shutdown() async {
        beginShutdown()
        await provider.shutdown()
        await restore?.value
        restore = nil
    }
}
