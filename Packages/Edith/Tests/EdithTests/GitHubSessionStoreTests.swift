import EdithCore
import Foundation
import Testing

@testable import EdithKit

@Suite struct GitHubSessionStoreTests {
    @Test func restoresSavedTabsAndFallsBackToHome() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("nested/browser-session.json")
        let store = GitHubSessionStore(file: file)

        let fallback = try await store.restore()
        let tabID = try #require(fallback.selectedTabID)
        var session = fallback
        let repository = try #require(
            GitHubRoute(url: URL(string: "https://github.com/acme/orbit")!))
        session.navigate(
            tabID: tabID, to: GitHubBrowserHistoryEntry(route: repository, scrollOffset: 48))
        session.updateAddressBarDraft(tabID: tabID, text: "acme/orbit/tree/main")

        try await store.save(session)
        let restored = try await store.restore()

        #expect(fallback.tabs.count == 1)
        #expect(fallback.currentRoute?.url.absoluteString == "https://github.com/")
        #expect(restored == session)
        #expect(restored.selectedTab?.currentEntry.scrollOffset == 48)
        #expect(restored.selectedTab?.addressBarDraft == "acme/orbit/tree/main")
    }
}

private extension GitHubBrowserSession {
    var currentRoute: GitHubRoute? { selectedTab?.currentEntry.route }
}
