import AppKit
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

@testable import EdithStudio

final class Workspace {
    let root: URL
    let output: URL

    static let parent = FileManager.default.temporaryDirectory.appendingPathComponent(
        "edith-studio-tests", isDirectory: true)

    static let sweep: Void = {
        let manager = FileManager.default
        let cutoff = Date().addingTimeInterval(-3600)
        let entries =
            (try? manager.contentsOfDirectory(
                at: parent, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for entry in entries {
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            if let modified, modified < cutoff { try? manager.removeItem(at: entry) }
        }
    }()

    init() throws {
        _ = Self.sweep
        root = Self.parent.appendingPathComponent(UUID().uuidString, isDirectory: true)
        output = root.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    }

    func url(_ name: String) -> URL {
        root.appendingPathComponent(name)
    }

    var environment: StudioEnvironment {
        var environment = StudioEnvironment.detect()
        environment.temporaryRoot = root.appendingPathComponent("staging", isDirectory: true)
        return environment
    }

    func run(
        _ id: String, _ inputs: [URL], _ values: [String: StudioValue] = [:],
        environment: StudioEnvironment? = nil
    ) async throws -> StudioRunResult {
        guard let tool = StudioCatalog.tool(id) else {
            throw StudioError.failed("missing tool \(id)")
        }
        return try await StudioRunner.run(
            tool: tool, inputs: inputs, settings: StudioSettings(values),
            destination: .folder(output), environment: environment ?? self.environment)
    }
}

enum Fixtures {
    static func pdf(
        at url: URL, pages: [String], size: CGSize = CGSize(width: 612, height: 792),
        rotation: Int = 0, fontSize: CGFloat = 14, title: String? = nil
    ) throws {
        var box = CGRect(origin: .zero, size: size)
        var info: [CFString: Any] = [:]
        if let title { info[kCGPDFContextTitle] = title }
        guard let context = CGContext(url as CFURL, mediaBox: &box, info as CFDictionary) else {
            throw StudioError.failed("fixture")
        }
        for text in pages {
            context.beginPage(mediaBox: &box)
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(box)
            drawText(text, in: box.insetBy(dx: 54, dy: 54), size: fontSize, context: context)
            context.endPage()
        }
        context.closePDF()
        if rotation != 0 {
            let document = try requireFixture(PDFDocument(url: url))
            for index in 0..<document.pageCount { document.page(at: index)?.rotation = rotation }
            document.write(to: url)
        }
    }

    static func drawText(_ text: String, in rect: CGRect, size: CGFloat, context: CGContext) {
        let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let attributed = NSAttributedString(
            string: text, attributes: [.font: font, .foregroundColor: CGColor(gray: 0, alpha: 1)])
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let frame = CTFramesetterCreateFrame(
            framesetter, CFRange(location: 0, length: 0), CGPath(rect: rect, transform: nil), nil)
        context.textMatrix = .identity
        CTFrameDraw(frame, context)
    }

    static func structuredPDF(at url: URL) throws {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else {
            throw StudioError.failed("fixture")
        }
        context.beginPage(mediaBox: &box)
        line("Quarterly Report", x: 54, y: 720, size: 28, bold: true, context: context)
        line(
            "Revenue grew across every region this quarter.", x: 54, y: 680, size: 12,
            context: context)
        line("Costs stayed flat while hiring continued.", x: 54, y: 664, size: 12, context: context)
        line("Highlights", x: 54, y: 620, size: 18, bold: true, context: context)
        line("• Launched two products", x: 54, y: 596, size: 12, context: context)
        line("• Opened the Berlin office", x: 54, y: 580, size: 12, context: context)
        let rows = [["Region", "Q1", "Q2"], ["North", "120", "140"], ["South", "95", "101"]]
        for (index, row) in rows.enumerated() {
            let y = 520 - CGFloat(index) * 20
            for (column, cell) in row.enumerated() {
                line(cell, x: 54 + CGFloat(column) * 150, y: y, size: 12, context: context)
            }
        }
        context.endPage()
        context.closePDF()
    }

    static func line(
        _ text: String, x: CGFloat, y: CGFloat, size: CGFloat, bold: Bool = false,
        context: CGContext
    ) {
        let font = CTFontCreateWithName(
            (bold ? "Helvetica-Bold" : "Helvetica") as CFString, size, nil)
        let attributed = NSAttributedString(
            string: text, attributes: [.font: font, .foregroundColor: CGColor(gray: 0, alpha: 1)])
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
    }

    static func photoPDF(at url: URL, pages: Int = 2, imageSize: Int = 1600) throws {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else {
            throw StudioError.failed("fixture")
        }
        for page in 0..<pages {
            let jpeg = try jpegData(
                photo(width: imageSize, height: imageSize * 3 / 4, seed: page), quality: 0.95)
            let provider = CGDataProvider(data: jpeg as CFData)!
            let image = CGImage(
                jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true,
                intent: .defaultIntent)!
            context.beginPage(mediaBox: &box)
            context.draw(image, in: CGRect(x: 36, y: 300, width: 540, height: 405))
            drawText(
                "Photo page \(page + 1)", in: CGRect(x: 54, y: 100, width: 500, height: 100),
                size: 18, context: context)
            context.endPage()
        }
        context.closePDF()
    }

    static func photo(width: Int, height: Int, seed: Int = 0) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let data = context.data!.bindMemory(to: UInt8.self, capacity: context.bytesPerRow * height)
        var state = UInt32(truncatingIfNeeded: 2_654_435_761 &* UInt32(seed + 1))
        for row in 0..<height {
            for column in 0..<width {
                state = state &* 1_664_525 &+ 1_013_904_223
                let noise = Int(state >> 27)
                let offset = row * context.bytesPerRow + column * 4
                data[offset] = UInt8(clamping: column * 255 / width + noise)
                data[offset + 1] = UInt8(clamping: row * 255 / height + noise)
                data[offset + 2] = UInt8(clamping: 128 + (column - row) % 64 + noise)
                data[offset + 3] = 255
            }
        }
        return context.makeImage()!
    }

    static func jpegData(_ image: CGImage, quality: Double) throws -> Data {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(
            data, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(
            destination, image,
            [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw StudioError.failed("jpeg") }
        return data as Data
    }

    static func image(
        at url: URL, width: Int = 400, height: Int = 300, format: StudioImageFormat = .png,
        alpha: Bool = false, orientation: Int? = nil
    ) throws {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: alpha
                ? CGImageAlphaInfo.premultipliedLast.rawValue
                : CGImageAlphaInfo.noneSkipLast.rawValue)!
        if alpha {
            context.clear(CGRect(x: 0, y: 0, width: width, height: height))
            context.setFillColor(CGColor(srgbRed: 0.1, green: 0.4, blue: 0.9, alpha: 1))
            context.fillEllipse(
                in: CGRect(x: width / 4, y: height / 4, width: width / 2, height: height / 2))
        } else {
            context.setFillColor(CGColor(srgbRed: 0.95, green: 0.9, blue: 0.8, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.setFillColor(CGColor(srgbRed: 0.8, green: 0.1, blue: 0.1, alpha: 1))
            context.fill(CGRect(x: 0, y: height / 2, width: width / 2, height: height / 2))
            context.setFillColor(CGColor(srgbRed: 0.1, green: 0.6, blue: 0.2, alpha: 1))
            context.fill(CGRect(x: width / 2, y: 0, width: width / 2, height: height / 2))
        }
        let image = context.makeImage()!
        let destination = CGImageDestinationCreateWithURL(
            url as CFURL, format.utType.identifier as CFString, 1, nil)!
        var properties: [CFString: Any] = [:]
        if let orientation { properties[kCGImagePropertyOrientation] = orientation }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw StudioError.failed("image") }
    }

    static func pixel(_ image: CGImage, x: Int, y: Int) -> (r: Int, g: Int, b: Int, a: Int) {
        let context = CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let data = context.data!.bindMemory(
            to: UInt8.self, capacity: image.width * image.height * 4)
        let offset = y * image.width * 4 + x * 4
        return (
            Int(data[offset]), Int(data[offset + 1]), Int(data[offset + 2]), Int(data[offset + 3])
        )
    }

    static func text(of url: URL) -> String {
        guard let document = PDFDocument(url: url) else { return "" }
        return (0..<document.pageCount).compactMap { document.page(at: $0)?.string }.joined(
            separator: "\n")
    }
}

func requireFixture<T>(_ value: T?) throws -> T {
    guard let value else { throw StudioError.failed("fixture value missing") }
    return value
}

extension StudioRunResult {
    func document(_ index: Int = 0) throws -> PDFDocument {
        guard index < outputs.count, let document = PDFDocument(url: outputs[index].url) else {
            throw StudioError.failed("output \(index) is not a readable PDF")
        }
        return document
    }

    func url(_ index: Int = 0) throws -> URL {
        guard index < outputs.count else { throw StudioError.failed("missing output \(index)") }
        return outputs[index].url
    }
}
