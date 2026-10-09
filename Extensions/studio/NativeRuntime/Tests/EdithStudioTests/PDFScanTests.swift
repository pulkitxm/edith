import CoreGraphics
import Foundation
import PDFKit
import Testing

@testable import EdithStudio

@Suite struct PDFScanTests {
    static func paper() -> CGImage {
        let width = 760
        let height = 1000
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(gray: 0.97, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        Fixtures.drawText(
            "RECEIPT 4821\n\nCoffee beans 12.50\nOat milk 4.25\n\nTotal 16.75",
            in: CGRect(x: 70, y: 120, width: 620, height: 800), size: 56, context: context)
        return context.makeImage()!
    }

    static func photo(of paper: CGImage?, angle: CGFloat = 0.07) -> CGImage {
        let width = 1800
        let height = 1500
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(srgbRed: 0.24, green: 0.17, blue: 0.12, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if let paper {
            context.translateBy(x: CGFloat(width) / 2, y: CGFloat(height) / 2)
            context.rotate(by: angle)
            context.draw(
                paper,
                in: CGRect(
                    x: -CGFloat(paper.width) / 2, y: -CGFloat(paper.height) / 2,
                    width: CGFloat(paper.width), height: CGFloat(paper.height)))
        }
        return context.makeImage()!
    }

    @Test func findsThePageStraightensItAndMakesItSearchable() async throws {
        let space = try Workspace()
        let photo = space.url("receipt.jpg")
        try StudioImageIO.write(
            Self.photo(of: Self.paper()), to: photo, format: .jpeg, options: .init(quality: 0.9))
        let result = try await space.run("pdf.scan", [photo], ["paper": .text("fit")])
        #expect(result.failures.isEmpty)
        let document = try result.document()
        #expect(document.pageCount == 1)
        let page = try #require(document.page(at: 0))
        let size = StudioPDF.displaySize(page)
        #expect(abs(size.width / size.height - 0.76) < 0.06)
        let rendered = try StudioPDF.render(page, dpi: 72)
        let insetX = max(2, rendered.width / 30)
        let insetY = max(2, rendered.height / 30)
        for (x, y) in [
            (insetX, insetY), (rendered.width - insetX, insetY),
            (insetX, rendered.height - insetY), (rendered.width - insetX, rendered.height - insetY),
        ] {
            let pixel = Fixtures.pixel(rendered, x: x, y: y)
            #expect(pixel.r > 180 && pixel.g > 180 && pixel.b > 180)
        }
        let text = Fixtures.text(of: try result.url())
        #expect(text.contains("4821"))
        #expect(text.contains("Total"))
        #expect(result.notes.contains { $0.contains("No page edges") } == false)
    }

    @Test func keepsPhotosWholeWhenNoPageIsFound() async throws {
        let space = try Workspace()
        var inputs: [URL] = []
        for index in 0..<2 {
            let url = space.url("wall-\(index).png")
            try StudioImageIO.write(Self.photo(of: nil), to: url, format: .png)
            inputs.append(url)
        }
        let result = try await space.run(
            "pdf.scan", inputs, ["ocr": .bool(false), "look": .text("gray")])
        let document = try result.document()
        #expect(document.pageCount == 2)
        let size = StudioPDF.displaySize(try #require(document.page(at: 0)))
        #expect(abs(size.width - StudioPaperSize.a4.points.height) < 1)
        #expect(result.notes.contains { $0.contains("No page edges were found in 2 photos") })
    }

    @Test func blackAndWhiteLookLeavesOnlyInkAndPaper() throws {
        let image = try #require(DocumentScan.enhance(Self.paper(), look: "mono"))
        var levels = Set<Int>()
        for (x, y) in [(10, 10), (380, 500), (700, 950), (100, 880), (375, 20)] {
            levels.insert(Fixtures.pixel(image, x: x, y: y).r)
        }
        #expect(levels.isSubset(of: [0, 255]))
    }

    @Test func straighteningReturnsNothingForABlankWall() async throws {
        let straightened = try await DocumentScan.straighten(Self.photo(of: nil))
        #expect(straightened == nil)
    }
}
