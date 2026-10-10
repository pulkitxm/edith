import EdithExtensionSupport
import Foundation

@MainActor final class MusicBackupLifecycle {
    private let provider: MusicBackupProvider
    private let restore: Task<Void, Never>
    private var stopping = false

    init(provider: MusicBackupProvider) {
        self.provider = provider
        restore = Task { _ = await provider.restoreOnEnable() }
    }

    func execute(_ command: String, payload: Data) async throws -> Data {
        guard !stopping else { throw ExtensionPeerError.unavailable }
        if command == "backup.cancel" { restore.cancel() }
        if command == "backup.synchronize" {
            await withTaskCancellationHandler {
                await restore.value
            } onCancel: {
                restore.cancel()
            }
        }
        try Task.checkCancellation()
        guard !stopping else { throw ExtensionPeerError.unavailable }
        let result = try await provider.execute(command, payload: payload)
        if command == "backup.cancel" { await restore.value }
        return result
    }

    func beginShutdown() { stopping = true; restore.cancel() }

    func shutdown() async {
        beginShutdown()
        await provider.shutdown()
        await restore.value
    }
}
