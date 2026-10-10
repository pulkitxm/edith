import CoreGraphics
import CoreText
import Foundation
import PDFKit
import Testing

@testable import EdithStudio

struct PageGeometry: Sendable, CustomTestStringConvertible {
    let name: String
    let media: CGRect
    let crop: CGRect?
    let rotation: Int

    var testDescription: String { name }

    static let all: [PageGeometry] = [
        PageGeometry(
            name: "plain", media: CGRect(x: 0, y: 0, width: 612, height: 792), crop: nil,
            rotation: 0),
        PageGeometry(
            name: "media shifted up", media: CGRect(x: 0, y: 60, width: 612, height: 792),
            crop: nil, rotation: 0),
        PageGeometry(
            name: "media shifted both ways", media: CGRect(x: 30, y: 60, width: 612, height: 792),
            crop: nil, rotation: 0),
        PageGeometry(
            name: "negative media origin",
            media: CGRect(x: -306, y: -396, width: 612, height: 792), crop: nil, rotation: 0),
        PageGeometry(
            name: "crop inside media", media: CGRect(x: 0, y: 0, width: 612, height: 792),
            crop: CGRect(x: 20, y: 40, width: 560, height: 700), rotation: 0),
        PageGeometry(
            name: "rotated 90", media: CGRect(x: 0, y: 0, width: 612, height: 792), crop: nil,
            rotation: 90),
        PageGeometry(
            name: "rotated 180 and shifted", media: CGRect(x: 0, y: 60, width: 612, height: 792),
            crop: nil, rotation: 180),
        PageGeometry(
            name: "rotated 270 with crop", media: CGRect(x: 0, y: 0, width: 612, height: 792),
            crop: CGRect(x: 10, y: 20, width: 590, height: 750), rotation: 270),
    ]

    func write(to url: URL, headline: Bool = true, publicLine: Bool = true) throws {
        var box = media
        guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else {
            throw StudioError.failed("fixture")
        }
        context.beginPage(mediaBox: &box)
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(media)
        if headline {
            let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 36, nil)
            let line = CTLineCreateWithAttributedString(
                NSAttributedString(string: "SECRET NAME", attributes: [.font: font]))
            context.textPosition = CGPoint(x: media.minX + 120, y: media.minY + 560)
            CTLineDraw(line, context)
        }
        if publicLine {
            let small = CTFontCreateWithName("Helvetica" as CFString, 14, nil)
            let keep = CTLineCreateWithAttributedString(
                NSAttributedString(string: "Public line stays", attributes: [.font: small]))
            context.textPosition = CGPoint(x: media.minX + 120, y: media.minY + 420)
            CTLineDraw(keep, context)
        }
        context.endPage()
        context.closePDF()
        guard crop != nil || rotation != 0 else { return }
        let document = try requireFixture(PDFDocument(url: url))
        let page = try requireFixture(document.page(at: 0))
        if let crop { page.setBounds(crop, for: .cropBox) }
        page.rotation = rotation
        let staged = url.deletingLastPathComponent().appendingPathComponent(
            UUID().uuidString + ".pdf")
        guard document.write(to: staged) else { throw StudioError.failed("fixture write") }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: staged)
    }
}

enum PageInk {
    static func pixels(_ image: CGImage) -> (data: [UInt8], width: Int, height: Int) {
        let width = image.width
        let height = image.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        data.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return (data, width, height)
    }

    static func box(_ image: CGImage, below level: Int) -> CGRect? {
        let (data, width, height) = pixels(image)
        var minX = width
        var minY = height
        var maxX = -1
        var maxY = -1
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let value = (Int(data[offset]) + Int(data[offset + 1]) + Int(data[offset + 2])) / 3
                guard value < level else { continue }
                minX = min(minX, x)
                maxX = max(maxX, x)
                minY = min(minY, y)
                maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    static func darkShare(_ image: CGImage, in rect: CGRect) -> Double {
        let (data, width, height) = pixels(image)
        var dark = 0
        var total = 0
        for y in max(0, Int(rect.minY))..<min(height, Int(rect.maxY)) {
            for x in max(0, Int(rect.minX))..<min(width, Int(rect.maxX)) {
                let offset = (y * width + x) * 4
                let value = (Int(data[offset]) + Int(data[offset + 1]) + Int(data[offset + 2])) / 3
                total += 1
                if value < 30 { dark += 1 }
            }
        }
        return total == 0 ? 0 : Double(dark) / Double(total)
    }
}

@Suite struct PDFGeometryTests {
    @Test(arguments: PageGeometry.all)
    func renderIgnoresBoxOriginAndHonorsRotation(_ geometry: PageGeometry) throws {
        let space = try Workspace()
        let plainURL = space.url("plain.pdf")
        let rotatedPlain = PageGeometry(
            name: "reference", media: CGRect(origin: .zero, size: geometry.media.size),
            crop: geometry.crop.map {
                $0.offsetBy(dx: -geometry.media.minX, dy: -geometry.media.minY)
            }, rotation: geometry.rotation)
        try rotatedPlain.write(to: plainURL)
        let url = space.url("page.pdf")
        try geometry.write(to: url)
        let page = try requireFixture(PDFDocument(url: url)?.page(at: 0))
        let reference = try requireFixture(PDFDocument(url: plainURL)?.page(at: 0))
        let rendered = try StudioPDF.render(page, dpi: 72)
        let expected = try StudioPDF.render(reference, dpi: 72)
        #expect(rendered.width == expected.width && rendered.height == expected.height)
        let ink = try requireFixture(PageInk.box(rendered, below: 128))
        let expectedInk = try requireFixture(PageInk.box(expected, below: 128))
        #expect(abs(ink.minX - expectedInk.minX) <= 1 && abs(ink.minY - expectedInk.minY) <= 1)
        #expect(
            abs(ink.width - expectedInk.width) <= 2 && abs(ink.height - expectedInk.height) <= 2)
        let size = StudioPDF.displaySize(page)
        let portrait = geometry.rotation == 0 || geometry.rotation == 180
        #expect((size.height > size.width) == portrait)
        #expect((ink.height > ink.width) == !portrait)
    }

    @Test(arguments: PageGeometry.all)
    func redactionCoversTheFoundTextOnEveryPageGeometry(_ geometry: PageGeometry) async throws {
        let space = try Workspace()
        let url = space.url("page.pdf")
        try geometry.write(to: url)
        let headlineURL = space.url("headline.pdf")
        try geometry.write(to: headlineURL, publicLine: false)
        let publicURL = space.url("public.pdf")
        try geometry.write(to: publicURL, headline: false)
        let secret = try requireFixture(
            PageInk.box(
                try StudioPDF.render(
                    try requireFixture(PDFDocument(url: headlineURL)?.page(at: 0)), dpi: 72),
                below: 128))
        let visible = try requireFixture(
            PageInk.box(
                try StudioPDF.render(
                    try requireFixture(PDFDocument(url: publicURL)?.page(at: 0)), dpi: 72),
                below: 128))
        let document = try requireFixture(PDFDocument(url: url))
        let page = try requireFixture(document.page(at: 0))
        let marks = PDFRedaction.find(terms: ["SECRET NAME"], patterns: [], in: document)
        #expect(marks[0]?.count == 1)
        let output = space.url("redacted.pdf")
        try await PDFRedaction.apply(
            marks, to: document, fill: .black, searchable: true, scrubMetadata: false,
            output: output)
        let redacted = try requireFixture(PDFDocument(url: output))
        let redactedPage = try requireFixture(redacted.page(at: 0))
        let after = try StudioPDF.render(redactedPage, dpi: 72)
        #expect(PageInk.darkShare(after, in: secret) > 0.98)
        let publicShare = PageInk.darkShare(after, in: visible)
        #expect(publicShare > 0.03 && publicShare < 0.7)
        let text = redacted.string ?? ""
        #expect(!text.localizedCaseInsensitiveContains("SECRET"))
        #expect(text.contains("Public"))
        #expect(StudioPDF.displaySize(redactedPage) == StudioPDF.displaySize(page))
    }

    @Test func redactionKeepsOnlyLinksOutsideTheBoxes() async throws {
        let space = try Workspace()
        let url = space.url("links.pdf")
        let geometry = PageGeometry.all[1]
        try geometry.write(to: url)
        let document = try requireFixture(PDFDocument(url: url))
        let page = try requireFixture(document.page(at: 0))
        let marks = PDFRedaction.find(terms: ["SECRET NAME"], patterns: [], in: document)
        let secret = try requireFixture(marks[0]?.first)
        let hidden = PDFAnnotation(bounds: secret, forType: .link, withProperties: nil)
        hidden.url = URL(string: "mailto:secret@example.com")
        page.addAnnotation(hidden)
        let publicBounds = try requireFixture(
            document.findString("Public line stays", withOptions: []).first?.bounds(for: page))
        let visible = PDFAnnotation(bounds: publicBounds, forType: .link, withProperties: nil)
        visible.url = URL(string: "https://example.com/portfolio")
        page.addAnnotation(visible)
        let output = space.url("redacted.pdf")
        try await PDFRedaction.apply(
            marks, to: document, fill: .black, searchable: false, scrubMetadata: false,
            output: output)
        let redacted = try requireFixture(PDFDocument(url: output)?.page(at: 0))
        let links = redacted.annotations.filter { $0.type == "Link" }
        #expect(links.count == 1)
        #expect(links.first?.url?.absoluteString == "https://example.com/portfolio")
        let crop = StudioPDF.cropBox(page)
        let expected = publicBounds.offsetBy(dx: -crop.minX, dy: -crop.minY)
        let bounds = try requireFixture(links.first?.bounds)
        #expect(abs(bounds.minX - expected.minX) < 1 && abs(bounds.minY - expected.minY) < 1)
    }
}
