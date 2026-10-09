import AppKit
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import PDFKit
import Testing
import UniformTypeIdentifiers

@testable import EdithStudio

struct AuditColor: Sendable, Equatable {
    var red: CGFloat
    var green: CGFloat
    var blue: CGFloat

    static let black = AuditColor(red: 0, green: 0, blue: 0)
    static let red = AuditColor(red: 0.9, green: 0.05, blue: 0.05)
    static let green = AuditColor(red: 0.05, green: 0.7, blue: 0.1)
    static let blue = AuditColor(red: 0.05, green: 0.15, blue: 0.95)

    var cgColor: CGColor { CGColor(srgbRed: red, green: green, blue: blue, alpha: 1) }
}

struct AuditText: Sendable {
    var text: String
    var x: CGFloat
    var y: CGFloat
    var size: CGFloat = 14
    var font = "Helvetica"
    var color = AuditColor.black
    var unitFont = false
}

struct AuditMark: Sendable {
    var rect: CGRect
    var color = AuditColor.black
}

enum AuditImageKind: Sendable {
    case jpeg
    case photo
    case alphaPNG
    case scan(String)
}

struct AuditImage: Sendable {
    var kind: AuditImageKind
    var rect: CGRect
}

struct AuditLink: Sendable {
    var rect: CGRect
    var page: Int?
    var url: String?
}

struct AuditPage: Sendable {
    var media = CGRect(x: 0, y: 0, width: 612, height: 792)
    var crop: CGRect?
    var rotation = 0
    var upright = true
    var texts: [AuditText] = []
    var marks: [AuditMark] = []
    var images: [AuditImage] = []
    var links: [AuditLink] = []

    var toPage: CGAffineTransform {
        let shift = CGAffineTransform(translationX: box.minX, y: box.minY)
        guard upright else { return shift }
        return StudioPDF.pageFromDisplay(size: box.size, rotation: rotation).concatenating(shift)
    }

    func rect(of text: String) -> CGRect? {
        guard let item = texts.first(where: { $0.text.contains(text) }) else { return nil }
        let font = CTFontCreateWithName(item.font as CFString, item.size, nil)
        let prefix = String(item.text[..<item.text.range(of: text)!.lowerBound])
        func width(_ value: String) -> CGFloat {
            let line = CTLineCreateWithAttributedString(
                NSAttributedString(string: value, attributes: [.font: font]))
            return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        }
        return CGRect(
            x: item.x + width(prefix), y: item.y - CTFontGetDescent(font), width: width(text),
            height: CTFontGetAscent(font) + CTFontGetDescent(font))
    }

    mutating func link(_ text: String, page target: Int? = nil, url: String? = nil) {
        guard let rect = rect(of: text) else { return }
        links.append(AuditLink(rect: rect, page: target, url: url))
    }

    var box: CGRect { crop ?? media }

    var displaySize: CGSize {
        rotation % 180 == 0 ? box.size : CGSize(width: box.height, height: box.width)
    }

    var layoutSize: CGSize { upright ? displaySize : box.size }

    static let letter = CGRect(x: 0, y: 0, width: 612, height: 792)
    static let a4Landscape = CGRect(x: 0, y: 0, width: 841.89, height: 595.28)
    static let businessCard = CGRect(x: 0, y: 0, width: 252, height: 144)
    static let a0 = CGRect(x: 0, y: 0, width: 2383.94, height: 3370.39)

    static func titled(
        _ title: String, media: CGRect = letter, crop: CGRect? = nil, rotation: Int = 0,
        upright: Bool = true, size: CGFloat = 28
    ) -> AuditPage {
        var page = AuditPage(media: media, crop: crop, rotation: rotation, upright: upright)
        let height = page.layoutSize.height
        page.texts = [AuditText(text: title, x: 60, y: height - 110, size: size)]
        return page
    }

    static func cornered(
        _ label: String, media: CGRect = letter, crop: CGRect? = nil, rotation: Int = 0
    ) -> AuditPage {
        var page = titled(label, media: media, crop: crop, rotation: rotation)
        let size = page.layoutSize
        page.marks = [AuditMark(rect: CGRect(x: 0, y: size.height - 60, width: 60, height: 60))]
        return page
    }
}

struct AuditGeometry: Sendable, CustomTestStringConvertible {
    let name: String
    let media: CGRect
    let crop: CGRect?
    let rotation: Int

    var testDescription: String { name }

    func page(_ build: (inout AuditPage) -> Void = { _ in }) -> AuditPage {
        var page = AuditPage(media: media, crop: crop, rotation: rotation)
        build(&page)
        return page
    }

    static let all: [AuditGeometry] = [
        AuditGeometry(name: "plain", media: AuditPage.letter, crop: nil, rotation: 0),
        AuditGeometry(
            name: "media shifted positive", media: CGRect(x: 40, y: 70, width: 612, height: 792),
            crop: nil, rotation: 0),
        AuditGeometry(
            name: "media shifted negative",
            media: CGRect(x: -306, y: -396, width: 612, height: 792), crop: nil, rotation: 0),
        AuditGeometry(
            name: "crop inside media", media: AuditPage.letter,
            crop: CGRect(x: 30, y: 50, width: 540, height: 680), rotation: 0),
        AuditGeometry(name: "rotated 90", media: AuditPage.letter, crop: nil, rotation: 90),
        AuditGeometry(
            name: "rotated 180 shifted", media: CGRect(x: 20, y: 60, width: 612, height: 792),
            crop: nil, rotation: 180),
        AuditGeometry(
            name: "rotated 270 cropped", media: AuditPage.letter,
            crop: CGRect(x: 12, y: 24, width: 580, height: 740), rotation: 270),
    ]
}

enum AuditPDF {
    static func write(
        _ pages: [AuditPage], to url: URL, info: [CFString: Any] = [:], xmp: String? = nil,
        outline: [(String, Int)] = [], finish: ((PDFDocument) throws -> Void)? = nil
    ) throws {
        guard let context = CGContext(url as CFURL, mediaBox: nil, info as CFDictionary) else {
            throw StudioError.failed("fixture")
        }
        if let xmp { context.addDocumentMetadata(Data(xmp.utf8) as CFData) }
        for (index, page) in pages.enumerated() {
            var boxes: [CFString: Any] = [kCGPDFContextMediaBox: data(page.media)]
            if let crop = page.crop { boxes[kCGPDFContextCropBox] = data(crop) }
            context.beginPDFPage(boxes as CFDictionary)
            let top = CGPoint(x: 0, y: page.layoutSize.height).applying(page.toPage)
            context.addDestination("audit-page-\(index)" as CFString, at: top)
            for link in page.links {
                let rect = link.rect.applying(page.toPage).standardized
                if let target = link.page {
                    context.setDestination("audit-page-\(target)" as CFString, for: rect)
                } else if let address = link.url, let target = URL(string: address) {
                    context.setURL(target as CFURL, for: rect)
                }
            }
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(page.media)
            context.saveGState()
            context.translateBy(x: page.box.minX, y: page.box.minY)
            if page.upright {
                context.concatenate(
                    StudioPDF.pageFromDisplay(size: page.box.size, rotation: page.rotation))
            }
            draw(page, in: context)
            context.restoreGState()
            context.endPDFPage()
        }
        if !outline.isEmpty {
            let children = outline.map { entry -> [CFString: Any] in
                [
                    kCGPDFOutlineTitle: entry.0,
                    kCGPDFOutlineDestination: NSNumber(value: entry.1 + 1),
                ]
            }
            CGPDFContextSetOutline(context, [kCGPDFOutlineChildren: children] as CFDictionary)
        }
        context.closePDF()
        guard finish != nil || pages.contains(where: { $0.rotation != 0 }) else { return }
        let document = try requireFixture(PDFDocument(url: url))
        for (index, page) in pages.enumerated() {
            document.page(at: index)?.rotation = page.rotation
        }
        try finish?(document)
        try save(document, over: url)
    }

    static func save(
        _ document: PDFDocument, over url: URL, options: [PDFDocumentWriteOption: Any] = [:]
    )
        throws
    {
        let staged = url.deletingLastPathComponent().appendingPathComponent(
            ".\(UUID().uuidString).pdf")
        let written =
            options.isEmpty
            ? document.write(to: staged) : document.write(to: staged, withOptions: options)
        guard written else { throw StudioError.failed("fixture write") }
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: staged)
        } else {
            try FileManager.default.moveItem(at: staged, to: url)
        }
    }

    static func data(_ rect: CGRect) -> Data {
        var value = rect
        return Data(bytes: &value, count: MemoryLayout<CGRect>.size)
    }

    static func draw(_ page: AuditPage, in context: CGContext) {
        for image in page.images {
            switch image.kind {
            case .jpeg:
                context.draw(jpeg(width: 480, height: 360), in: image.rect)
            case .photo:
                context.draw(jpeg(width: 1400, height: 1050, quality: 0.95), in: image.rect)
            case .alphaPNG:
                context.draw(alphaImage(width: 400, height: 400), in: image.rect)
            case .scan(let text):
                context.draw(scan(text, size: image.rect.size), in: image.rect)
            }
        }
        for mark in page.marks {
            context.setFillColor(mark.color.cgColor)
            context.fill(mark.rect)
        }
        for text in page.texts {
            context.saveGState()
            let fontSize = text.unitFont ? 1 : text.size
            let font = CTFontCreateWithName(text.font as CFString, fontSize, nil)
            let line = CTLineCreateWithAttributedString(
                NSAttributedString(
                    string: text.text,
                    attributes: [.font: font, .foregroundColor: text.color.cgColor]))
            context.textMatrix = .identity
            if text.unitFont {
                context.translateBy(x: text.x, y: text.y)
                context.scaleBy(x: text.size, y: text.size)
                context.textPosition = .zero
            } else {
                context.textPosition = CGPoint(x: text.x, y: text.y)
            }
            CTLineDraw(line, context)
            context.restoreGState()
        }
    }

    static func jpeg(width: Int, height: Int, quality: Double = 0.9) -> CGImage {
        let photo = Fixtures.photo(width: width, height: height, seed: 3)
        let data = (try? Fixtures.jpegData(photo, quality: quality)) ?? Data()
        let provider = CGDataProvider(data: data as CFData)!
        return CGImage(
            jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true,
            intent: .defaultIntent)!
    }

    static func alphaImage(width: Int, height: Int) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(srgbRed: 0.1, green: 0.8, blue: 0.2, alpha: 1))
        context.fillEllipse(
            in: CGRect(x: width / 4, y: height / 4, width: width / 2, height: height / 2))
        return context.makeImage()!
    }

    static func scan(_ text: String, size: CGSize, scale: CGFloat = 3) -> CGImage {
        let width = Int(size.width * scale)
        let height = Int(size.height * scale)
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(gray: 0.98, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        Fixtures.drawText(
            text,
            in: CGRect(
                x: 40 * scale, y: 40 * scale, width: CGFloat(width) - 80 * scale,
                height: CGFloat(height) - 80 * scale), size: 26 * scale, context: context)
        return context.makeImage()!
    }

    static func numbered(_ count: Int, at url: URL) throws {
        let pages = (1...count).map { index in
            AuditPage.titled(
                "Page \(index) marker", media: CGRect(x: 0, y: 0, width: 300, height: 400))
        }
        try write(pages, to: url)
    }

    static func texts(_ url: URL) -> [String] {
        guard let document = PDFDocument(url: url) else { return [] }
        return texts(document)
    }

    static func texts(_ document: PDFDocument) -> [String] {
        (0..<document.pageCount).map {
            document.page(at: $0)?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
    }

    static func linkTargets(_ document: PDFDocument, page index: Int) -> [Int] {
        guard let page = document.page(at: index) else { return [] }
        return page.annotations.filter { $0.type == "Link" }.compactMap { link in
            let destination =
                link.destination ?? (link.action as? PDFActionGoTo)?.destination
            guard let target = destination?.page else { return nil }
            let found = document.index(for: target)
            return found == NSNotFound ? nil : found
        }
    }

    static func linkURLs(_ document: PDFDocument, page index: Int) -> [String] {
        guard let page = document.page(at: index) else { return [] }
        return page.annotations.filter { $0.type == "Link" }.compactMap {
            ($0.url ?? ($0.action as? PDFActionURL)?.url)?.absoluteString
        }
    }

    static func outlineTargets(_ document: PDFDocument) -> [(String, Int)] {
        guard let root = document.outlineRoot else { return [] }
        var result: [(String, Int)] = []
        func walk(_ item: PDFOutline) {
            for index in 0..<item.numberOfChildren {
                guard let child = item.child(at: index) else { continue }
                var target = -1
                if let page = child.destination?.page {
                    let found = document.index(for: page)
                    target = found == NSNotFound ? -1 : found
                }
                result.append((child.label ?? "", target))
                walk(child)
            }
        }
        walk(root)
        return result
    }

    static func encrypt(
        _ url: URL, to output: URL, user: String?, owner: String,
        permissions: UInt = 0
    ) throws {
        let document = try requireFixture(PDFDocument(url: url))
        var options: [PDFDocumentWriteOption: Any] = [
            .ownerPasswordOption: owner,
            .accessPermissionsOption: NSNumber(value: permissions),
        ]
        if let user { options[.userPasswordOption] = user }
        guard document.write(to: output, withOptions: options) else {
            throw StudioError.failed("fixture encrypt")
        }
    }

    static func xmp(title: String, author: String) -> String {
        "<?xpacket begin=\"\u{FEFF}\" id=\"W5M0MpCehiHzreSzNTczkc9d\"?>"
            + "<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"><rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\">"
            + "<rdf:Description rdf:about=\"\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\">"
            + "<dc:title><rdf:Alt><rdf:li xml:lang=\"x-default\">\(title)</rdf:li></rdf:Alt></dc:title>"
            + "<dc:creator><rdf:Seq><rdf:li>\(author)</rdf:li></rdf:Seq></dc:creator>"
            + "</rdf:Description></rdf:RDF></x:xmpmeta><?xpacket end=\"w\"?>"
    }

    static func bytes(_ url: URL) -> Data {
        (try? Data(contentsOf: url)) ?? Data()
    }
}

enum AuditInk {
    static func render(_ page: PDFPage, dpi: Double = 72) throws -> CGImage {
        try StudioPDF.render(page, dpi: dpi)
    }

    static func pixelRect(_ display: CGRect, size: CGSize, image: CGImage) -> CGRect {
        let scaleX = CGFloat(image.width) / size.width
        let scaleY = CGFloat(image.height) / size.height
        return CGRect(
            x: display.minX * scaleX, y: (size.height - display.maxY) * scaleY,
            width: display.width * scaleX, height: display.height * scaleY)
    }

    static func displayRect(_ pixels: CGRect, size: CGSize, image: CGImage) -> CGRect {
        let scaleX = size.width / CGFloat(image.width)
        let scaleY = size.height / CGFloat(image.height)
        return CGRect(
            x: pixels.minX * scaleX, y: size.height - pixels.maxY * scaleY,
            width: pixels.width * scaleX, height: pixels.height * scaleY)
    }

    static func box(_ image: CGImage, in region: CGRect? = nil, below level: Int = 128) -> CGRect? {
        let (data, width, height) = PageInk.pixels(image)
        let area = (region ?? CGRect(x: 0, y: 0, width: width, height: height)).integral
            .intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard !area.isNull, area.width > 0, area.height > 0 else { return nil }
        var minX = Int.max
        var minY = Int.max
        var maxX = -1
        var maxY = -1
        for y in Int(area.minY)..<Int(area.maxY) {
            for x in Int(area.minX)..<Int(area.maxX) {
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

    static func coloredBox(_ image: CGImage, chroma: Int = 90) -> CGRect? {
        let (data, width, height) = PageInk.pixels(image)
        var minX = Int.max
        var minY = Int.max
        var maxX = -1
        var maxY = -1
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let channels = [Int(data[offset]), Int(data[offset + 1]), Int(data[offset + 2])]
                guard (channels.max() ?? 0) - (channels.min() ?? 0) > chroma else { continue }
                minX = min(minX, x)
                maxX = max(maxX, x)
                minY = min(minY, y)
                maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    static func coloredPixels(_ image: CGImage, chroma: Int = 24) -> Int {
        let (data, width, height) = PageInk.pixels(image)
        var count = 0
        for index in 0..<(width * height) {
            let offset = index * 4
            let channels = [Int(data[offset]), Int(data[offset + 1]), Int(data[offset + 2])]
            if (channels.max() ?? 0) - (channels.min() ?? 0) > chroma { count += 1 }
        }
        return count
    }

    static func darkShare(_ image: CGImage, in region: CGRect) -> Double {
        PageInk.darkShare(image, in: region)
    }

    static func near(_ a: CGRect?, _ b: CGRect?, tolerance: CGFloat) -> Bool {
        guard let a, let b else { return false }
        return abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
            && abs(a.maxX - b.maxX) <= tolerance && abs(a.maxY - b.maxY) <= tolerance
    }
}

extension Workspace {
    func audited(
        _ id: String, _ inputs: [URL], _ values: [String: StudioValue] = [:],
        environment: StudioEnvironment? = nil
    ) async throws -> StudioRunResult {
        let before = inputs.map(AuditPDF.bytes)
        defer {
            let after = inputs.map(AuditPDF.bytes)
            #expect(after == before, "\(id) changed its input files")
        }
        return try await run(id, inputs, values, environment: environment)
    }

    var withoutEngines: StudioEnvironment {
        var environment = self.environment
        environment.qpdf = nil
        return environment
    }
}
