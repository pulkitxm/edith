import AppKit
import Foundation
import PDFKit
import Testing

@testable import EdithStudio

@Suite struct PDFAuditOrganizeTests {
    static let shifted = CGRect(x: 40, y: 70, width: 612, height: 792)

    func linkedPair(_ space: Workspace) throws -> (URL, URL) {
        let first = space.url("first.pdf")
        var letter = AuditPage.titled("Letter portrait")
        letter.link("Letter portrait", page: 1)
        try AuditPDF.write(
            [letter, .titled("A4 landscape", media: AuditPage.a4Landscape)], to: first,
            outline: [("Intro", 0), ("Wide", 1)])
        let second = space.url("second.pdf")
        var shifted = AuditPage.titled("Shifted page", media: Self.shifted)
        shifted.link("Shifted", page: 0)
        shifted.link("page", url: "https://example.com/terms")
        try AuditPDF.write([.titled("Turned page", rotation: 90), shifted], to: second)
        return (first, second)
    }

    @Test func mergeKeepsOrderSizesRotationBookmarksAndLinks() async throws {
        let space = try Workspace()
        let (first, second) = try linkedPair(space)
        let result = try await space.audited("pdf.merge", [first, second])
        let merged = try result.document()
        let texts = AuditPDF.texts(merged)
        #expect(texts == ["Letter portrait", "A4 landscape", "Turned page", "Shifted page"])
        let sizes = (0..<merged.pageCount).compactMap { merged.page(at: $0) }.map(
            StudioPDF.displaySize)
        let expected = [
            CGSize(width: 612, height: 792), CGSize(width: 841.89, height: 595.28),
            CGSize(width: 792, height: 612), CGSize(width: 612, height: 792),
        ]
        #expect(sizes.count == 4)
        for (size, want) in zip(sizes, expected) {
            #expect(abs(size.width - want.width) < 0.5 && abs(size.height - want.height) < 0.5)
        }
        #expect(merged.page(at: 2)?.rotation == 90)
        let root = try #require(merged.outlineRoot)
        #expect(root.numberOfChildren == 2)
        let top = (0..<root.numberOfChildren).compactMap { root.child(at: $0) }
        #expect(top.map(\.label) == ["first", "second"])
        let starts = top.map { item in item.destination?.page.map { merged.index(for: $0) } }
        #expect(starts == [0, 2])
        let nested = AuditPDF.outlineTargets(merged).filter { $0.0 == "Intro" || $0.0 == "Wide" }
        #expect(nested.map(\.1) == [0, 1])
        #expect(AuditPDF.linkTargets(merged, page: 0) == [1])
        #expect(AuditPDF.linkTargets(merged, page: 3) == [2])
        #expect(AuditPDF.linkURLs(merged, page: 3) == ["https://example.com/terms"])
        let shiftedPage = try #require(merged.page(at: 3))
        let word = try #require(merged.findString("Shifted", withOptions: []).first)
        let link = try #require(
            shiftedPage.annotations.first { $0.type == "Link" && $0.url == nil })
        #expect(link.bounds.intersects(word.bounds(for: shiftedPage)))
    }

    @Test func mergeRejectsBrokenAndLockedInputsInsteadOfSkippingThem() async throws {
        let space = try Workspace()
        let good = space.url("good.pdf")
        try AuditPDF.write([.titled("Good")], to: good)
        let empty = space.url("empty.pdf")
        try Data().write(to: empty)
        let garbage = space.url("garbage.pdf")
        try Data("%PDF-1.7\n1 0 obj << /Type /Catalog >> endobj\ntrailer\n%%EOF".utf8).write(
            to: garbage)
        let locked = space.url("locked.pdf")
        try AuditPDF.encrypt(good, to: locked, user: "open sesame", owner: "owner")
        await #expect(throws: StudioError.unreadable("empty.pdf")) {
            try await space.audited("pdf.merge", [good, empty])
        }
        await #expect(throws: StudioError.unreadable("garbage.pdf")) {
            try await space.audited("pdf.merge", [good, garbage])
        }
        await #expect(throws: StudioError.needsPassword("locked.pdf")) {
            try await space.audited("pdf.merge", [good, locked])
        }
        await #expect(throws: StudioError.wrongPassword("locked.pdf")) {
            try await space.audited("pdf.merge", [good, locked], ["password": .text("nope")])
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: space.output.path)
        #expect(files.isEmpty)
    }

    @Test func splitProducesExactlyTheRequestedPagesOfALongDocument() async throws {
        let space = try Workspace()
        let source = space.url("long.pdf")
        try AuditPDF.numbered(35, at: source)
        func pages(_ url: URL) -> [String] {
            AuditPDF.texts(url).map {
                $0.replacingOccurrences(of: "Page ", with: "")
                    .replacingOccurrences(of: " marker", with: "")
            }
        }
        let ranges = try await space.audited(
            "pdf.split", [source], ["ranges": .text("1-3, 10, 30-")])
        #expect(
            ranges.outputs.map { pages($0.url) } == [
                ["1", "2", "3"], ["10"], (30...35).map(String.init),
            ])
        #expect(
            ranges.outputs.map(\.url.lastPathComponent) == [
                "long-pages-1-3.pdf", "long-page-10.pdf", "long-pages-30-35.pdf",
            ])
        let odd = try await space.audited(
            "pdf.split", [source], ["mode": .text("extract"), "extract": .text("odd")])
        #expect(pages(try odd.url()) == stride(from: 1, through: 35, by: 2).map(String.init))
        let reversed = try await space.audited(
            "pdf.split", [source], ["mode": .text("extract"), "extract": .text("5-3, last")])
        #expect(pages(try reversed.url()) == ["5", "4", "3", "35"])
        let every = try await space.audited(
            "pdf.split", [source], ["mode": .text("every"), "size": .number(10)])
        #expect(every.outputs.map { pages($0.url).count } == [10, 10, 10, 5])
        #expect(every.outputs.last.map { pages($0.url).first } == "31")
        await #expect(throws: StudioError.self) {
            try await space.audited("pdf.split", [source], ["ranges": .text("1-3, 36")])
        }
    }

    @Test func splitKeepsLinksInsideEachPartAndDropsLinksOutOfIt() async throws {
        let space = try Workspace()
        let source = space.url("linked.pdf")
        var pages = (1...4).map { AuditPage.titled("Section \($0)") }
        pages[0].links = [
            AuditLink(rect: CGRect(x: 60, y: 600, width: 200, height: 20), page: 1),
            AuditLink(rect: CGRect(x: 60, y: 500, width: 200, height: 20), page: 3),
        ]
        try AuditPDF.write(pages, to: source, outline: [("One", 0), ("Two", 1), ("Four", 3)])
        let result = try await space.audited("pdf.split", [source], ["ranges": .text("1-2, 3-4")])
        let part = try result.document(0)
        #expect(AuditPDF.linkTargets(part, page: 0) == [1])
        let outline = AuditPDF.outlineTargets(part)
        #expect(outline.map(\.0) == ["One", "Two"])
        #expect(outline.map(\.1) == [0, 1])
    }

    @Test func removePagesRemovesExactlyThoseAndRetargetsBookmarks() async throws {
        let space = try Workspace()
        let source = space.url("long.pdf")
        var pages = (1...32).map { AuditPage.titled("Sheet \($0)") }
        pages[6].links = [AuditLink(rect: CGRect(x: 60, y: 600, width: 200, height: 20), page: 8)]
        try AuditPDF.write(
            pages, to: source, outline: [("First", 0), ("Sixth", 5), ("Seventh", 6)])
        let result = try await space.audited(
            "pdf.remove-pages", [source], ["pages": .text("1, 3-5, even, last")])
        let texts = AuditPDF.texts(try result.url())
        let removed = Set([1, 3, 4, 5, 32] + stride(from: 2, through: 32, by: 2).map { $0 })
        let kept = (1...32).filter { !removed.contains($0) }.map { "Sheet \($0)" }
        #expect(texts == kept)
        #expect(result.notes == ["Removed \(removed.count) pages."])
        let document = try result.document()
        let seventh = try #require(kept.firstIndex(of: "Sheet 7"))
        let ninth = try #require(kept.firstIndex(of: "Sheet 9"))
        #expect(AuditPDF.outlineTargets(document).map(\.0) == ["Seventh"])
        #expect(AuditPDF.outlineTargets(document).map(\.1) == [seventh])
        #expect(AuditPDF.linkTargets(document, page: seventh) == [ninth])
    }

    @Test func reorderMovesLinksAndBookmarksWithTheirPages() async throws {
        let space = try Workspace()
        let source = space.url("order.pdf")
        var pages = (1...3).map { AuditPage.titled("Part \($0)") }
        pages[0].link("Part 1", page: 2)
        try AuditPDF.write(pages, to: source, outline: [("Third", 2)])
        let result = try await space.audited(
            "pdf.reorder", [source], ["order": .text("custom"), "sequence": .text("3, 1, 2")])
        let document = try result.document()
        #expect(AuditPDF.texts(document) == ["Part 3", "Part 1", "Part 2"])
        #expect(AuditPDF.linkTargets(document, page: 1) == [0])
        #expect(AuditPDF.outlineTargets(document).map(\.1) == [0])
    }

    @Test func rotateComposesWithExistingRotationAndTurnsClockwise() async throws {
        let space = try Workspace()
        let source = space.url("turn.pdf")
        try AuditPDF.write(
            [
                .cornered("Upright"), .cornered("Already turned", rotation: 90),
                .cornered("Landscape", media: AuditPage.a4Landscape),
            ], to: source)
        let result = try await space.audited("pdf.rotate", [source], ["angle": .text("90")])
        let document = try result.document()
        #expect((0..<3).map { document.page(at: $0)?.rotation } == [90, 180, 90])
        let page = try #require(document.page(at: 0))
        let image = try AuditInk.render(page)
        let mark = try #require(AuditInk.box(image, below: 60))
        #expect(mark.maxX > CGFloat(image.width) - 70 && mark.minY < 70)
        let back = try await space.audited("pdf.rotate", [source], ["angle": .text("270")])
        #expect(try back.document().page(at: 1)?.rotation == 0)
        let numeric = try await space.audited("pdf.rotate", [source], ["angle": .number(180)])
        #expect(try numeric.document().page(at: 0)?.rotation == 180)
        await #expect(throws: StudioError.self) {
            try await space.audited("pdf.rotate", [source], ["angle": .text("45")])
        }
    }

    @Test func rotateOrientationFilterUsesTheDisplayedShape() async throws {
        let space = try Workspace()
        let source = space.url("mixed.pdf")
        try AuditPDF.write(
            [
                .titled("Portrait"), .titled("Wide", media: AuditPage.a4Landscape),
                .titled("Portrait shown wide", rotation: 90),
            ], to: source)
        let result = try await space.audited(
            "pdf.rotate", [source], ["angle": .text("270"), "orientation": .text("landscape")])
        let document = try result.document()
        #expect((0..<3).map { document.page(at: $0)?.rotation } == [0, 270, 0])
    }

    func cellMarks(_ page: PDFPage, columns: Int, rows: Int, count: Int) throws -> [Bool] {
        let size = StudioPDF.displaySize(page)
        let image = try AuditInk.render(page)
        let cellWidth = CGFloat(image.width) / CGFloat(columns)
        let cellHeight = CGFloat(image.height) / CGFloat(rows)
        return (0..<count).map { slot in
            let cell = CGRect(
                x: CGFloat(slot % columns) * cellWidth, y: CGFloat(slot / columns) * cellHeight,
                width: cellWidth, height: cellHeight)
            guard let mark = AuditInk.box(image, in: cell, below: 40) else { return false }
            _ = size
            return mark.minX < cell.minX + cellWidth * 0.2
                && mark.minY < cell.minY + cellHeight * 0.3
                && mark.width < cellWidth * 0.3
        }
    }

    @Test func nUpPutsEveryPageUprightInItsCell() async throws {
        let space = try Workspace()
        let source = space.url("deck.pdf")
        try AuditPDF.write(
            [
                .cornered("Card 1"), .cornered("Card 2", rotation: 90),
                .cornered("Card 3", media: Self.shifted), .cornered("Card 4", rotation: 180),
                .cornered("Card 5", media: AuditPage.a4Landscape),
            ], to: source)
        let result = try await space.audited(
            "pdf.n-up", [source], ["layout": .text("4"), "border": .bool(false)])
        let document = try result.document()
        #expect(document.pageCount == 2)
        let sheet = try #require(document.page(at: 0))
        let size = StudioPDF.displaySize(sheet)
        #expect(abs(size.width - 595.28) < 1 && abs(size.height - 841.89) < 1)
        #expect(try cellMarks(sheet, columns: 2, rows: 2, count: 4) == [true, true, true, true])
        for (index, label) in ["Card 1", "Card 2", "Card 3", "Card 4"].enumerated() {
            let found = try #require(document.findString(label, withOptions: []).first)
            let bounds = found.bounds(for: sheet)
            let column = index % 2
            let row = index / 2
            #expect(bounds.midX > CGFloat(column) * size.width / 2)
            #expect(bounds.midX < CGFloat(column + 1) * size.width / 2)
            #expect(bounds.midY < size.height - CGFloat(row) * size.height / 2)
            #expect(bounds.midY > size.height - CGFloat(row + 1) * size.height / 2)
        }
        #expect(document.page(at: 1)?.string?.contains("Card 5") == true)
    }

    @Test func nUpTwoPerSheetTurnsTheSheetAndKeepsAnnotationsVisible() async throws {
        let space = try Workspace()
        let source = space.url("two.pdf")
        try AuditPDF.write([.cornered("Left page"), .cornered("Right page")], to: source) {
            document in
            let page = try requireFixture(document.page(at: 1))
            let square = PDFAnnotation(
                bounds: CGRect(x: 300, y: 300, width: 120, height: 120), forType: .square,
                withProperties: nil)
            square.color = .red
            square.interiorColor = .red
            page.addAnnotation(square)
        }
        let result = try await space.audited("pdf.n-up", [source], ["layout": .text("2")])
        let sheet = try #require(try result.document().page(at: 0))
        let size = StudioPDF.displaySize(sheet)
        #expect(size.width > size.height)
        #expect(try cellMarks(sheet, columns: 2, rows: 1, count: 2) == [true, true])
        let image = try AuditInk.render(sheet)
        let red = try #require(AuditInk.coloredBox(image))
        #expect(red.minX > CGFloat(image.width) / 2)
    }

    @Test(arguments: AuditGeometry.all)
    func pageSizeFitsContentWithoutDistortionAndCentersIt(_ geometry: AuditGeometry) async throws {
        let space = try Workspace()
        let source = space.url("frame.pdf")
        let page = geometry.page { page in
            let size = page.layoutSize
            page.marks = [
                AuditMark(rect: CGRect(x: 0, y: 0, width: 40, height: 40)),
                AuditMark(
                    rect: CGRect(x: size.width - 40, y: size.height - 40, width: 40, height: 40)),
            ]
            page.texts = [AuditText(text: "Framed", x: 200, y: size.height / 2, size: 30)]
        }
        try AuditPDF.write([page], to: source)
        let result = try await space.audited("pdf.page-size", [source], ["paper": .text("a4")])
        let output = try #require(try result.document().page(at: 0))
        let size = StudioPDF.displaySize(output)
        let portrait = page.displaySize.height >= page.displaySize.width
        #expect((size.height >= size.width) == portrait)
        let a4 =
            portrait ? CGSize(width: 595.28, height: 841.89) : CGSize(width: 841.89, height: 595.28)
        #expect(abs(size.width - a4.width) < 1 && abs(size.height - a4.height) < 1)
        let image = try AuditInk.render(output)
        let ink = try #require(AuditInk.box(image, below: 60))
        let scale = min(a4.width / page.displaySize.width, a4.height / page.displaySize.height)
        #expect(abs(ink.width - page.displaySize.width * scale) < 3)
        #expect(abs(ink.height - page.displaySize.height * scale) < 3)
        #expect(abs(ink.midX - CGFloat(image.width) / 2) < 2)
        #expect(abs(ink.midY - CGFloat(image.height) / 2) < 2)
        #expect(output.string?.contains("Framed") == true)
    }

    @Test func pageSizeKeepsAnnotationsLinksAndBookmarks() async throws {
        let space = try Workspace()
        let source = space.url("notes.pdf")
        var first = AuditPage.titled("First page", media: Self.shifted)
        first.link("First page", page: 1)
        try AuditPDF.write(
            [first, .titled("Second page", rotation: 90)], to: source, outline: [("Second", 1)]
        ) { document in
            let page = try requireFixture(document.page(at: 0))
            let square = PDFAnnotation(
                bounds: CGRect(x: 340, y: 370, width: 100, height: 100), forType: .square,
                withProperties: nil)
            square.color = .blue
            square.interiorColor = .blue
            page.addAnnotation(square)
        }
        let result = try await space.audited("pdf.page-size", [source], ["paper": .text("a4")])
        let document = try result.document()
        let image = try AuditInk.render(try #require(document.page(at: 0)))
        #expect(AuditInk.coloredBox(image) != nil)
        #expect(AuditPDF.linkTargets(document, page: 0) == [1])
        #expect(AuditPDF.outlineTargets(document).map(\.1) == [1])
        let link = try #require(document.page(at: 0)?.annotations.first { $0.type == "Link" })
        let title = try #require(document.findString("First page", withOptions: []).first)
        let titleBounds = title.bounds(for: try #require(document.page(at: 0)))
        #expect(link.bounds.intersects(titleBounds))
    }

    @Test(arguments: AuditGeometry.all)
    func cropMarginsCutTheDisplayedEdgesOnEveryGeometry(_ geometry: AuditGeometry) async throws {
        let space = try Workspace()
        let source = space.url("cut.pdf")
        let page = geometry.page { page in
            let size = page.layoutSize
            page.marks = [AuditMark(rect: CGRect(x: 0, y: size.height - 60, width: 60, height: 60))]
            page.texts = [
                AuditText(text: "Keep this title", x: 100, y: size.height - 130, size: 24)
            ]
        }
        try AuditPDF.write([page], to: source)
        let original = try #require(PDFDocument(url: source)?.page(at: 0))
        let before = try AuditInk.render(original)
        let title = try #require(
            AuditInk.box(before, in: CGRect(x: 80, y: 0, width: 500, height: 200)))
        let result = try await space.audited(
            "pdf.crop", [source],
            [
                "mode": .text("margins"), "top": .number(70), "left": .number(30),
                "right": .number(10), "bottom": .number(20),
            ])
        let output = try #require(try result.document().page(at: 0))
        let size = StudioPDF.displaySize(output)
        #expect(abs(size.width - (page.displaySize.width - 40)) < 0.5)
        #expect(abs(size.height - (page.displaySize.height - 90)) < 0.5)
        let after = try AuditInk.render(output)
        #expect(
            AuditInk.box(after, in: CGRect(x: 0, y: 0, width: 40, height: 40), below: 60) == nil)
        let moved = try #require(
            AuditInk.box(after, in: CGRect(x: 40, y: 0, width: 500, height: 200)))
        #expect(abs(moved.minX - (title.minX - 30)) <= 1.5)
        #expect(abs(moved.minY - (title.minY - 70)) <= 1.5)
    }

    @Test(arguments: AuditGeometry.all)
    func autoCropHugsTheContentOnEveryGeometry(_ geometry: AuditGeometry) async throws {
        let space = try Workspace()
        let source = space.url("auto.pdf")
        let page = geometry.page { page in
            page.marks = [AuditMark(rect: CGRect(x: 150, y: 200, width: 120, height: 80))]
            page.texts = [AuditText(text: "Content", x: 300, y: 400, size: 30)]
        }
        try AuditPDF.write([page], to: source)
        let before = try AuditInk.render(try #require(PDFDocument(url: source)?.page(at: 0)))
        let ink = try #require(AuditInk.box(before, below: 200))
        let result = try await space.audited("pdf.crop", [source], ["padding": .number(10)])
        let output = try #require(try result.document().page(at: 0))
        let size = StudioPDF.displaySize(output)
        #expect(abs(size.width - (ink.width + 20)) <= 3)
        #expect(abs(size.height - (ink.height + 20)) <= 3)
        let after = try AuditInk.render(output)
        let moved = try #require(AuditInk.box(after, below: 200))
        #expect(abs(moved.minX - 10) <= 2 && abs(moved.minY - 10) <= 2)
        #expect(output.string?.contains("Content") == true)
    }
}
