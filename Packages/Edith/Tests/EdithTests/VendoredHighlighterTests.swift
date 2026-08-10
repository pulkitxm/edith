import Foundation
import Testing

@testable import EdithKit

import Highlighter

@Suite struct VendoredHighlighterTests {
    @Test func loadsItsResourcesWithoutTheGeneratedAccessor() {
        #expect(Highlighter() != nil)
    }

    @Test func highlightsCodeWithATheme() throws {
        let highlighter = try #require(Highlighter())
        #expect(highlighter.setTheme("atom-one-dark"))
        let rendered = highlighter.highlight("let x = 1", as: "swift")
        #expect(rendered?.string.contains("let x = 1") == true)
    }

    @Test func shipsTheThemesTheFilePreviewAsksFor() {
        let bundle = BundledResources.bundle(named: "Edith_Highlighter")
        for theme in ["atom-one-dark", "atom-one-light", "default-light"] {
            #expect(bundle?.path(forResource: theme, ofType: "css") != nil)
        }
    }

    @Test func resolvesAFlatBundleLaidOutLikeAPackagedApp() throws {
        let resources = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        let bundle = resources.appendingPathComponent("Edith_Highlighter.bundle")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: resources) }
        try Data("body {}".utf8).write(to: bundle.appendingPathComponent("atom-one-dark.css"))

        let found = try #require(
            BundledResources.bundle(named: "Edith_Highlighter", directories: [resources]))
        #expect(found.path(forResource: "atom-one-dark", ofType: "css") != nil)
    }

    @Test func returnsNilForABundleThatIsNotThere() {
        let missing = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")
        #expect(BundledResources.bundle(named: "Edith_Highlighter", directories: [missing]) == nil)
    }
}
