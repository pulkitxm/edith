import Foundation
import PDFKit
import Testing

@testable import EdithStudio

@Suite struct WebToolsTests {
    static func page(at url: URL, sections: Int) throws {
        let body = (1...sections).map {
            "<section style=\"height:600px;border-bottom:1px solid #ccc\"><h2>Section \($0)</h2><p>Body copy for section \($0).</p></section>"
        }.joined()
        try
            "<html><head><title>Long Page</title></head><body style=\"margin:0;font-family:Helvetica\"><div style=\"background:#d97757;height:120px\"></div>\(body)</body></html>"
            .write(to: url, atomically: true, encoding: .utf8)
    }

    @Test func localPageBecomesPaginatedPDF() async throws {
        let space = try Workspace()
        let html = space.url("long.html")
        try Self.page(at: html, sections: 6)
        let result = try await space.run("web.to-pdf", [], ["url": .text(html.path)])
        let document = try result.document()
        #expect(document.pageCount >= 3)
        let box = try #require(document.page(at: 0)?.bounds(for: .mediaBox))
        #expect(abs(box.width - 595.28) < 1)
        let text = Fixtures.text(of: try result.url())
        #expect(text.contains("Section 1"))
        #expect(text.contains("Section 6"))
        #expect(try result.url().lastPathComponent == "long.pdf")

        let single = try await space.run(
            "web.to-pdf", [], ["url": .text(html.path), "pages": .text("single")])
        #expect(try single.document().pageCount == 1)

        let dropped = try await space.run("web.html-to-pdf", [html])
        #expect(Fixtures.text(of: try dropped.url()).contains("Section 3"))
    }

    @Test func localPageBecomesFullHeightScreenshot() async throws {
        let space = try Workspace()
        let html = space.url("shot.html")
        try Self.page(at: html, sections: 3)
        let result = try await space.run(
            "web.to-image", [], ["url": .text(html.path), "width": .text("768")])
        let info = try #require(StudioImageIO.info(try result.url()))
        #expect(info.width >= 768)
        #expect(Double(info.height) / Double(info.width) > 2)
        let image = try StudioImageIO.load(try result.url())
        let top = Fixtures.pixel(image, x: 10, y: 10)
        #expect(top.r > 180 && top.g < 150)
    }

    @Test func addressesAreValidated() throws {
        #expect(try WebCapture.target(from: "example.com").absoluteString == "https://example.com")
        #expect(try WebCapture.target(from: "http://example.com/a").scheme == "http")
        #expect(throws: StudioError.self) { try WebCapture.target(from: "") }
        #expect(throws: StudioError.self) { try WebCapture.target(from: "ftp://example.com") }
        #expect(throws: StudioError.self) { try WebCapture.target(from: "/nonexistent/file.html") }
        #expect(throws: StudioError.self) { try WebCapture.target(from: "not a url") }
    }

    @Test func missingAddressIsRejectedBeforeLoading() async throws {
        let space = try Workspace()
        await #expect(throws: StudioError.self) { try await space.run("web.to-pdf", []) }
    }
}
