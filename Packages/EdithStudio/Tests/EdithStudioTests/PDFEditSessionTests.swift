import AppKit
import Foundation
import PDFKit
import Testing

@testable import EdithStudio

@Suite struct PDFEditSessionTests {
    func session(_ space: Workspace, pages: [String] = ["One", "Two", "Three"]) throws
        -> PDFEditSession
    {
        let source = space.url("doc-\(UUID().uuidString.prefix(6)).pdf")
        try Fixtures.pdf(at: source, pages: pages)
        return try PDFEditSession(url: source)
    }

    func texts(_ document: PDFDocument) -> [String] {
        (0..<document.pageCount).map {
            document.page(at: $0)?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
    }

    @Test func pageOperationsReorderRotateDeleteDuplicateAndInsert() throws {
        let space = try Workspace()
        let edit = try session(space)
        edit.movePage(from: 2, to: 0)
        #expect(texts(edit.document) == ["Three", "One", "Two"])
        edit.rotatePages([0, 1], by: 90)
        #expect(edit.document.page(at: 0)?.rotation == 90)
        edit.rotatePages([0], by: -90)
        #expect(edit.document.page(at: 0)?.rotation == 0)
        edit.duplicatePage(1)
        #expect(texts(edit.document) == ["Three", "One", "One", "Two"])
        try edit.deletePages([1, 2])
        #expect(texts(edit.document) == ["Three", "Two"])
        edit.insertBlankPage(at: 1)
        #expect(edit.pageCount == 3)
        #expect(texts(edit.document)[1].isEmpty)
        let other = space.url("other.pdf")
        try Fixtures.pdf(at: other, pages: ["Extra A", "Extra B"])
        #expect(try edit.insertPages(from: other, at: 3) == 2)
        #expect(texts(edit.document).suffix(2) == ["Extra A", "Extra B"])
        #expect(throws: StudioError.self) { try edit.deletePages(Set(0..<edit.pageCount)) }
        #expect(edit.isDirty)
    }

    @Test func annotationsSurviveExport() throws {
        let space = try Workspace()
        let edit = try session(space)
        let style = PDFEditSession.Style()
        edit.addText(
            "Approved", in: CGRect(x: 100, y: 600, width: 160, height: 30), page: 0, style: style)
        edit.addShape(
            .rectangle, from: CGPoint(x: 50, y: 50), to: CGPoint(x: 150, y: 120), page: 0,
            style: style)
        edit.addShape(
            .arrow, from: CGPoint(x: 200, y: 200), to: CGPoint(x: 300, y: 260), page: 1,
            style: style)
        edit.addInk(
            [[CGPoint(x: 10, y: 10), CGPoint(x: 60, y: 40), CGPoint(x: 90, y: 20)]], page: 1,
            style: style)
        edit.addNote("Check this", at: CGPoint(x: 300, y: 700), page: 2, color: .black)
        let selection = try #require(edit.document.findString("Two", withOptions: []).first)
        #expect(
            edit.addMarkup(
                .highlight, for: selection, color: StudioColor(red: 1, green: 0.9, blue: 0)) == 1)
        let output = space.url("annotated.pdf")
        try edit.export(to: output)
        let saved = try #require(PDFDocument(url: output))
        let types = (0..<saved.pageCount).flatMap {
            saved.page(at: $0)?.annotations.compactMap(\.type) ?? []
        }
        #expect(types.contains("FreeText"))
        #expect(types.contains("Square"))
        #expect(types.contains("Line"))
        #expect(types.contains("Ink"))
        #expect(types.contains("Text"))
        #expect(types.contains("Highlight"))
        #expect(
            saved.page(at: 0)?.annotations.first { $0.type == "FreeText" }?.contents == "Approved")
        #expect(!edit.isDirty)

        let flat = space.url("flat.pdf")
        try edit.export(to: flat, flatten: true)
        let flattened = try #require(PDFDocument(url: flat))
        #expect(flattened.page(at: 0)?.annotations.isEmpty == true)
        #expect(flattened.page(at: 0)?.string?.contains("Approved") == true)
    }

    @Test func placementsAreBurnedAndMarkersNeverLeak() throws {
        let space = try Workspace()
        let edit = try session(space, pages: ["Sign here"])
        let signature = try #require(
            StudioSignature.typed(
                "Jane Doe", font: "Snell Roundhand",
                color: StudioColor(red: 0.05, green: 0.1, blue: 0.6)))
        let id = edit.place(signature, in: CGRect(x: 300, y: 100, width: 200, height: 60), page: 0)
        #expect(id != nil)
        #expect(
            edit.document.page(at: 0)?.annotations.contains { $0 is PlacementAnnotation } == true)
        let output = space.url("signed.pdf")
        try edit.export(to: output)
        let saved = try #require(PDFDocument(url: output))
        #expect(saved.page(at: 0)?.annotations.isEmpty == true)
        let image = try StudioPDF.render(try #require(saved.page(at: 0)), dpi: 72)
        let pixel = Fixtures.pixel(image, x: 400, y: image.height - 130)
        let inked = (0..<60).contains { dx in
            let sample = Fixtures.pixel(image, x: 310 + dx * 3, y: image.height - 130)
            return sample.b > sample.r + 40
        }
        #expect(inked || pixel.b > pixel.r)
        #expect(
            edit.document.page(at: 0)?.annotations.contains { $0 is PlacementAnnotation } == true)
    }

    @Test func redactionMarksAreAppliedOnExport() throws {
        let space = try Workspace()
        let edit = try session(space, pages: ["Account 4111 1111 1111 1111 belongs to Sam Carter"])
        #expect(edit.markRedactions(terms: ["Sam Carter"], patterns: [.card]) >= 2)
        edit.markRedaction(CGRect(x: 10, y: 10, width: 40, height: 40), page: 0)
        let marked = edit.redactionCount
        #expect(marked >= 3)
        let output = space.url("redacted.pdf")
        try edit.export(to: output)
        let text = Fixtures.text(of: output)
        #expect(!text.contains("Sam Carter"))
        #expect(!text.contains("4111"))
        #expect(text.contains("Account"))
        #expect(PDFDocument(url: output)?.page(at: 0)?.annotations.isEmpty == true)
        edit.clearRedactions()
        #expect(edit.redactionCount == 0)
    }

    @Test func formFieldsCanBeCreatedDetectedAndFilled() throws {
        let space = try Workspace()
        let edit = try session(space, pages: ["Name: ________________\n\nAgree [ ]"])
        let detected = edit.detectFormFields()
        #expect(detected == 2)
        edit.addField(
            .choice(["Red", "Green"]), in: CGRect(x: 60, y: 500, width: 140, height: 22), page: 0,
            name: "Color")
        let output = space.url("form.pdf")
        try edit.export(to: output)
        let saved = try #require(PDFDocument(url: output))
        let widgets = saved.page(at: 0)?.annotations.filter { $0.type == "Widget" } ?? []
        #expect(widgets.count == 3)
        #expect(widgets.contains { $0.fieldName == "Color" && $0.choices == ["Red", "Green"] })
        let text = try #require(widgets.first { $0.widgetFieldType == .text })
        text.widgetStringValue = "Ada Lovelace"
        let filled = space.url("filled.pdf")
        #expect(saved.write(to: filled))
        let reopened = try #require(PDFDocument(url: filled))
        #expect(
            reopened.page(at: 0)?.annotations.contains { $0.widgetStringValue == "Ada Lovelace" }
                == true)
    }

    @Test func cropAndTrimAdjustPageBoxes() throws {
        let space = try Workspace()
        let edit = try session(space, pages: ["Tiny"])
        edit.crop(pages: [0], to: CGRect(x: 0, y: 0, width: 300, height: 400))
        #expect(edit.document.page(at: 0)?.bounds(for: .cropBox).width == 300)
        let second = try session(space, pages: ["Trim me"])
        #expect(try second.trimMargins(pages: [0]) == 1)
        #expect((second.document.page(at: 0)?.bounds(for: .cropBox).width ?? 612) < 200)
    }

    @Test func undoSnapshotsRestoreEverything() throws {
        let space = try Workspace()
        let edit = try session(space)
        let snapshot = try #require(edit.snapshot())
        edit.markRedaction(CGRect(x: 10, y: 10, width: 50, height: 20), page: 1)
        try edit.deletePages([0])
        #expect(edit.pageCount == 2)
        #expect(edit.redactions[0]?.count == 1)
        edit.restore(snapshot)
        #expect(edit.pageCount == 3)
        #expect(edit.redactionCount == 0)
    }

    @Test func pageMovesKeepRedactionsOnTheirPage() throws {
        let space = try Workspace()
        let edit = try session(space)
        edit.markRedaction(CGRect(x: 10, y: 10, width: 50, height: 20), page: 2)
        edit.movePage(from: 2, to: 0)
        #expect(edit.redactions[0]?.count == 1)
        #expect(edit.redactions[2] == nil)
        edit.insertBlankPage(at: 0)
        #expect(edit.redactions[1]?.count == 1)
    }

    @Test func signatureHelpersProduceTrimmedTransparentImages() throws {
        let drawn = try #require(
            StudioSignature.drawn(
                [[CGPoint(x: 10, y: 10), CGPoint(x: 100, y: 40)]],
                canvas: CGSize(width: 200, height: 80),
                color: .black))
        #expect(drawn.width < 600)
        let corner = Fixtures.pixel(drawn, x: 0, y: 0)
        #expect(corner.a < 10)
        let scan = try #require(StudioImageOps.context(width: 120, height: 60, opaque: true))
        scan.setFillColor(gray: 1, alpha: 1)
        scan.fill(CGRect(x: 0, y: 0, width: 120, height: 60))
        scan.setFillColor(gray: 0, alpha: 1)
        scan.fill(CGRect(x: 30, y: 20, width: 60, height: 8))
        let scanned = try #require(scan.makeImage())
        let cleaned = try #require(StudioSignature.cleaned(scanned))
        #expect(cleaned.width < 120)
        #expect(Fixtures.pixel(cleaned, x: 0, y: 0).a == 0)
        let typed = try #require(StudioSignature.typed("JD", font: "Zapfino", color: .black))
        #expect(typed.width > 20)
    }
}
