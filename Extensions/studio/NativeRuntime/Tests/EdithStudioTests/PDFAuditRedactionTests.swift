import AppKit
import Foundation
import PDFKit
import Testing

@testable import EdithStudio

@Suite struct PDFAuditRedactionTests {
    func letter(_ geometry: AuditGeometry) -> AuditPage {
        geometry.page { page in
            let top = page.layoutSize.height
            page.texts = [
                AuditText(text: "Project Falcon launches soon", x: 60, y: top - 120, size: 24),
                AuditText(text: "Write to jane.doe@example.com today", x: 60, y: top - 200),
                AuditText(text: "Docs at https://example.com/docs/start", x: 60, y: top - 240),
                AuditText(text: "Confidential appendix", x: 60, y: top - 300, size: 24),
            ]
        }
    }

    func words(_ document: PDFDocument, _ index: Int = 0) -> String {
        document.page(at: index)?.string ?? ""
    }

    @Test(arguments: AuditGeometry.all)
    func redactRemovesTheTermAndKeepsOtherTextExact(_ geometry: AuditGeometry) async throws {
        let space = try Workspace()
        let source = space.url("letter.pdf")
        try AuditPDF.write([letter(geometry)], to: source)
        let original = try #require(PDFDocument(url: source))
        let before = try AuditInk.render(try #require(original.page(at: 0)))
        let falcon = try #require(original.findString("Falcon", withOptions: []).first)
        let falconDisplay = falcon.bounds(for: try #require(original.page(at: 0)))
            .applying(StudioPDF.displayFromPage(try #require(original.page(at: 0))))
        let result = try await space.audited(
            "pdf.redact", [source],
            ["terms": .text("falcon"), "emails": .bool(false), "phones": .bool(false)])
        let document = try result.document()
        let page = try #require(document.page(at: 0))
        #expect(StudioPDF.rotation(page) == geometry.rotation)
        let text = words(document)
        #expect(text.localizedCaseInsensitiveContains("falcon") == false)
        #expect(text.contains("jane.doe@example.com"))
        #expect(text.contains("https://example.com/docs/start"))
        #expect(text.contains("Project"))
        #expect(text.contains("launches soon"))
        let after = try AuditInk.render(page)
        let size = StudioPDF.displaySize(page)
        let covered = AuditInk.pixelRect(falconDisplay, size: size, image: after)
        #expect(AuditInk.darkShare(after, in: covered.insetBy(dx: 1, dy: 1)) > 0.97)
        let email = try #require(document.findString("jane.doe@example.com", withOptions: []).first)
        let emailDisplay = email.bounds(for: page).applying(StudioPDF.displayFromPage(page))
        #expect(emailDisplay.width > emailDisplay.height)
        let emailPixels = AuditInk.pixelRect(emailDisplay, size: size, image: after)
        let ink = try #require(AuditInk.box(after, in: emailPixels.insetBy(dx: -3, dy: -3)))
        let overlap = ink.intersection(emailPixels)
        #expect(overlap.width * overlap.height > ink.width * ink.height * 0.6)
        #expect(AuditInk.darkShare(before, in: emailPixels) > 0.05)
    }

    @Test func aMarkOverHalfAWordRemovesEveryLetterItTouches() async throws {
        let space = try Workspace()
        let source = space.url("half.pdf")
        try AuditPDF.write([letter(AuditGeometry.all[0])], to: source)
        let edit = try PDFEditSession(url: source)
        let page = try #require(edit.page(0))
        let word = try #require(edit.document.findString("Confidential", withOptions: []).first)
        let bounds = word.bounds(for: page)
        let range = try #require(page.string.map { ($0 as NSString).range(of: "Confidential") })
        let d = try #require(page.selection(for: NSRange(location: range.location + 5, length: 1)))
        let mark = CGRect(
            x: bounds.minX - 2, y: bounds.minY - 2,
            width: d.bounds(for: page).midX - bounds.minX + 2,
            height: bounds.height + 4)
        #expect(edit.markRedaction(mark, page: 0) != nil)
        let output = space.url("half-redacted.pdf")
        try await edit.export(to: output)
        let text = try #require(PDFDocument(url: output)?.page(at: 0)?.string)
        #expect(text.contains("ential"))
        #expect(text.contains("Con") == false)
        #expect(text.contains("dent") == false)
        #expect(text.contains("appendix"))
        #expect(text.contains("jane.doe@example.com"))
    }

    @Test func linksOutsideMarksKeepWorkingOnEveryPage() async throws {
        let space = try Workspace()
        let source = space.url("links.pdf")
        var first = letter(AuditGeometry.all[1])
        first.link("Falcon", url: "https://falcon.example.com")
        first.link("jane.doe@example.com", url: "mailto:jane.doe@example.com")
        first.link("Docs at", page: 2)
        var second = AuditPage.titled("Second page", rotation: 90)
        second.link("Second page", page: 0)
        try AuditPDF.write(
            [first, second, .titled("Third page")], to: source,
            outline: [("Falcon plan", 0), ("Third", 2)])
        let result = try await space.audited(
            "pdf.redact", [source],
            ["terms": .text("Falcon"), "emails": .bool(false), "phones": .bool(false)])
        let document = try result.document()
        #expect(AuditPDF.linkURLs(document, page: 0) == ["mailto:jane.doe@example.com"])
        #expect(AuditPDF.linkTargets(document, page: 0) == [2])
        #expect(AuditPDF.linkTargets(document, page: 1) == [0])
        let outline = AuditPDF.outlineTargets(document)
        #expect(outline.map(\.1) == [0, 2])
        #expect(outline.contains { $0.0.localizedCaseInsensitiveContains("falcon") } == false)
        let page = try #require(document.page(at: 0))
        let email = try #require(document.findString("jane.doe@example.com", withOptions: []).first)
        let link = try #require(page.annotations.first { $0.type == "Link" && $0.url != nil })
        #expect(link.bounds.intersects(email.bounds(for: page)))
    }

    @Test(arguments: [0, 90, 270])
    func imageOnlyPagesStillGetRecognizedText(_ rotation: Int) async throws {
        let space = try Workspace()
        let source = space.url("scan.pdf")
        var page = AuditPage(rotation: rotation)
        let top = page.layoutSize.height
        page.images = [
            AuditImage(
                kind: .scan("INVOICE 4821\n\nTOTAL DUE FRIDAY"),
                rect: CGRect(x: 40, y: top - 340, width: 500, height: 300))
        ]
        try AuditPDF.write([page], to: source)
        let edit = try PDFEditSession(url: source)
        let live = try #require(edit.page(0))
        let display = CGRect(x: 30, y: top - 205, width: 520, height: 75)
        let mark = display.applying(StudioPDF.displayFromPage(live).inverted()).standardized
        #expect(edit.markRedaction(mark, page: 0) != nil)
        let output = space.url("scan-redacted.pdf")
        try await edit.export(to: output)
        let text = try #require(PDFDocument(url: output)?.page(at: 0)?.string)
        #expect(text.contains("INVOICE"))
        #expect(text.contains("FRIDAY") == false)
        #expect(text.contains("TOTAL") == false)
    }

    @Test func unsearchableRedactionKeepsNoTextAtAll() async throws {
        let space = try Workspace()
        let source = space.url("flat.pdf")
        try AuditPDF.write([letter(AuditGeometry.all[4]), .titled("Untouched page")], to: source)
        let result = try await space.audited(
            "pdf.redact", [source],
            ["terms": .text("Falcon"), "searchable": .bool(false), "emails": .bool(false)])
        let document = try result.document()
        #expect(words(document, 0).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(words(document, 1).contains("Untouched page"))
    }

    @Test func patternsFindEmailsPhonesAndCardsAcrossPages() async throws {
        let space = try Workspace()
        let source = space.url("pii.pdf")
        var first = AuditPage.titled("Customer record")
        first.texts += [
            AuditText(text: "Email: sam.carter@example.org", x: 60, y: 600),
            AuditText(text: "Phone: +1 415 555 0132", x: 60, y: 570),
            AuditText(text: "Card: 4111 1111 1111 1111", x: 60, y: 540),
            AuditText(text: "Order total 42 dollars", x: 60, y: 510),
        ]
        try AuditPDF.write([first, .titled("Nothing here", rotation: 90)], to: source)
        let result = try await space.audited(
            "pdf.redact", [source], ["cards": .bool(true), "scrubMetadata": .bool(true)])
        let text = words(try result.document())
        #expect(text.contains("sam.carter") == false)
        #expect(text.contains("555") == false)
        #expect(text.contains("4111") == false)
        #expect(text.contains("Order total 42 dollars"))
        #expect(text.contains("Customer record"))
        #expect(result.notes.first?.contains("on 1 page") == true)
    }
}
