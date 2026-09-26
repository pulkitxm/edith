import CoreGraphics
import Foundation
import PDFKit
import Testing

@testable import EdithStudio

@Suite struct PDFRedactionEditingTests {
    func session(_ space: Workspace, _ text: String) throws -> PDFEditSession {
        let source = space.url("doc-\(UUID().uuidString.prefix(6)).pdf")
        try Fixtures.pdf(at: source, pages: [text], fontSize: 22)
        return try PDFEditSession(url: source)
    }

    func bounds(of term: String, in edit: PDFEditSession, page index: Int = 0) throws -> CGRect {
        let page = try #require(edit.document.page(at: index))
        let found = try #require(edit.document.findString(term, withOptions: []).first)
        return found.bounds(for: page)
    }

    func near(_ a: CGRect?, _ b: CGRect, tolerance: CGFloat = 0.5) -> Bool {
        guard let a else { return false }
        return abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
            && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }

    @Test func movedMarkIsExportedWhereItIsShown() async throws {
        let space = try Workspace()
        let edit = try session(space, "Keep this line\n\nHidden passphrase")
        let secret = try bounds(of: "Hidden passphrase", in: edit).insetBy(dx: -2, dy: -2)
        let mark = try #require(
            edit.markRedaction(CGRect(x: 380, y: 80, width: 60, height: 20), page: 0))
        edit.move(mark, to: secret)
        #expect(edit.redactionCount == 1)
        #expect(near(edit.redactions[0]?.first, secret))
        let output = space.url("moved.pdf")
        try await edit.export(to: output)
        let text = Fixtures.text(of: output)
        #expect(!text.contains("passphrase"))
        #expect(text.contains("Keep"))
    }

    @Test func resizedMarkCoversTheWholeNewArea() async throws {
        let space = try Workspace()
        let edit = try session(space, "Card 4111 2222 3333 4444 expires soon")
        let number = try bounds(of: "4111 2222 3333 4444", in: edit)
        let mark = try #require(
            edit.markRedaction(
                CGRect(x: number.minX, y: number.minY, width: 20, height: number.height), page: 0))
        edit.move(mark, to: number.insetBy(dx: -2, dy: -2))
        let output = space.url("resized.pdf")
        try await edit.export(to: output)
        let text = Fixtures.text(of: output)
        #expect(!text.contains("4111"))
        #expect(!text.contains("4444"))
        #expect(text.contains("expires"))
    }

    @Test func deletedMarkRedactsNothing() async throws {
        let space = try Workspace()
        let edit = try session(space, "Nothing to hide here")
        let mark = try #require(
            edit.markRedaction(try bounds(of: "Nothing", in: edit), page: 0))
        edit.remove(mark)
        #expect(edit.redactionCount == 0)
        let output = space.url("clean.pdf")
        try await edit.export(to: output)
        #expect(Fixtures.text(of: output).contains("Nothing to hide"))
        #expect(PDFDocument(url: output)?.page(at: 0)?.annotations.isEmpty == true)
    }

    @Test func tinyDragsDoNotCreateMarks() throws {
        let space = try Workspace()
        let edit = try session(space, "Text")
        #expect(edit.markRedaction(CGRect(x: 10, y: 10, width: 0.5, height: 20), page: 0) == nil)
        #expect(edit.markRedaction(CGRect(x: 10, y: 10, width: 20, height: 20), page: 7) == nil)
        #expect(edit.redactionCount == 0)
    }

    @Test func reversedRectsAreNormalized() async throws {
        let space = try Workspace()
        let edit = try session(space, "Secret words")
        let secret = try bounds(of: "Secret words", in: edit).insetBy(dx: -2, dy: -2)
        let reversed = CGRect(
            x: secret.maxX, y: secret.maxY, width: -secret.width, height: -secret.height)
        #expect(edit.markRedaction(reversed, page: 0) != nil)
        #expect(near(edit.redactions[0]?.first, secret))
        let output = space.url("reversed.pdf")
        try await edit.export(to: output)
        #expect(!Fixtures.text(of: output).contains("Secret"))
    }

    @Test func undoAndRedoKeepMarksInSync() async throws {
        let space = try Workspace()
        let edit = try session(space, "Alpha Beta Gamma")
        let before = try #require(edit.snapshot())
        let mark = try #require(
            edit.markRedaction(try bounds(of: "Beta", in: edit).insetBy(dx: -1, dy: -1), page: 0))
        let marked = try #require(edit.snapshot())
        edit.move(mark, to: try bounds(of: "Gamma", in: edit).insetBy(dx: -1, dy: -1))
        edit.restore(marked)
        #expect(edit.redactionCount == 1)
        let output = space.url("restored.pdf")
        try await edit.export(to: output)
        let text = Fixtures.text(of: output)
        #expect(!text.contains("Beta"))
        #expect(text.contains("Gamma"))
        edit.restore(before)
        #expect(edit.redactionCount == 0)
    }

    @Test func duplicatedPagesCarryTheirMarks() async throws {
        let space = try Workspace()
        let edit = try session(space, "Private detail")
        edit.markRedaction(try bounds(of: "Private", in: edit).insetBy(dx: -1, dy: -1), page: 0)
        edit.duplicatePage(0)
        #expect(edit.redactions[0]?.count == 1)
        #expect(edit.redactions[1]?.count == 1)
        let output = space.url("duplicated.pdf")
        try await edit.export(to: output)
        let saved = try #require(PDFDocument(url: output))
        #expect(saved.pageCount == 2)
        for index in 0..<2 {
            #expect(saved.page(at: index)?.string?.contains("Private") != true)
        }
    }

    @Test(arguments: PageGeometry.all)
    func editorMarksLandOnTheTextOnEveryPageGeometry(_ geometry: PageGeometry) async throws {
        let space = try Workspace()
        let url = space.url("page.pdf")
        try geometry.write(to: url)
        let headlineURL = space.url("headline.pdf")
        try geometry.write(to: headlineURL, publicLine: false)
        let headlinePage = try #require(PDFDocument(url: headlineURL)?.page(at: 0))
        let headline = try StudioPDF.render(headlinePage, dpi: 72)
        let secret = try #require(PageInk.box(headline, below: 128))
        let edit = try PDFEditSession(url: url)
        let page = try #require(edit.document.page(at: 0))
        let found = try #require(edit.document.findString("SECRET NAME", withOptions: []).first)
        #expect(edit.markRedaction(found.bounds(for: page).insetBy(dx: -2, dy: -2), page: 0) != nil)
        let output = space.url("redacted.pdf")
        try await edit.export(to: output)
        let saved = try #require(PDFDocument(url: output)?.page(at: 0))
        #expect(StudioPDF.rotation(saved) == geometry.rotation)
        let after = try StudioPDF.render(saved, dpi: 72)
        #expect(PageInk.darkShare(after, in: secret) > 0.98)
        #expect(saved.string?.contains("SECRET") != true)
    }
}
