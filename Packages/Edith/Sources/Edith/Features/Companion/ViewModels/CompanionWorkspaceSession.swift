import Foundation

@MainActor
final class CompanionWorkspaceSession {
    let home = CompanionHomeModel()
    let chat = CompanionChatModel()
    let library = CompanionLibraryModel()
    let mind = CompanionMindModel()
    let desk = CompanionDeskModel()
    let backend = CompanionBackendModel()
    let settings = CompanionSettingsModel()

    deinit {
        let chat = chat
        Task { @MainActor in chat.stop() }
    }
}
