import Foundation
import Testing

@testable import Edith
@testable import EdithKit

@MainActor
@Suite struct GitHubBrowserModelTests {
    @Test func routesAddressesAndPreservesTheFinalClosedTab() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = GitHubSessionStore(file: root.appendingPathComponent("session.json"))
        let model = GitHubBrowserModel(store: store)
        let originalID = try #require(model.session.selectedTabID)

        model.updateAddressDraft("acme/orbit/blob/main/README.md#L8")
        model.submitAddress()
        #expect(
            model.currentRoute?.url.absoluteString
                == "https://github.com/acme/orbit/blob/main/README.md#L8")

        model.close(originalID)
        #expect(model.session.tabs.count == 1)
        #expect(model.session.recentlyClosed.map(\.tab.id) == [originalID])
        model.reopenLastClosed()
        #expect(model.session.tabs.count == 2)
        #expect(model.session.selectedTabID == originalID)

        model.updateAddressDraft("not a valid URL")
        model.submitAddress()
        #expect(model.addressError != nil)
        try await Task.sleep(for: .milliseconds(300))
        let restored = try await store.restore()
        #expect(restored == model.session)
    }
}
