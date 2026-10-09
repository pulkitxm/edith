import Foundation
import PDFKit
import Testing

@testable import EdithStudio

@Suite struct PDFOrganizeTests {
    @Test func mergeCombinesPDFsAndImagesWithBookmarks() async throws {
        let space = try Workspace()
        let a = space.url("alpha.pdf")
        let b = space.url("beta.pdf")
        let photo = space.url("photo.png")
        try Fixtures.pdf(at: a, pages: ["Alpha one", "Alpha two"])
        try Fixtures.pdf(at: b, pages: ["Beta one", "Beta two", "Beta three"])
        try Fixtures.image(at: photo, width: 800, height: 600)
        let result = try await space.run("pdf.merge", [a, b, photo])
        let output = try #require(result.outputs.first)
        #expect(output.url.lastPathComponent == "alpha-merged.pdf")
        let merged = try #require(PDFDocument(url: output.url))
        #expect(merged.pageCount == 6)
        #expect(merged.page(at: 2)?.string?.contains("Beta one") == true)
        #expect(merged.outlineRoot?.numberOfChildren == 3)
        #expect(merged.outlineRoot?.child(at: 1)?.label == "beta")
    }

    @Test func mergeNeedsTwoFiles() async throws {
        let space = try Workspace()
        let a = space.url("alpha.pdf")
        try Fixtures.pdf(at: a, pages: ["Only"])
        await #expect(throws: StudioError.needsMoreInputs(2)) {
            try await space.run("pdf.merge", [a])
        }
    }

    @Test func splitByRangesEveryAndExtract() async throws {
        let space = try Workspace()
        let source = space.url("book.pdf")
        try Fixtures.pdf(at: source, pages: (1...5).map { "Chapter \($0)" })

        let ranges = try await space.run("pdf.split", [source], ["ranges": .text("1-2, 3-")])
        #expect(ranges.outputs.count == 2)
        #expect(ranges.folders.count == 1)
        let counts = ranges.outputs.map { PDFDocument(url: $0.url)?.pageCount ?? 0 }
        #expect(counts.sorted() == [2, 3])

        let every = try await space.run(
            "pdf.split", [source], ["mode": .text("every"), "size": .number(2)])
        #expect(
            every.outputs.map { PDFDocument(url: $0.url)?.pageCount ?? 0 }.sorted() == [1, 2, 2])

        let pages = try await space.run("pdf.split", [source], ["mode": .text("pages")])
        #expect(pages.outputs.count == 5)
        #expect(pages.outputs.contains { $0.url.lastPathComponent == "book-page-3.pdf" })

        let extract = try await space.run(
            "pdf.split", [source], ["mode": .text("extract"), "extract": .text("4, 2")])
        let extracted = try extract.document()
        #expect(extracted.pageCount == 2)
        #expect(extracted.page(at: 0)?.string?.contains("Chapter 4") == true)
        #expect(extracted.page(at: 1)?.string?.contains("Chapter 2") == true)
    }

    @Test func removePagesKeepsTheRest() async throws {
        let space = try Workspace()
        let source = space.url("deck.pdf")
        try Fixtures.pdf(at: source, pages: ["One", "Two", "Three", "Four"])
        let result = try await space.run("pdf.remove-pages", [source], ["pages": .text("2, last")])
        let output = try result.document()
        #expect(output.pageCount == 2)
        #expect(output.page(at: 1)?.string?.contains("Three") == true)
        #expect(result.notes.contains("Removed 2 pages."))

        await #expect(throws: StudioError.self) {
            try await space.run("pdf.remove-pages", [source], ["pages": .text("all")])
        }
    }

    @Test func removePagesCanDropBlankPages() async throws {
        let space = try Workspace()
        let source = space.url("scan.pdf")
        try Fixtures.pdf(at: source, pages: ["Cover", "", "Body", ""])
        let result = try await space.run(
            "pdf.remove-pages", [source], ["pages": .text("1"), "blank": .bool(true)])
        let output = try result.document()
        #expect(output.pageCount == 1)
        #expect(output.page(at: 0)?.string?.contains("Body") == true)
    }

    @Test func reorderReverseCustomAndInterleave() async throws {
        let space = try Workspace()
        let source = space.url("pages.pdf")
        try Fixtures.pdf(at: source, pages: (1...6).map { "Page\($0)" })
        func order(_ values: [String: StudioValue]) async throws -> [String] {
            let result = try await space.run("pdf.reorder", [source], values)
            let document = try result.document()
            return (0..<document.pageCount).map {
                document.page(at: $0)?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            }
        }
        #expect(try await order([:]) == ["Page6", "Page5", "Page4", "Page3", "Page2", "Page1"])
        #expect(
            try await order(["order": .text("custom"), "sequence": .text("3, 1")]) == [
                "Page3", "Page1",
            ])
        #expect(
            try await order(["order": .text("interleave")])
                == ["Page1", "Page6", "Page2", "Page5", "Page3", "Page4"])
        #expect(PDFPageOrder.interleaved(count: 5) == [0, 4, 1, 3, 2])
    }

    @Test func rotateSelectedAndFilteredPages() async throws {
        let space = try Workspace()
        let source = space.url("mixed.pdf")
        try Fixtures.pdf(at: source, pages: ["A", "B", "C"])
        let result = try await space.run(
            "pdf.rotate", [source], ["angle": .text("90"), "pages": .text("2-3")])
        let document = try result.document()
        #expect(document.page(at: 0)?.rotation == 0)
        #expect(document.page(at: 1)?.rotation == 90)
        #expect(document.page(at: 2)?.rotation == 90)

        await #expect(throws: StudioError.self) {
            try await space.run("pdf.rotate", [source], ["orientation": .text("landscape")])
        }
    }

    @Test func nUpPlacesFourPagesOnEachSheet() async throws {
        let space = try Workspace()
        let source = space.url("handout.pdf")
        try Fixtures.pdf(at: source, pages: (1...9).map { "Slide \($0)" })
        let result = try await space.run("pdf.n-up", [source], ["layout": .text("4")])
        let document = try result.document()
        #expect(document.pageCount == 3)
        let text = document.page(at: 0)?.string ?? ""
        #expect(text.contains("Slide 1") && text.contains("Slide 4"))
        #expect(!text.contains("Slide 5"))
    }

    @Test func changePageSizeFitsOntoA4() async throws {
        let space = try Workspace()
        let source = space.url("letter.pdf")
        try Fixtures.pdf(at: source, pages: ["Letter page"], size: CGSize(width: 300, height: 400))
        let result = try await space.run("pdf.page-size", [source], ["paper": .text("a4")])
        let document = try result.document()
        let box = try #require(document.page(at: 0)?.bounds(for: .mediaBox))
        #expect(abs(box.width - 595.28) < 1)
        #expect(abs(box.height - 841.89) < 1)
        #expect(document.page(at: 0)?.string?.contains("Letter page") == true)
    }

    @Test func autoCropTrimsWhiteMarginsAndFixedMarginsCut() async throws {
        let space = try Workspace()
        let source = space.url("margins.pdf")
        try Fixtures.pdf(at: source, pages: ["Short text"])
        let auto = try await space.run("pdf.crop", [source])
        let trimmed = try auto.document()
        let box = try #require(trimmed.page(at: 0)?.bounds(for: .cropBox))
        #expect(box.width < 300)
        #expect(box.height < 200)
        #expect(trimmed.page(at: 0)?.string?.contains("Short text") == true)

        let fixed = try await space.run(
            "pdf.crop", [source],
            [
                "mode": .text("margins"), "top": .number(100), "left": .number(50),
                "right": .number(50), "bottom": .number(0),
            ])
        let cut = try fixed.document()
        let cutBox = try #require(cut.page(at: 0)?.bounds(for: .cropBox))
        #expect(abs(cutBox.width - 512) < 1)
        #expect(abs(cutBox.height - 692) < 1)
    }

    @Test func pageSelectionParsing() throws {
        #expect(try StudioPageSelection.pages("all", pageCount: 3) == [0, 1, 2])
        #expect(try StudioPageSelection.pages("1-2, 5", pageCount: 5) == [0, 1, 4])
        #expect(try StudioPageSelection.pages("odd", pageCount: 5) == [0, 2, 4])
        #expect(try StudioPageSelection.pages("even", pageCount: 5) == [1, 3])
        #expect(try StudioPageSelection.pages("3-", pageCount: 5) == [2, 3, 4])
        #expect(try StudioPageSelection.pages("last", pageCount: 5) == [4])
        #expect(try StudioPageSelection.pages("3-1", pageCount: 5) == [2, 1, 0])
        #expect(try StudioPageSelection.groups("1-2;4", pageCount: 5) == [[0, 1], [3]])
        #expect(throws: StudioError.self) { try StudioPageSelection.pages("9", pageCount: 5) }
        #expect(throws: StudioError.self) { try StudioPageSelection.pages("x", pageCount: 5) }
        #expect(throws: StudioError.self) { try StudioPageSelection.pages("0", pageCount: 5) }
    }
}
