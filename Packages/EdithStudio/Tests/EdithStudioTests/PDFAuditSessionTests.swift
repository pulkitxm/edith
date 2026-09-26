import AppKit
import Foundation
import PDFKit
import Testing

@testable import EdithStudio

@Suite struct PDFAuditSessionTests {
    static func twoTone(width: Int = 200, height: Int = 100) -> CGImage {
        let context = StudioImageOps.context(width: width, height: height)!
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(srgbRed: 0.95, green: 0.05, blue: 0.05, alpha: 1))
        context.fill(CGRect(x: 0, y: height / 2, width: width, height: height / 2))
        context.setFillColor(CGColor(srgbRed: 0.05, green: 0.1, blue: 0.95, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height / 2))
        return context.makeImage()!
    }

    static func hueBox(_ image: CGImage, red: Bool) -> CGRect? {
        let (data, width, height) = PageInk.pixels(image)
        var minX = Int.max
        var minY = Int.max
        var maxX = -1
        var maxY = -1
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let r = Int(data[offset])
                let g = Int(data[offset + 1])
                let b = Int(data[offset + 2])
                let hit = red ? (r > 150 && g < 110 && b < 110) : (b > 150 && r < 110 && g < 130)
                guard hit else { continue }
                minX = min(minX, x)
                maxX = max(maxX, x)
                minY = min(minY, y)
                maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    static func difference(_ a: CGImage, _ b: CGImage) -> Double {
        guard a.width == b.width, a.height == b.height else { return 1 }
        let left = PageInk.pixels(a).data
        let right = PageInk.pixels(b).data
        var changed = 0
        for index in 0..<(a.width * a.height) {
            let offset = index * 4
            let delta =
                abs(Int(left[offset]) - Int(right[offset]))
                + abs(Int(left[offset + 1]) - Int(right[offset + 1]))
                + abs(Int(left[offset + 2]) - Int(right[offset + 2]))
            if delta > 90 { changed += 1 }
        }
        return Double(changed) / Double(a.width * a.height)
    }

    func session(_ space: Workspace, _ geometry: AuditGeometry) throws -> PDFEditSession {
        let source = space.url("page.pdf")
        let page = geometry.page { page in
            page.texts = [
                AuditText(
                    text: "Signed agreement", x: 60, y: page.layoutSize.height - 100, size: 24)
            ]
            page.links = [AuditLink(rect: CGRect(x: 0, y: 0, width: 50, height: 50), page: 1)]
        }
        try AuditPDF.write([page, .titled("Second page")], to: source)
        return try PDFEditSession(url: source)
    }

    func pageRect(_ display: CGRect, on page: PDFPage) -> CGRect {
        display.applying(StudioPDF.displayFromPage(page).inverted()).standardized
    }

    @Test(arguments: AuditGeometry.all)
    func placedSignatureIsUprightAndInPlaceInEditorAndExport(_ geometry: AuditGeometry)
        async throws
    {
        let space = try Workspace()
        let edit = try session(space, geometry)
        let page = try #require(edit.page(0))
        let target = CGRect(x: 300, y: 100, width: 200, height: 100)
        #expect(edit.place(Self.twoTone(), in: pageRect(target, on: page), page: 0) != nil)
        let live = try AuditInk.render(page)
        let output = space.url("signed.pdf")
        try await edit.export(to: output)
        let saved = try #require(PDFDocument(url: output)?.page(at: 0))
        #expect(StudioPDF.rotation(saved) == geometry.rotation)
        let exported = try AuditInk.render(saved)
        let size = StudioPDF.displaySize(saved)
        let red = AuditInk.pixelRect(
            CGRect(x: 300, y: 150, width: 200, height: 50), size: size, image: exported)
        let blue = AuditInk.pixelRect(
            CGRect(x: 300, y: 100, width: 200, height: 50), size: size, image: exported)
        for (name, image) in [("editor", live), ("export", exported)] {
            #expect(
                AuditInk.near(Self.hueBox(image, red: true), red, tolerance: 3), "\(name) red half")
            #expect(
                AuditInk.near(Self.hueBox(image, red: false), blue, tolerance: 3),
                "\(name) blue half")
        }
        #expect(AuditPDF.linkTargets(try #require(PDFDocument(url: output)), page: 0) == [1])
    }

    @Test(arguments: AuditGeometry.all)
    func annotationsLookTheSameInEditorAndExport(_ geometry: AuditGeometry) async throws {
        let space = try Workspace()
        let edit = try session(space, geometry)
        let page = try #require(edit.page(0))
        let style = PDFEditSession.Style(
            color: StudioColor(red: 0.1, green: 0.6, blue: 0.1), lineWidth: 3,
            fontName: "Helvetica", fontSize: 20)
        let note = try #require(
            edit.addText(
                "Approved by legal",
                in: pageRect(CGRect(x: 60, y: 400, width: 260, height: 40), on: page),
                page: 0, style: style))
        let from = CGPoint(x: 350, y: 300).applying(StudioPDF.displayFromPage(page).inverted())
        let to = CGPoint(x: 500, y: 380).applying(StudioPDF.displayFromPage(page).inverted())
        edit.addShape(.rectangle, from: from, to: to, page: 0, style: style)
        edit.addInk(
            [
                [CGPoint(x: 80, y: 200), CGPoint(x: 160, y: 260), CGPoint(x: 240, y: 200)].map {
                    $0.applying(StudioPDF.displayFromPage(page).inverted())
                }
            ], page: 0, style: style)
        let selection = try #require(edit.document.findString("agreement", withOptions: []).first)
        #expect(
            edit.addMarkup(
                .highlight, for: selection, color: StudioColor(red: 1, green: 0.85, blue: 0))
                == 1)
        edit.addField(
            .text(multiline: false),
            in: pageRect(CGRect(x: 60, y: 520, width: 220, height: 24), on: page),
            page: 0, name: "Reviewer")
        let live = try AuditInk.render(page)
        let output = space.url("annotated.pdf")
        try await edit.export(to: output)
        let saved = try #require(PDFDocument(url: output)?.page(at: 0))
        let exported = try AuditInk.render(saved)
        #expect(Self.difference(live, exported) < 0.004)
        let size = StudioPDF.displaySize(saved)
        let referenceURL = space.url("reference.pdf")
        try AuditPDF.write([AuditPage(media: CGRect(origin: .zero, size: size))], to: referenceURL)
        let reference = try PDFEditSession(url: referenceURL)
        let referencePage = try #require(reference.page(0))
        reference.addText(
            "Approved by legal", in: CGRect(x: 60, y: 400, width: 260, height: 40),
            page: 0, style: style)
        let upright = try AuditInk.render(referencePage)
        let textArea = AuditInk.pixelRect(
            CGRect(x: 50, y: 390, width: 280, height: 60), size: size, image: exported
        ).integral
        for (name, image) in [("editor", live), ("export", exported)] {
            let region = try #require(image.cropping(to: textArea))
            let expected = try #require(upright.cropping(to: textArea))
            #expect(Self.difference(region, expected) < 0.01, "\(name) text is not upright")
        }
        let types = Set(saved.annotations.compactMap(\.type))
        #expect(types.isSuperset(of: ["FreeText", "Square", "Ink", "Highlight", "Widget"]))
        #expect(saved.annotations.first { $0.type == "FreeText" }?.contents == note.contents)
    }

    @Test(arguments: AuditGeometry.all)
    func cropAreaKeepsExactlyTheDrawnRegion(_ geometry: AuditGeometry) async throws {
        let space = try Workspace()
        let edit = try session(space, geometry)
        let page = try #require(edit.page(0))
        let before = try AuditInk.render(page)
        let title = try #require(
            AuditInk.box(before, in: CGRect(x: 40, y: 60, width: 400, height: 80)))
        let displayHeight = StudioPDF.displaySize(page).height
        let region = CGRect(x: 40, y: displayHeight - 500, width: 300, height: 450)
        edit.crop(pages: [0], to: pageRect(region, on: page))
        let output = space.url("cropped.pdf")
        try await edit.export(to: output)
        let saved = try #require(PDFDocument(url: output)?.page(at: 0))
        let size = StudioPDF.displaySize(saved)
        #expect(abs(size.width - 300) < 0.5 && abs(size.height - 450) < 0.5)
        let after = try AuditInk.render(saved)
        let moved = try #require(
            AuditInk.box(after, in: CGRect(x: 0, y: 0, width: 300, height: 100)))
        #expect(abs(moved.minX - (title.minX - 40)) <= 1.5)
        #expect(abs(moved.minY - (title.minY - 50)) <= 1.5)
    }

    @Test func pageOperationsCarryPlacementsAndMarksToTheRightPages() async throws {
        let space = try Workspace()
        let source = space.url("pages.pdf")
        var pages = (1...4).map { AuditPage.titled("Sheet \($0)") }
        pages[0].link("Sheet 1", page: 3)
        try AuditPDF.write(pages, to: source, outline: [("Four", 3)])
        let edit = try PDFEditSession(url: source)
        edit.place(Self.twoTone(), in: CGRect(x: 300, y: 100, width: 200, height: 100), page: 2)
        let secret = try #require(edit.document.findString("Sheet 4", withOptions: []).first)
        edit.markRedaction(
            secret.bounds(for: try #require(edit.page(3))).insetBy(dx: -2, dy: -2), page: 3)
        edit.movePage(from: 2, to: 0)
        try edit.deletePages([2])
        edit.rotatePages([0], by: 90)
        let output = space.url("pages-out.pdf")
        try await edit.export(to: output)
        let document = try #require(PDFDocument(url: output))
        #expect(document.pageCount == 3)
        #expect(
            AuditPDF.texts(document).map { $0.isEmpty ? "-" : $0 } == ["Sheet 3", "Sheet 1", "-"])
        let first = try AuditInk.render(try #require(document.page(at: 0)))
        #expect(Self.hueBox(first, red: true) != nil)
        let second = try AuditInk.render(try #require(document.page(at: 1)))
        #expect(Self.hueBox(second, red: true) == nil)
        #expect(document.page(at: 0)?.rotation == 90)
        #expect(AuditPDF.linkTargets(document, page: 1) == [2])
        #expect(AuditPDF.outlineTargets(document).map(\.1) == [2])
    }

    @Test func formFieldsStayFillableAfterExport() async throws {
        let space = try Workspace()
        let edit = try session(space, AuditGeometry.all[4])
        let page = try #require(edit.page(0))
        let field = try #require(
            edit.addField(
                .text(multiline: false),
                in: pageRect(CGRect(x: 60, y: 500, width: 220, height: 24), on: page),
                page: 0, name: "Name"))
        field.widgetStringValue = "Ada Lovelace"
        edit.addField(
            .checkbox, in: pageRect(CGRect(x: 60, y: 460, width: 16, height: 16), on: page),
            page: 0,
            name: "Agree")
        edit.place(
            Self.twoTone(), in: pageRect(CGRect(x: 300, y: 100, width: 200, height: 100), on: page),
            page: 0)
        let output = space.url("form.pdf")
        try await edit.export(to: output)
        let saved = try #require(PDFDocument(url: output)?.page(at: 0))
        let widgets = saved.annotations.filter { $0.type == "Widget" }
        #expect(Set(widgets.compactMap(\.fieldName)) == ["Name", "Agree"])
        #expect(widgets.first { $0.fieldName == "Name" }?.widgetStringValue == "Ada Lovelace")
    }

    @Test func duplicatedPagesShowAndExportTheirSignature() async throws {
        let space = try Workspace()
        let edit = try session(space, AuditGeometry.all[0])
        edit.place(Self.twoTone(), in: CGRect(x: 300, y: 100, width: 200, height: 100), page: 0)
        edit.duplicatePage(0)
        #expect(edit.pageCount == 3)
        let output = space.url("duplicated.pdf")
        try await edit.export(to: output)
        let document = try #require(PDFDocument(url: output))
        for index in 0..<2 {
            let live = try AuditInk.render(try #require(edit.page(index)))
            let saved = try AuditInk.render(try #require(document.page(at: index)))
            let red = Self.hueBox(saved, red: true)
            #expect(red != nil, "page \(index + 1) lost the signature")
            #expect(AuditInk.near(Self.hueBox(live, red: true), red, tolerance: 2))
            #expect(document.page(at: index)?.annotations.contains { $0.type == "Stamp" } == false)
        }
    }

    @Test(arguments: AuditGeometry.all)
    func signedAndRedactedPagesExportAndExtractCorrectly(_ geometry: AuditGeometry) async throws {
        let space = try Workspace()
        let edit = try session(space, geometry)
        let page = try #require(edit.page(0))
        edit.place(
            Self.twoTone(), in: pageRect(CGRect(x: 300, y: 100, width: 200, height: 100), on: page),
            page: 0)
        let found = try #require(edit.document.findString("agreement", withOptions: []).first)
        let secret = found.bounds(for: page)
        edit.markRedaction(secret.insetBy(dx: -2, dy: -2), page: 0)
        let covered = secret.applying(StudioPDF.displayFromPage(page))
        let extracted = space.url("extracted.pdf")
        try edit.extractPages([0], to: extracted)
        let exported = space.url("exported.pdf")
        try await edit.export(to: exported)
        for url in [extracted, exported] {
            let document = try #require(PDFDocument(url: url))
            let saved = try #require(document.page(at: 0))
            #expect(saved.annotations.contains { $0.type != "Link" } == false)
            #expect(saved.string?.contains("agreement") != true)
            #expect(saved.string?.contains("Signed") == true)
            let image = try AuditInk.render(saved)
            let size = StudioPDF.displaySize(saved)
            let red = AuditInk.pixelRect(
                CGRect(x: 300, y: 150, width: 200, height: 50), size: size, image: image)
            #expect(AuditInk.near(Self.hueBox(image, red: true), red, tolerance: 3))
            let box = AuditInk.pixelRect(covered, size: size, image: image)
            #expect(AuditInk.darkShare(image, in: box.insetBy(dx: 1, dy: 1)) > 0.97)
        }
        #expect(edit.redactionCount == 1)
        #expect(edit.placements.count == 1)
    }
}
