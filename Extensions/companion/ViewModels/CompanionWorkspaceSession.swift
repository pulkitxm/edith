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
