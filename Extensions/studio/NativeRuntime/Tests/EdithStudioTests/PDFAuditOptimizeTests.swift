import AppKit
import Foundation
import PDFKit
import Testing

@testable import EdithStudio

@Suite struct PDFAuditOptimizeTests {
    func structured(_ space: Workspace, photos: Bool) throws -> URL {
        let url = space.url("structured.pdf")
        var first = AuditPage.titled("Photo report")
        var second = AuditPage.titled("Turned photo page", rotation: 90, upright: false)
        var third = AuditPage.titled(
            "Shifted page", media: CGRect(x: 40, y: 70, width: 612, height: 792))
        if photos {
            first.images = [
                AuditImage(kind: .photo, rect: CGRect(x: 60, y: 200, width: 480, height: 360))
            ]
            second.images = [
                AuditImage(kind: .photo, rect: CGRect(x: 60, y: 100, width: 480, height: 360))
            ]
            third.images = [
                AuditImage(kind: .alphaPNG, rect: CGRect(x: 100, y: 200, width: 300, height: 300))
            ]
        }
        first.link("Photo", page: 2)
        first.link("report", url: "https://example.com/report")
        try AuditPDF.write(
            [first, second, third], to: url, outline: [("Start", 0), ("Shifted", 2)]
        ) { document in
            let page = try requireFixture(document.page(at: 0))
            let note = PDFAnnotation(
                bounds: CGRect(x: 400, y: 100, width: 120, height: 60), forType: .square,
                withProperties: nil)
            note.color = .red
            page.addAnnotation(note)
        }
        return url
    }

    func sizes(_ document: PDFDocument) -> [CGSize] {
        (0..<document.pageCount).compactMap { document.page(at: $0) }.map {
            let size = StudioPDF.displaySize($0)
            return CGSize(width: size.width.rounded(), height: size.height.rounded())
        }
    }

    @Test(arguments: ["low", "recommended", "extreme"])
    func compressShrinksWithoutLosingPagesTextOrNavigation(_ level: String) async throws {
        let space = try Workspace()
        let source = try structured(space, photos: true)
        let original = try #require(PDFDocument(url: source))
        let result = try await space.audited(
            "pdf.compress", [source], ["level": .text(level)], environment: space.withoutEngines)
        let file = try #require(result.outputs.first)
        let before = StudioRunner.fileSize(source)
        #expect(level == "low" ? file.bytes <= before : file.bytes < before)
        let document = try result.document()
        #expect(sizes(document) == sizes(original))
        #expect(AuditPDF.texts(document) == AuditPDF.texts(original))
        #expect(AuditPDF.linkTargets(document, page: 0) == [2])
        #expect(AuditPDF.linkURLs(document, page: 0) == ["https://example.com/report"])
        #expect(AuditPDF.outlineTargets(document).map(\.1) == [0, 2])
        let turned = try #require(document.page(at: 1))
        let turnedSize = StudioPDF.displaySize(turned)
        #expect(turnedSize.width > turnedSize.height)
    }

    @Test func compressNeverGrowsTextOnlyFilesAndSaysSo() async throws {
        let space = try Workspace()
        let source = try structured(space, photos: false)
        for level in ["low", "recommended", "extreme"] {
            let result = try await space.audited(
                "pdf.compress", [source], ["level": .text(level)],
                environment: space.withoutEngines)
            #expect(try #require(result.outputs.first).bytes <= StudioRunner.fileSize(source))
            #expect(AuditPDF.texts(try result.url()) == AuditPDF.texts(source))
        }
    }

    @Test func grayscaleLeavesNoColoredPixelsAnywhere() async throws {
        let space = try Workspace()
        let source = space.url("colors.pdf")
        var page = AuditPage.titled("Colorful page")
        page.texts.append(AuditText(text: "Red words", x: 60, y: 620, size: 30, color: .red))
        page.marks = [
            AuditMark(rect: CGRect(x: 60, y: 520, width: 120, height: 60), color: .blue),
            AuditMark(rect: CGRect(x: 200, y: 520, width: 120, height: 60), color: .green),
        ]
        page.images = [
            AuditImage(kind: .jpeg, rect: CGRect(x: 60, y: 200, width: 240, height: 180)),
            AuditImage(kind: .alphaPNG, rect: CGRect(x: 320, y: 200, width: 200, height: 200)),
        ]
        var turned = page
        turned.rotation = 90
        try AuditPDF.write([page, turned], to: source) { document in
            let first = try requireFixture(document.page(at: 0))
            let highlight = PDFAnnotation(
                bounds: CGRect(x: 60, y: 610, width: 200, height: 40), forType: .highlight,
                withProperties: nil)
            highlight.color = NSColor.yellow.withAlphaComponent(0.6)
            first.addAnnotation(highlight)
            let square = PDFAnnotation(
                bounds: CGRect(x: 350, y: 60, width: 150, height: 80), forType: .square,
                withProperties: nil)
            square.color = .red
            square.interiorColor = .blue
            first.addAnnotation(square)
        }
        let before = try AuditInk.render(try #require(PDFDocument(url: source)?.page(at: 0)))
        #expect(AuditInk.coloredPixels(before) > 1000)
        let result = try await space.audited("pdf.grayscale", [source])
        let document = try result.document()
        for index in 0..<document.pageCount {
            let image = try AuditInk.render(try #require(document.page(at: index)))
            #expect(AuditInk.coloredPixels(image) == 0, "page \(index + 1) still has color")
        }
        #expect(document.page(at: 0)?.string?.contains("Red words") == true)
        #expect(document.page(at: 1)?.rotation == 90)
    }

    func scanned(_ geometry: AuditGeometry) -> AuditPage {
        geometry.page { page in
            let size = page.layoutSize
            page.images = [
                AuditImage(
                    kind: .scan("INVOICE 4821\n\nTOTAL DUE FRIDAY"),
                    rect: CGRect(x: 40, y: size.height - 340, width: 500, height: 300))
            ]
        }
    }

    @Test(arguments: AuditGeometry.all)
    func ocrTextLayerSitsOnTheInkOnEveryGeometry(_ geometry: AuditGeometry) async throws {
        let space = try Workspace()
        let source = space.url("scan.pdf")
        try AuditPDF.write([scanned(geometry)], to: source)
        #expect(AuditPDF.texts(source) == [""])
        let result = try await space.audited("pdf.ocr", [source])
        let document = try result.document()
        let page = try #require(document.page(at: 0))
        #expect(StudioPDF.rotation(page) == geometry.rotation)
        let image = try AuditInk.render(page)
        let size = StudioPDF.displaySize(page)
        let toDisplay = StudioPDF.displayFromPage(page)
        var previous: CGRect?
        for word in ["INVOICE", "TOTAL"] {
            let found = try #require(document.findString(word, withOptions: []).first)
            let display = found.bounds(for: page).applying(toDisplay).standardized
            #expect(display.width > display.height, "\(word) is not horizontal on screen")
            let pixels = AuditInk.pixelRect(display, size: size, image: image)
            let ink = try #require(AuditInk.box(image, in: pixels.insetBy(dx: -4, dy: -4)))
            let overlap = ink.intersection(pixels)
            #expect(overlap.width * overlap.height > ink.width * ink.height * 0.6)
            #expect(AuditInk.darkShare(image, in: pixels) > 0.08)
            if let previous { #expect(display.maxY < previous.minY) }
            previous = display
        }
    }

    @Test func repairRecoversTruncatedFilesAndRejectsHopelessOnes() async throws {
        let space = try Workspace()
        let source = space.url("good.pdf")
        try AuditPDF.write([.titled("Recovered title"), .titled("Second page")], to: source)
        var data = try Data(contentsOf: source)
        let marker = try #require(data.range(of: Data("xref".utf8), options: .backwards))
        data.removeSubrange(marker.lowerBound..<data.endIndex)
        let truncated = space.url("truncated.pdf")
        try data.write(to: truncated)
        let result = try await space.audited(
            "pdf.repair", [truncated], environment: space.withoutEngines)
        #expect(AuditPDF.texts(try result.url()) == ["Recovered title", "Second page"])
        let hopeless = space.url("hopeless.pdf")
        try Data("%PDF-1.4\nnothing useful here".utf8).write(to: hopeless)
        await #expect(throws: StudioError.self) {
            try await space.audited("pdf.repair", [hopeless], environment: space.withoutEngines)
        }
    }

    @Test func flattenBurnsFormValuesAndAnnotationsButKeepsLinks() async throws {
        let space = try Workspace()
        let source = space.url("form.pdf")
        var form = AuditPage.titled("Application form")
        form.link("Application", page: 1)
        try AuditPDF.write([form, .titled("Second page", rotation: 90)], to: source) { document in
            let page = try requireFixture(document.page(at: 0))
            let field = PDFAnnotation(
                bounds: CGRect(x: 60, y: 500, width: 260, height: 28), forType: .widget,
                withProperties: nil)
            field.widgetFieldType = .text
            field.fieldName = "Name"
            field.font = NSFont.systemFont(ofSize: 16)
            field.widgetStringValue = "Grace Hopper"
            page.addAnnotation(field)
            let turned = try requireFixture(document.page(at: 1))
            let square = PDFAnnotation(
                bounds: CGRect(x: 400, y: 100, width: 100, height: 100), forType: .square,
                withProperties: nil)
            square.color = .blue
            square.interiorColor = .blue
            turned.addAnnotation(square)
        }
        let original = try #require(PDFDocument(url: source))
        let turnedBefore = try AuditInk.render(try #require(original.page(at: 1)))
        let result = try await space.audited("pdf.flatten", [source])
        let document = try result.document()
        let page = try #require(document.page(at: 0))
        #expect(page.annotations.contains { $0.type == "Widget" } == false)
        #expect(page.string?.contains("Grace Hopper") == true)
        #expect(AuditPDF.linkTargets(document, page: 0) == [1])
        let turnedAfter = try AuditInk.render(try #require(document.page(at: 1)))
        #expect(document.page(at: 1)?.annotations.isEmpty == true)
        #expect(
            AuditInk.near(
                AuditInk.coloredBox(turnedAfter), AuditInk.coloredBox(turnedBefore), tolerance: 2))
    }

    @Test(arguments: ["pdf.decompress", "pdf.linearize"])
    func qpdfToolsFailCleanlyWithoutTheEngine(_ id: String) async throws {
        let space = try Workspace()
        let source = space.url("plain.pdf")
        try AuditPDF.write([.titled("Plain")], to: source)
        await #expect(throws: StudioError.needsEngine(.qpdf)) {
            try await space.audited(id, [source], environment: space.withoutEngines)
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: space.output.path)
        #expect(files.isEmpty)
    }
}
