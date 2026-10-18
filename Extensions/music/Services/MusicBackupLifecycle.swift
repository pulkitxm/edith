import EdithExtensionSupport
import Foundation

@MainActor final class MusicBackupLifecycle {
    private let provider: MusicBackupProvider
    private var restore: Task<Void, Never>?
    private var stopping = false
    private var commandsSuspended = false

    init(provider: MusicBackupProvider) {
        self.provider = provider
        restore = Task { [weak self] in
            guard let self else { return }
            let restored = await provider.restoreOnEnable()
            guard !stopping, !commandsSuspended else { return }
            provider.startScheduling(restorePending: !restored)
        }
    }

    func execute(_ command: String, payload: Data) async throws -> Data {
        guard !stopping, !commandsSuspended else { throw ExtensionPeerError.unavailable }
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
        guard !stopping, !commandsSuspended else { throw ExtensionPeerError.unavailable }
        let result = try await provider.execute(command, payload: payload)
        return result
    }

    func preferencesChanged() {
        guard !stopping, !commandsSuspended else { return }; provider.preferencesChanged()
    }
    func suspendCommands() {
        commandsSuspended = true
        restore?.cancel()
        provider.suspendCommands()
    }

    func suspendCommandsAndWait() async {
        suspendCommands()
        await restore?.value
        await provider.suspendCommandsAndWait()
    }

    func beginShutdown() { stopping = true; suspendCommands() }

    func shutdown() async {
        beginShutdown()
        await provider.shutdown()
        await restore?.value
        restore = nil
    }
}
