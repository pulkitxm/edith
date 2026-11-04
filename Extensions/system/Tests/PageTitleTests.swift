import Foundation
import Testing

@testable import SystemExtension

@Suite struct PageTitleTests {
    @Test func pageTitleMatchesTheCatalogTitle() throws {
        let manifest = URL(filePath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "package.json")
        let package = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest))
        let title = try #require((package as? [String: Any])?["title"] as? String)
        #expect(SystemPage.title == title)
    }
}
