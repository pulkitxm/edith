import AppKit
import Foundation
import PDFKit
import Testing

@testable import EdithStudio

@Suite struct PDFToolsTests {
    @Test func compressShrinksPhotoHeavyPDFs() async throws {
        let space = try Workspace()
        let source = space.url("photos.pdf")
        try Fixtures.photoPDF(at: source)
        let before = StudioRunner.fileSize(source)
        let recommended = try await space.run("pdf.compress", [source])
        #expect(try #require(recommended.outputs.first).bytes < before)
        #expect(try recommended.url().lastPathComponent == "photos-compressed.pdf")
        let extreme = try await space.run("pdf.compress", [source], ["level": .text("extreme")])
        let extremeFile = try #require(extreme.outputs.first)
        #expect(extremeFile.bytes < before / 2)
        #expect(Fixtures.text(of: extremeFile.url).contains("Photo page 2"))
        #expect(try #require(extreme.savings) > 0.5)
    }

    @Test func compressNeverGrowsAFile() async throws {
        let space = try Workspace()
        let source = space.url("tiny.pdf")
        try Fixtures.pdf(at: source, pages: ["Tiny"])
        let result = try await space.run("pdf.compress", [source])
        #expect(try #require(result.outputs.first).bytes <= StudioRunner.fileSize(source))
    }

    @Test func grayscaleRemovesColor() async throws {
        let space = try Workspace()
        let source = space.url("color.pdf")
        try Fixtures.photoPDF(at: source, pages: 1, imageSize: 400)
        let result = try await space.run("pdf.grayscale", [source])
        let page = try #require(try result.document().page(at: 0))
        let image = try StudioPDF.render(page, dpi: 36)
        let sample = Fixtures.pixel(image, x: image.width / 2, y: image.height / 2)
        #expect(abs(sample.r - sample.g) <= 3 && abs(sample.g - sample.b) <= 3)
        #expect(page.string?.contains("Photo page 1") == true)
    }

    @Test func ocrMakesScannedPagesSearchable() async throws {
        let space = try Workspace()
        let text = space.url("text.pdf")
        try Fixtures.pdf(at: text, pages: ["Invoice Number 4821\nTotal Due Friday"], fontSize: 28)
        let rendered = try StudioPDF.render(
            try #require(PDFDocument(url: text)?.page(at: 0)), dpi: 150)
        let scan = space.url("scan.png")
        try StudioImageIO.write(rendered, to: scan, format: .png)
        let scanned = try await space.run("pdf.from-images", [scan], ["paper": .text("fit")])
        let scannedURL = try scanned.url()
        #expect(
            Fixtures.text(of: scannedURL).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        let result = try await space.run("pdf.ocr", [scannedURL])
        let recognized = Fixtures.text(of: try result.url())
        #expect(recognized.contains("Invoice"))
        #expect(recognized.contains("4821"))

        let direct = try await space.run("pdf.ocr", [scan])
        #expect(Fixtures.text(of: try direct.url()).contains("Total"))
    }

    @Test func ocrSkipsPagesThatHaveText() async throws {
        let space = try Workspace()
        let source = space.url("digital.pdf")
        try Fixtures.pdf(
            at: source, pages: ["This page already has plenty of selectable text in it."])
        await #expect(throws: StudioError.self) { try await space.run("pdf.ocr", [source]) }
    }

    @Test func repairRewritesReadableFiles() async throws {
        let space = try Workspace()
        let source = space.url("ok.pdf")
        try Fixtures.pdf(at: source, pages: ["Recover me"])
        var data = try Data(contentsOf: source)
        if let range = data.range(of: Data("startxref".utf8), options: .backwards) {
            data.replaceSubrange(
                range.lowerBound..<data.endIndex, with: Data("startxref\n0\n%%EOF".utf8))
        }
        let damaged = space.url("damaged.pdf")
        try data.write(to: damaged)
        let result = try await space.run("pdf.repair", [damaged])
        #expect(Fixtures.text(of: try result.url()).contains("Recover me"))
    }

    @Test func flattenBurnsAnnotationsIntoPages() async throws {
        let space = try Workspace()
        let source = space.url("notes.pdf")
        try Fixtures.pdf(at: source, pages: ["Body"])
        let document = try #require(PDFDocument(url: source))
        let note = PDFAnnotation(
            bounds: CGRect(x: 100, y: 100, width: 200, height: 40), forType: .freeText,
            withProperties: nil)
        note.contents = "Reviewed"
        note.font = NSFont.systemFont(ofSize: 18)
        document.page(at: 0)?.addAnnotation(note)
        let annotated = space.url("annotated.pdf")
        #expect(document.write(to: annotated))
        let result = try await space.run("pdf.flatten", [annotated])
        let flattened = try result.document()
        #expect(flattened.page(at: 0)?.annotations.isEmpty == true)
        #expect(flattened.page(at: 0)?.string?.contains("Reviewed") == true)
    }

    @Test func pagesToImagesAndExtractEmbeddedImages() async throws {
        let space = try Workspace()
        let source = space.url("mixed.pdf")
        try Fixtures.photoPDF(at: source, pages: 2, imageSize: 320)
        let pages = try await space.run(
            "pdf.to-images", [source], ["dpi": .text("72"), "format": .text("png")])
        #expect(pages.outputs.count == 2)
        #expect(pages.outputs.allSatisfy { $0.url.pathExtension == "png" })
        let info = try #require(StudioImageIO.info(try pages.url()))
        #expect(info.width == 612 && info.height == 792)

        let extracted = try await space.run("pdf.to-images", [source], ["mode": .text("extract")])
        #expect(extracted.outputs.count == 2)
        #expect(extracted.outputs.allSatisfy { $0.url.pathExtension == "jpg" })
        #expect(StudioImageIO.info(try extracted.url())?.width == 320)
    }

    @Test func imagesToPDFCombinesOrSeparates() async throws {
        let space = try Workspace()
        let first = space.url("first.png")
        let second = space.url("second.jpg")
        try Fixtures.image(at: first, width: 800, height: 400)
        try Fixtures.image(at: second, width: 300, height: 600, format: .jpeg)
        let combined = try await space.run("pdf.from-images", [first, second])
        let document = try combined.document()
        #expect(document.pageCount == 2)
        let landscape = try #require(document.page(at: 0)?.bounds(for: .mediaBox))
        #expect(landscape.width > landscape.height)
        let separate = try await space.run(
            "pdf.from-images", [first, second], ["combine": .bool(false), "paper": .text("fit")])
        #expect(separate.outputs.count == 2)
        let fit = try #require(try separate.document(1).page(at: 0)?.bounds(for: .mediaBox))
        #expect(abs(fit.width - 300) < 1 && abs(fit.height - 600) < 1)
    }

    @Test func watermarkStampsTextOnSelectedPagesAndKeepsRotation() async throws {
        let space = try Workspace()
        let source = space.url("contract.pdf")
        try Fixtures.pdf(at: source, pages: ["Page one", "Page two"], rotation: 90)
        let result = try await space.run(
            "pdf.watermark", [source], ["text": .text("DRAFT COPY"), "pages": .text("2")])
        let document = try result.document()
        #expect(document.page(at: 0)?.string?.contains("DRAFT") == false)
        #expect(document.page(at: 1)?.string?.contains("DRAFT COPY") == true)
        #expect(document.page(at: 1)?.rotation == 90)
        #expect(document.page(at: 1)?.string?.contains("Page two") == true)
    }

    @Test func imageWatermarkAndTiledLayout() async throws {
        let space = try Workspace()
        let source = space.url("brochure.pdf")
        let logo = space.url("logo.png")
        try Fixtures.pdf(at: source, pages: ["Brochure"])
        try Fixtures.image(at: logo, width: 200, height: 100)
        let result = try await space.run(
            "pdf.watermark", [source],
            [
                "kind": .text("image"), "image": .text(logo.path), "position": .text("tiled"),
                "opacity": .number(1),
            ])
        let page = try #require(try result.document().page(at: 0))
        let image = try StudioPDF.render(page, dpi: 36)
        var colored = 0
        for x in stride(from: 0, to: image.width, by: 8) {
            for y in stride(from: 0, to: image.height, by: 8) {
                let pixel = Fixtures.pixel(image, x: x, y: y)
                if abs(pixel.r - pixel.g) > 60 { colored += 1 }
            }
        }
        #expect(colored > 20)
    }

    @Test func pageNumbersFollowTheTemplate() async throws {
        let space = try Workspace()
        let source = space.url("report.pdf")
        try Fixtures.pdf(at: source, pages: ["Intro", "Body", "End"])
        let result = try await space.run(
            "pdf.page-numbers", [source], ["format": .text("Page {n} of {total}")])
        let document = try result.document()
        #expect(document.page(at: 1)?.string?.contains("Page 2 of 3") == true)
        let skipped = try await space.run(
            "pdf.page-numbers", [source],
            ["format": .text("custom"), "custom": .text("{file} #{n}"), "skipFirst": .bool(true)])
        let skippedDocument = try skipped.document()
        #expect(skippedDocument.page(at: 0)?.string?.contains("#") == false)
        #expect(skippedDocument.page(at: 1)?.string?.contains("report #1") == true)
    }

    @Test func metadataIsWrittenAndCleared() async throws {
        let space = try Workspace()
        let source = space.url("meta.pdf")
        try Fixtures.pdf(at: source, pages: ["Meta"], title: "Old title")
        let result = try await space.run(
            "pdf.metadata", [source], ["title": .text("New title"), "author": .text("Studio")])
        let attributes = try result.document().documentAttributes ?? [:]
        #expect(attributes[PDFDocumentAttribute.titleAttribute] as? String == "New title")
        #expect(attributes[PDFDocumentAttribute.authorAttribute] as? String == "Studio")
        let cleared = try await space.run("pdf.metadata", [source], ["clear": .bool(true)])
        let clearedAttributes = try cleared.document().documentAttributes ?? [:]
        #expect((clearedAttributes[PDFDocumentAttribute.titleAttribute] as? String ?? "").isEmpty)
    }

    @Test func protectThenUnlock() async throws {
        let space = try Workspace()
        let source = space.url("secret.pdf")
        try Fixtures.pdf(at: source, pages: ["Top secret"])
        let protected = try await space.run(
            "pdf.protect", [source], ["userPassword": .text("hunter2")])
        let locked = try protected.url()
        let reopened = try #require(PDFDocument(url: locked))
        #expect(reopened.isLocked)
        #expect(reopened.unlock(withPassword: "hunter2"))
        #expect(reopened.page(at: 0)?.string?.contains("Top secret") == true)

        await #expect(throws: StudioError.needsPassword("secret-protected.pdf")) {
            try await space.run("pdf.unlock", [locked])
        }
        await #expect(throws: StudioError.wrongPassword("secret-protected.pdf")) {
            try await space.run("pdf.unlock", [locked], ["password": .text("nope")])
        }
        let unlocked = try await space.run("pdf.unlock", [locked], ["password": .text("hunter2")])
        let open = try unlocked.document()
        #expect(!open.isEncrypted && !open.isLocked)
        #expect(open.page(at: 0)?.string?.contains("Top secret") == true)

        let merged = try await space.run(
            "pdf.merge", [locked, source], ["password": .text("hunter2")])
        #expect(try merged.document().pageCount == 2)
    }

    @Test func protectRequiresAPassword() async throws {
        let space = try Workspace()
        let source = space.url("open.pdf")
        try Fixtures.pdf(at: source, pages: ["Open"])
        await #expect(throws: StudioError.self) { try await space.run("pdf.protect", [source]) }
        await #expect(throws: StudioError.self) { try await space.run("pdf.unlock", [source]) }
    }

    @Test func redactRemovesMatchesButKeepsOtherTextSearchable() async throws {
        let space = try Workspace()
        let source = space.url("letter.pdf")
        try Fixtures.pdf(
            at: source,
            pages: [
                "Dear Customer\n\nContact jane.doe@example.com about the Project Falcon budget.\n\nKind regards",
                "Nothing sensitive here",
            ], fontSize: 20)
        let result = try await space.run(
            "pdf.redact", [source], ["terms": .text("Falcon"), "phones": .bool(false)])
        let text = Fixtures.text(of: try result.url())
        #expect(!text.contains("example.com"))
        #expect(!text.contains("Falcon"))
        #expect(text.contains("Customer"))
        #expect(text.contains("Nothing sensitive here"))
        #expect(result.notes.first?.contains("on 1 page") == true)
        let marks = PDFRedaction.find(
            terms: [], patterns: [.email], in: try #require(PDFDocument(url: source)))
        #expect(marks[0]?.isEmpty == false)
    }

    @Test func redactWithoutMatchesExplainsItself() async throws {
        let space = try Workspace()
        let source = space.url("plain.pdf")
        try Fixtures.pdf(at: source, pages: ["Nothing to see"])
        await #expect(throws: StudioError.self) {
            try await space.run("pdf.redact", [source], ["terms": .text("zebra")])
        }
    }

    @Test func officeAndTextConversions() async throws {
        let space = try Workspace()
        let source = space.url("report.pdf")
        try Fixtures.structuredPDF(at: source)

        let markdown = try String(
            contentsOf: try await space.run("pdf.to-markdown", [source]).url())
        #expect(markdown.contains("# Quarterly Report"))
        #expect(markdown.contains("Highlights"))
        #expect(markdown.contains("- Launched two products"))
        #expect(
            markdown.contains("Revenue grew across every region this quarter. Costs stayed flat"))

        let text = try String(contentsOf: try await space.run("pdf.to-text", [source]).url())
        #expect(text.contains("Opened the Berlin office"))

        let word = try await space.run("pdf.to-word", [source])
        let wordParts = try OOXMLPackage.read(try word.url())
        let body = String(decoding: try #require(wordParts["word/document.xml"]), as: UTF8.self)
        #expect(body.contains("Quarterly Report"))
        #expect(body.contains("Heading1"))

        let excel = try await space.run("pdf.to-excel", [source])
        let excelParts = try OOXMLPackage.read(try excel.url())
        let sheet = String(
            decoding: try #require(excelParts["xl/worksheets/sheet1.xml"]), as: UTF8.self)
        #expect(sheet.contains("Region"))
        #expect(sheet.contains("<v>140</v>"))

        let slides = try await space.run("pdf.to-powerpoint", [source])
        let slideParts = try OOXMLPackage.read(try slides.url())
        #expect(slideParts["ppt/slides/slide1.xml"] != nil)
        #expect(slideParts["ppt/media/image1.jpg"] != nil)

        let layout = try await space.run("pdf.to-word", [source], ["mode": .text("layout")])
        #expect(try OOXMLPackage.read(try layout.url())["word/media/image1.jpg"] != nil)
    }

    @Test func pdfaCarriesArchivalMetadata() async throws {
        let space = try Workspace()
        let source = space.url("archive.pdf")
        try Fixtures.pdf(at: source, pages: ["Keep forever"], title: "Records")
        for mode in ["vector", "flatten"] {
            let result = try await space.run("pdf.to-pdfa", [source], ["mode": .text(mode)])
            let archived = try #require(CGPDFDocument(try result.url() as CFURL))
            let catalog = try #require(archived.catalog)
            var stream: CGPDFStreamRef?
            #expect(CGPDFDictionaryGetStream(catalog, "Metadata", &stream))
            var format = CGPDFDataFormat.raw
            let xmp = try #require(stream.flatMap { CGPDFStreamCopyData($0, &format) } as Data?)
            #expect(String(decoding: xmp, as: UTF8.self).contains("<pdfaid:part>2</pdfaid:part>"))
            var intents: CGPDFArrayRef?
            #expect(CGPDFDictionaryGetArray(catalog, "OutputIntents", &intents))
            #expect(archived.numberOfPages == 1)
            #expect(Fixtures.text(of: try result.url()).contains("Keep forever"))
        }
    }

    @Test func compareFindsAddedAndRemovedLines() async throws {
        let space = try Workspace()
        let original = space.url("v1.pdf")
        let revised = space.url("v2.pdf")
        try Fixtures.pdf(at: original, pages: ["Alpha clause\nBeta clause\nGamma clause"])
        try Fixtures.pdf(at: revised, pages: ["Alpha clause\nBeta clause revised\nGamma clause"])
        let report = PDFComparison.compare(
            try #require(PDFDocument(url: original)), try #require(PDFDocument(url: revised)))
        #expect(report.removed.map(\.text) == ["Beta clause"])
        #expect(report.added.map(\.text) == ["Beta clause revised"])
        #expect(!report.isIdentical)
        let same = PDFComparison.compare(
            try #require(PDFDocument(url: original)), try #require(PDFDocument(url: original)))
        #expect(same.isIdentical)

        let run = try await space.run("pdf.compare", [original, revised])
        let markdown = try String(contentsOf: try run.url())
        #expect(markdown.contains("+ p1: Beta clause revised"))

        let visual = try PDFComparison.visualDifference(
            try #require(PDFDocument(url: original)?.page(at: 0)),
            try #require(PDFDocument(url: revised)?.page(at: 0)))
        #expect(visual.changedFraction > 0)
    }

    @Test func rebuildKeepsLinksAnnotationsAndOutline() async throws {
        let space = try Workspace()
        let source = space.url("linked.pdf")
        try Fixtures.pdf(at: source, pages: ["First", "Second"])
        let document = StudioPDF.fresh(from: try #require(PDFDocument(url: source)))
        let link = PDFAnnotation(
            bounds: CGRect(x: 50, y: 50, width: 100, height: 20), forType: .link,
            withProperties: nil)
        link.destination = PDFDestination(page: try #require(document.page(at: 1)), at: .zero)
        document.page(at: 0)?.addAnnotation(link)
        let outline = PDFOutline()
        let item = PDFOutline()
        item.label = "Second"
        item.destination = PDFDestination(page: try #require(document.page(at: 1)), at: .zero)
        outline.insertChild(item, at: 0)
        document.outlineRoot = outline
        let prepared = space.url("prepared.pdf")
        #expect(document.write(to: prepared))

        let result = try await space.run("pdf.watermark", [prepared], ["text": .text("X")])
        let rebuilt = try result.document()
        let copied = try #require(rebuilt.page(at: 0)?.annotations.first { $0.type == "Link" })
        let target = copied.destination ?? (copied.action as? PDFActionGoTo)?.destination
        #expect(target?.page == rebuilt.page(at: 1))
        #expect(rebuilt.outlineRoot?.child(at: 0)?.label == "Second")
        #expect(rebuilt.outlineRoot?.child(at: 0)?.destination?.page == rebuilt.page(at: 1))
    }
}
