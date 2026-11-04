import Foundation
import Testing

@testable import BlitzTreeExtension

@Suite struct PageTitleTests {
    @Test func pageTitleMatchesTheCatalogTitle() throws {
        let manifest = URL(filePath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "package.json")
        let package = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest))
        let title = try #require((package as? [String: Any])?["title"] as? String)
        #expect(BlitzTreePage.title == title)
    }

    @Test func settingsNameTheExtensionByItsCatalogTitle() throws {
        #expect(BlitzTreeSettings.summaryName == "Disk Map")
    }
}
