import AppKit
import CoreGraphics
import Foundation
import PDFKit
import Testing

@testable import EdithStudio

@Suite struct PDFRasterizerTests {
    func legacyFont() throws -> URL {
        try #require(
            Bundle.module.url(
                forResource: "legacy-type1", withExtension: "pdf", subdirectory: "Fixtures"))
    }

    func expectTriangle(_ image: CGImage, scale: CGFloat = 1) throws {
        let ink = try #require(PageInk.box(image, below: 128))
        #expect(abs(ink.minX - 40 * scale) <= 2)
        #expect(abs(ink.minY - 60 * scale) <= 2)
        #expect(abs(ink.width - 60 * scale) <= 2)
        #expect(abs(ink.height - 70 * scale) <= 2)
        #expect(
            PageInk.darkShare(
                image,
                in: CGRect(x: 65 * scale, y: 85 * scale, width: 10 * scale, height: 10 * scale))
                > 0.95)
        #expect(
            PageInk.darkShare(
                image,
                in: CGRect(x: 40 * scale, y: 60 * scale, width: 10 * scale, height: 10 * scale))
                < 0.05)
    }

    @Test func embeddedTypeOneGlyphsRenderFromTheOriginalBytes() async throws {
        let space = try Workspace()
        let result = try await space.audited(
            "pdf.to-images", [legacyFont()], ["format": .text("png"), "dpi": .text("72")])
        let image = try StudioImageIO.load(try result.url())
        #expect(image.width == 240 && image.height == 160)
        try expectTriangle(image)
    }

    @Test func imageOnlyWorkflowPreservesEmbeddedGlyphsAndPageSize() async throws {
        let space = try Workspace()
        let workflow = StudioWorkflow(
            name: "Image-only PDF",
            steps: [
                .init(
                    toolID: "pdf.to-images",
                    settings: StudioSettings(["format": .text("png"), "dpi": .text("300")])),
                .init(
                    toolID: "pdf.from-images",
                    settings: StudioSettings(["paper": .text("fit"), "margin": .text("0")])),
            ])
        let result = try await StudioRunner.run(
            tool: #require(workflow.tool), inputs: [legacyFont()], settings: StudioSettings(),
            destination: .folder(space.output), environment: space.environment)
        #expect(result.failures.isEmpty)
        let document = try result.document()
        #expect(document.pageCount == 1)
        #expect(document.string?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false)
        let page = try #require(document.page(at: 0))
        let size = StudioPDF.displaySize(page)
        #expect(abs(size.width - 240) < 0.25 && abs(size.height - 160) < 0.25)
        try expectTriangle(StudioPDF.render(page, dpi: 72))
    }

    @Test func cappedResolutionKeepsPhysicalPageSize() throws {
        let renderer = try StudioPDFRasterizer(legacyFont())
        let rendered = try renderer.render(0, dpi: 300, maxPixels: 38_400)
        #expect(rendered.image.width == 240 && rendered.image.height == 160)
        #expect(abs(rendered.dpi - 72) < 0.01)
        try expectTriangle(rendered.image)
    }

    @Test func unlockedDocumentsKeepVisibleAnnotationsAndFormValues() async throws {
        let space = try Workspace()
        let source = space.url("annotated.pdf")
        try Fixtures.pdf(at: source, pages: [""], size: CGSize(width: 240, height: 160))
        let document = try #require(PDFDocument(url: source))
        let page = try #require(document.page(at: 0))
        let square = PDFAnnotation(
            bounds: CGRect(x: 20, y: 20, width: 40, height: 40), forType: .square,
            withProperties: nil)
        square.color = .red
        square.interiorColor = .red
        page.addAnnotation(square)
        let field = PDFAnnotation(
            bounds: CGRect(x: 90, y: 80, width: 120, height: 40), forType: .widget,
            withProperties: nil)
        field.widgetFieldType = .text
        field.fieldName = "sample"
        field.widgetStringValue = "SAMPLE"
        field.font = .systemFont(ofSize: 20)
        field.fontColor = .black
        page.addAnnotation(field)
        try StudioPDF.write(document, to: source)
        let encrypted = space.url("locked.pdf")
        try AuditPDF.encrypt(source, to: encrypted, user: "right", owner: "owner")
        let result = try await space.audited(
            "pdf.to-images", [encrypted],
            ["password": .text("right"), "format": .text("png"), "dpi": .text("72")])
        let image = try StudioImageIO.load(try result.url())
        let red = Fixtures.pixel(image, x: 40, y: 120)
        #expect(red.r > 240 && red.g < 20 && red.b < 20)
        #expect(PageInk.darkShare(image, in: CGRect(x: 90, y: 40, width: 120, height: 40)) > 0.03)
    }
}
