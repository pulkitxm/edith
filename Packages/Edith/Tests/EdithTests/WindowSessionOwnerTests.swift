import Foundation
import Testing

@testable import Edith

@MainActor
@Suite struct WindowSessionOwnerTests {
    @Test func sessionsStayWithinTheirWindowOwner() {
        let first = WindowSessionOwner()
        let second = WindowSessionOwner()
        let quinjet = first.quinjet
        let capture = first.capture
        quinjet.addPickerTab()
        capture.note = "synthetic draft"

        #expect(first.quinjet === quinjet)
        #expect(first.capture === capture)
        #expect(second.quinjet !== quinjet)
        #expect(second.capture !== capture)
        #expect(second.quinjet.tabs.count == 1)
        #expect(second.capture.note.isEmpty)
        second.capture.setCaptureActive(false)
        #expect(first.capture.note == "synthetic draft")
    }

    @Test func analyticsRetainTheirReportsAndNavigationWithinOneWindow() {
        let first = WindowSessionOwner()
        let second = WindowSessionOwner()
        let attention = first.attention
        let codeStats = first.codeStats
        attention.section = .timeline
        #expect(first.attention === attention)
        #expect(first.codeStats === codeStats)
        #expect(first.attention.section == .timeline)
        #expect(second.attention !== attention)
        #expect(second.codeStats !== codeStats)
        #expect(second.attention.section == .overview)
    }

    @Test func extensionWorkspacesRetainDraftsFiltersAndSelections() {
        let first = WindowSessionOwner()
        let second = WindowSessionOwner()
        first.companion.chat.draft = "Plan a sample launch"
        first.database.connections.searchText = "sample database"
        first.database.connections.favoritesOnly = true
        first.maintenance.query = "sample editor"
        first.homebrew.query = "sample package"
        first.homebrew.mode = .search
        first.blitzTree.list = .files
        first.blitzTree.rings = true

        #expect(first.companion === first.companion)
        #expect(first.database === first.database)
        #expect(first.companion.chat.draft == "Plan a sample launch")
        #expect(first.database.connections.favoritesOnly)
        #expect(first.maintenance.query == "sample editor")
        #expect(first.homebrew.mode == .search)
        #expect(first.blitzTree.list == .files)
        #expect(second.companion.chat.draft.isEmpty)
        #expect(second.database.connections.searchText.isEmpty)
        #expect(!second.database.connections.favoritesOnly)
        #expect(second.maintenance.query.isEmpty)
        #expect(second.blitzTree.list == .children)
    }

    @Test func catalogsAndLiveAppFiltersSurviveNavigationWithinTheirWindow() {
        let first = WindowSessionOwner()
        let second = WindowSessionOwner()
        first.extensions.query = "sample tool"
        first.extensions.category = .media
        first.runningApps.query = "sample editor"
        first.studio.toolQuery = "compress"
        first.studio.toolFilter = .intelligence
        #expect(first.extensions === first.extensions)
        #expect(first.runningApps === first.runningApps)
        #expect(first.extensions.query == "sample tool")
        #expect(first.extensions.category == .media)
        #expect(first.runningApps.query == "sample editor")
        #expect(first.studio.toolFilter == .intelligence)
        #expect(second.extensions.query.isEmpty)
        #expect(second.extensions.category == .all)
        #expect(second.runningApps.query.isEmpty)
        #expect(second.studio.toolFilter == .all)
    }

    @Test func bridgeTargetsFocusedHostAndPreservesSurvivingAttachments() {
        let bridge = QuinjetSessionBridge()
        let first = WindowSessionOwner()
        let second = WindowSessionOwner()
        let firstRouter = WindowRouter()
        let secondRouter = WindowRouter()
        let firstToken = UUID()
        let secondToken = UUID()
        bridge.attach(first.quinjet, token: firstToken, router: firstRouter)
        bridge.attach(second.quinjet, token: secondToken, router: secondRouter)

        #expect(bridge.model(for: firstRouter) === first.quinjet)
        #expect(bridge.model(for: secondRouter) === second.quinjet)
        #expect(bridge.model(for: nil) === second.quinjet)
        bridge.detach(token: firstToken)
        #expect(bridge.model(for: nil) === second.quinjet)
        bridge.attach(first.quinjet, token: firstToken, router: firstRouter)
        bridge.detach(token: firstToken)
        #expect(bridge.model(for: secondRouter) === second.quinjet)
        bridge.detach(token: secondToken)
        #expect(bridge.model(for: nil) == nil)
    }
}
