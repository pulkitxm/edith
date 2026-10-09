import AppKit
import Foundation
import PDFKit
import Testing

@testable import EdithStudio

@Suite struct PDFAuditEditTests {
    func blank(_ space: Workspace, _ geometry: AuditGeometry, pages: Int = 1) throws -> URL {
        let url = space.url("blank.pdf")
        try AuditPDF.write(Array(repeating: geometry.page(), count: pages), to: url)
        return url
    }

    func corner(_ image: CGImage, _ ink: CGRect, _ position: String) -> Bool {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let left = ink.minX < width * 0.2 && ink.maxX < width * 0.5
        let right = ink.maxX > width * 0.8 && ink.minX > width * 0.5
        let top = ink.minY < height * 0.15 && ink.maxY < height * 0.3
        let bottom = ink.maxY > height * 0.85 && ink.minY > height * 0.7
        switch position {
        case "top-left": return top && left
        case "top-right": return top && right
        case "bottom-left": return bottom && left
        default: return bottom && right
        }
    }

    @Test(arguments: AuditGeometry.all)
    func watermarkAndPageNumbersLandAtTheirAnchor(_ geometry: AuditGeometry) async throws {
        let space = try Workspace()
        let source = try blank(space, geometry, pages: 2)
        for position in ["top-left", "bottom-right"] {
            let result = try await space.audited(
                "pdf.watermark", [source],
                [
                    "text": .text("MARK"), "position": .text(position), "color": .text("#000000"),
                    "opacity": .number(1), "rotation": .number(0), "size": .number(0.25),
                ])
            let document = try result.document()
            for index in 0..<2 {
                let page = try #require(document.page(at: index))
                #expect(StudioPDF.rotation(page) == geometry.rotation)
                let image = try AuditInk.render(page)
                let ink = try #require(AuditInk.box(image))
                #expect(corner(image, ink, position), "watermark \(position) page \(index + 1)")
            }
        }
        for position in ["top-right", "bottom-left"] {
            let result = try await space.audited(
                "pdf.page-numbers", [source],
                ["position": .text(position), "size": .number(18), "color": .text("#000000")])
            let document = try result.document()
            for index in 0..<2 {
                let page = try #require(document.page(at: index))
                let image = try AuditInk.render(page)
                let ink = try #require(AuditInk.box(image))
                #expect(corner(image, ink, position), "number \(position) page \(index + 1)")
                let edge = position.hasSuffix("left") ? ink.minX : CGFloat(image.width) - ink.maxX
                #expect(abs(edge - 28) < 6)
                #expect(page.string?.contains("\(index + 1)") == true)
            }
        }
    }

    @Test func metadataRoundTripsAndClearingRemovesEveryCopy() async throws {
        let space = try Workspace()
        let source = space.url("meta.pdf")
        try AuditPDF.write(
            [.titled("Body")], to: source,
            info: [kCGPDFContextTitle: "Old title", kCGPDFContextAuthor: "Secret Author"],
            xmp: AuditPDF.xmp(title: "Old title", author: "Secret Author"))
        let result = try await space.audited(
            "pdf.metadata", [source],
            [
                "title": .text("Zoë's Ångström report"), "author": .text("東京 Studio"),
                "subject": .text("Quarterly"), "keywords": .text("alpha, beta gamma"),
            ])
        let attributes = try result.document().documentAttributes ?? [:]
        #expect(
            attributes[PDFDocumentAttribute.titleAttribute] as? String == "Zoë's Ångström report")
        #expect(attributes[PDFDocumentAttribute.authorAttribute] as? String == "東京 Studio")
        #expect(attributes[PDFDocumentAttribute.subjectAttribute] as? String == "Quarterly")
        let keywords = attributes[PDFDocumentAttribute.keywordsAttribute]
        let list = (keywords as? [String]) ?? (keywords as? String).map { [$0] } ?? []
        #expect(list.joined(separator: ",").contains("beta gamma"))
        let edited = String(decoding: AuditPDF.bytes(try result.url()), as: UTF8.self)
        #expect(edited.contains("Secret Author") == false)
        let cleared = try await space.audited("pdf.metadata", [source], ["clear": .bool(true)])
        let raw = String(decoding: AuditPDF.bytes(try cleared.url()), as: UTF8.self)
        #expect(raw.contains("Secret Author") == false)
        #expect(raw.contains("Old title") == false)
        #expect(AuditPDF.texts(try cleared.url()) == ["Body"])
    }

    @Test func protectThenUnlockRoundTripsWithTheRightPermissions() async throws {
        let space = try Workspace()
        let source = space.url("doc.pdf")
        var first = AuditPage.titled("Private terms")
        first.link("Private", page: 1)
        try AuditPDF.write(
            [first, .titled("Second", rotation: 90)], to: source, outline: [("Second", 1)])
        let restricted = try await space.audited(
            "pdf.protect", [source],
            [
                "userPassword": .text("open me"), "ownerPassword": .text("owner"),
                "allowPrinting": .bool(true), "allowCopying": .bool(false),
            ])
        let locked = try #require(PDFDocument(url: try restricted.url()))
        #expect(locked.isLocked)
        #expect(locked.unlock(withPassword: "open me"))
        #expect(locked.allowsPrinting && !locked.allowsCopying && !locked.allowsCommenting)
        let open = try await space.audited(
            "pdf.protect", [source],
            ["userPassword": .text("x"), "allowCopying": .bool(true), "allowEditing": .bool(true)])
        let generous = try #require(PDFDocument(url: try open.url()))
        #expect(generous.unlock(withPassword: "x"))
        #expect(generous.allowsCopying && generous.allowsCommenting)
        let unlocked = try await space.audited(
            "pdf.unlock", [try restricted.url()], ["password": .text("open me")])
        let plain = try unlocked.document()
        #expect(!plain.isEncrypted && !plain.isLocked)
        #expect(AuditPDF.texts(plain) == ["Private terms", "Second"])
        #expect(plain.page(at: 1)?.rotation == 90)
        #expect(AuditPDF.linkTargets(plain, page: 0) == [1])
        #expect(AuditPDF.outlineTargets(plain).map(\.1) == [1])
        let ownerOnly = space.url("owner-only.pdf")
        try AuditPDF.encrypt(source, to: ownerOnly, user: nil, owner: "boss", permissions: 0)
        #expect(PDFDocument(url: ownerOnly)?.allowsCopying == false)
        let freed = try await space.audited("pdf.unlock", [ownerOnly])
        #expect(try freed.document().allowsCopying)
        await #expect(throws: StudioError.wrongPassword("doc-protected.pdf")) {
            try await space.audited("pdf.unlock", [try restricted.url()], ["password": .text("no")])
        }
    }

    @Test func compareReportsExactlyTheChangedLines() async throws {
        let space = try Workspace()
        let original = space.url("v1.pdf")
        let revised = space.url("v2.pdf")
        func page(_ lines: [String], media: CGRect = AuditPage.letter, rotation: Int = 0)
            -> AuditPage
        {
            var page = AuditPage(media: media, rotation: rotation)
            let top = page.layoutSize.height
            page.texts = lines.enumerated().map {
                AuditText(text: $1, x: 60, y: top - 80 - CGFloat($0) * 24)
            }
            return page
        }
        try AuditPDF.write(
            [
                page(["Clause one stays", "Clause two stays"]),
                page(["Payment within 30 days", "Governing law is Delaware"]),
                page(["Signature block"]),
            ], to: original)
        try AuditPDF.write(
            [
                page(
                    ["Clause one stays", "New clause about privacy", "Clause two stays"],
                    media: CGRect(x: 40, y: 70, width: 612, height: 792)),
                page(["Payment within 45 days", "Governing law is Delaware"], rotation: 90),
            ], to: revised)
        let report = PDFComparison.compare(
            try #require(PDFDocument(url: original)), try #require(PDFDocument(url: revised)))
        #expect(report.removed.map(\.text) == ["Payment within 30 days", "Signature block"])
        #expect(report.added.map(\.text) == ["New clause about privacy", "Payment within 45 days"])
        let result = try await space.audited("pdf.compare", [original, revised])
        let markdown = try String(contentsOf: try result.url(), encoding: .utf8)
        #expect(markdown.contains("+ p1: New clause about privacy"))
        #expect(markdown.contains("- p2: Payment within 30 days"))
        #expect(markdown.contains("+ p2: Payment within 45 days"))
        #expect(markdown.contains("- p3: Signature block"))
        #expect(markdown.contains("Clause one") == false)
        let same = space.url("same.pdf")
        try AuditPDF.write(
            [
                page(["Clause one stays", "Clause two stays"], rotation: 180),
                page(["Payment within 30 days", "Governing law is Delaware"]),
                page(["Signature block"], media: CGRect(x: -100, y: -100, width: 612, height: 792)),
            ], to: same)
        let identical = PDFComparison.compare(
            try #require(PDFDocument(url: original)), try #require(PDFDocument(url: same)))
        #expect(identical.isIdentical)
    }
}
