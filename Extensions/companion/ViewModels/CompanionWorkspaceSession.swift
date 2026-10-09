import EdithExtensionSupport
import EdithExtensionUI
import Foundation

@MainActor
final class CompanionWorkspaceSession {
    let home = CompanionHomeModel()
    let chat = CompanionChatModel()
    let capture = CompanionCaptureModel()
    let library = CompanionLibraryModel()
    let mind = CompanionMindModel()
    let desk = CompanionDeskModel()
    let backend = CompanionBackendModel()
    let settings = CompanionSettingsModel()
    let privacy: SurfacePrivacyState?
    private(set) var isStopped = false

    init(privacy: SurfacePrivacyState? = nil) {
        self.privacy = privacy
    }

    func shutdown() {
        guard !isStopped else { return }
        isStopped = true
        chat.stop()
        capture.shutdown()
        CompanionGeneration.stopAll()
        privacy?.shutdown()
    }

    deinit {
        let chat = chat
        Task { @MainActor in chat.stop() }
    }
}
