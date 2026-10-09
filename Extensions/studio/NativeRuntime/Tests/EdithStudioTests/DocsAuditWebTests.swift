import AppKit
import Foundation
import PDFKit
import Testing

@testable import EdithStudio

@Suite(.serialized) struct DocsAuditWebTests {
    typealias F = DocsAuditFixtures

    static func lines(_ count: Int, at url: URL, extra: String = "") throws {
        let body = (1...count).map {
            "<p style=\"margin:0;font:16px/20px Helvetica\">Line \(String(format: "%05d", $0)) of the page</p>"
        }.joined()
        try
            "<html><head><title>Lines</title></head><body style=\"margin:0\">\(extra)\(body)</body></html>"
            .write(to: url, atomically: true, encoding: .utf8)
    }

    static func expectEveryLineOnce(_ pages: [String], count: Int) {
        var seen: [Int: [Int]] = [:]
        let pattern = try! NSRegularExpression(pattern: "Line (\\d{5}) of")
        for (index, page) in pages.enumerated() {
            let text = page as NSString
            for match in pattern.matches(in: page, range: NSRange(location: 0, length: text.length))
            {
                if let number = Int(text.substring(with: match.range(at: 1))) {
                    seen[number, default: []].append(index)
                }
            }
        }
        let wrong = (1...count).filter { seen[$0]?.count != 1 }
        #expect(
            wrong.isEmpty,
            "lines missing or repeated: \(wrong.prefix(10)) \(wrong.prefix(3).map { seen[$0] ?? [] })"
        )
        let order = (1...count).compactMap { seen[$0]?.first }
        #expect(order == order.sorted())
    }

    @Test func pageBreaksNeverCutOrRepeatLines() {
        let boxes: [(CGFloat, CGFloat)] = (0..<100).map { index -> (CGFloat, CGFloat) in
            let top = CGFloat(index) * 20
            return (top + 2, top + 18)
        }
        let cuts = WebPDFLayout.breaks(height: 2000, slice: 450, avoiding: boxes)
        #expect(cuts.first == 0)
        #expect(cuts.last == 2000)
        for cut in cuts.dropFirst().dropLast() {
            let inside = boxes.contains { $0.0 < cut && $0.1 > cut }
            #expect(inside == false, "cut \(cut) splits a line")
        }
        for (top, bottom) in zip(cuts, cuts.dropFirst()) {
            #expect(bottom > top && bottom - top <= 450)
        }
        #expect(cuts == [0, 442, 882, 1322, 1762, 2000])
        let tall = WebPDFLayout.breaks(height: 3000, slice: 1000, avoiding: [(900, 2500)])
        #expect(tall == [0, 1000, 2000, 3000])
        let empty = WebPDFLayout.breaks(height: 100, slice: 1000, avoiding: [])
        #expect(empty == [0, 100])
    }

    @Test func veryLongPagesSplitIntoCleanA4AndLetterPages() async throws {
        let space = try Workspace()
        let html = space.url("ledger.html")
        try Self.lines(1600, at: html)
        let original = try Data(contentsOf: html)
        let a4 = try await space.run("web.html-to-pdf", [html])
        let document = try a4.document()
        #expect(document.pageCount >= 12)
        for index in 0..<document.pageCount {
            let size = try #require(document.page(at: index)?.bounds(for: .mediaBox).size)
            #expect(abs(size.width - 595.28) < 0.5 && abs(size.height - 841.89) < 0.5)
        }
        Self.expectEveryLineOnce(try F.pages(try a4.url()), count: 1600)
        #expect(a4.notes.contains { $0.contains("\(document.pageCount) pages") })

        let letter = try await space.run(
            "web.to-pdf", [], ["url": .text(html.path), "pages": .text("letter")])
        let letterDocument = try letter.document()
        #expect(
            letterDocument.page(at: 0)?.bounds(for: .mediaBox).size
                == CGSize(width: 612, height: 792))
        Self.expectEveryLineOnce(try F.pages(try letter.url()), count: 1600)

        let single = try await space.run(
            "web.to-pdf", [],
            ["url": .text(html.path), "pages": .text("single"), "width": .text("768")])
        let singleDocument = try single.document()
        #expect(singleDocument.pageCount == 3)
        for index in 0..<singleDocument.pageCount {
            let size = try #require(singleDocument.page(at: index)?.bounds(for: .mediaBox).size)
            #expect(size.width == 768 && size.height <= 14_400)
        }
        Self.expectEveryLineOnce(try F.pages(try single.url()), count: 1600)
        #expect(try Data(contentsOf: html) == original)
    }

    @Test func shortPagesKeepCSSImagesAndOnePage() async throws {
        let space = try Workspace()
        let html = space.url("card.html")
        try F.solidPNG(width: 200, height: 100, red: 1, green: 0, blue: 0).write(
            to: space.url("swatch.png"))
        try """
        <html><head><style>
        body { margin: 0; font-family: Helvetica; }
        .band { background: #0000ff; height: 80px; }
        img { display: block; width: 200px; height: 100px; }
        </style></head><body><div class="band"></div><img src="swatch.png"><p>Caption text</p></body></html>
        """.write(to: html, atomically: true, encoding: .utf8)
        let result = try await space.run("web.html-to-pdf", [html], ["width": .text("768")])
        let document = try result.document()
        #expect(document.pageCount == 1)
        let page = try #require(document.page(at: 0))
        let image = try StudioPDF.render(page, dpi: 72)
        #expect(F.redPixels(image) > 1500)
        let blue = F.coloredPixels(image) { r, g, b in b > 200 && r < 60 && g < 60 }
        #expect(blue > 5000)
        #expect(page.string?.contains("Caption text") == true)

        let shot = try await space.run(
            "web.to-image", [], ["url": .text(html.path), "width": .text("390")])
        let picture = try StudioImageIO.load(try shot.url())
        #expect(picture.width == 390)
        #expect(picture.height == 900)
        let band = Fixtures.pixel(picture, x: 200, y: 40)
        #expect(band.b > 200 && band.r < 60)
        let swatch = Fixtures.pixel(picture, x: 100, y: 130)
        #expect(swatch.r > 200 && swatch.g < 60)
    }

    @Test func screenshotsHaveExactSizesAndReportTruncation() async throws {
        let space = try Workspace()
        let html = space.url("tall.html")
        try """
        <html><body style="margin:0"><div style="height:2345px;background:linear-gradient(#ff0000,#0000ff)"></div></body></html>
        """.write(to: html, atomically: true, encoding: .utf8)
        let full = try await space.run(
            "web.to-image", [], ["url": .text(html.path), "width": .text("768")])
        let info = try #require(StudioImageIO.info(try full.url()))
        #expect(info.width == 768)
        #expect(info.height == 2345)
        let bottom = Fixtures.pixel(try StudioImageIO.load(try full.url()), x: 300, y: 2340)
        #expect(bottom.b > 200 && bottom.r < 60)

        let viewport = try await space.run(
            "web.to-image", [],
            [
                "url": .text(html.path), "width": .text("1024"), "fullPage": .bool(false),
                "format": .text("jpg"),
            ])
        let viewportInfo = try #require(StudioImageIO.info(try viewport.url()))
        #expect(viewportInfo.width == 1024 && viewportInfo.height == 900)
        #expect(try viewport.url().pathExtension == "jpg")

        let huge = space.url("huge.html")
        try """
        <html><body style="margin:0"><div style="height:40000px;background:#00ff00"></div><p>Bottom</p></body></html>
        """.write(to: huge, atomically: true, encoding: .utf8)
        let capped = try await space.run(
            "web.to-image", [], ["url": .text(huge.path), "width": .text("390")])
        let cappedInfo = try #require(StudioImageIO.info(try capped.url()))
        #expect(cappedInfo.width == 390 && cappedInfo.height == 32_000)
        #expect(capped.notes.contains { $0.contains("32000") })
    }

    @Test func runawayScriptsAndBrokenAddressesFailWithoutHanging() async throws {
        let space = try Workspace()
        let busy = space.url("busy.html")
        try """
        <html><body><p>Loading forever</p><script>while (true) {}</script></body></html>
        """.write(to: busy, atomically: true, encoding: .utf8)
        let started = Date()
        do {
            _ = try await space.run("web.to-pdf", [], ["url": .text(busy.path)])
            Issue.record("a page with a runaway script produced a PDF")
        } catch let error as StudioError {
            let message = error.localizedDescription
            #expect(
                message.contains("stopped responding") || message.contains("too long")
                    || message.contains("crashed"))
        }
        #expect(Date().timeIntervalSince(started) < 60)

        await #expect(throws: StudioError.self) {
            try await space.run("web.to-pdf", [], ["url": .text(space.url("missing.html").path)])
        }
        let blank = space.url("blank.html")
        try "<html><body>   </body></html>".write(to: blank, atomically: true, encoding: .utf8)
        do {
            _ = try await space.run("web.html-to-pdf", [blank])
            Issue.record("an empty page produced a PDF")
        } catch let error as StudioError {
            #expect(error.localizedDescription.contains("blank.html"))
        }
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: space.output.path)
        #expect(leftovers.isEmpty)
    }
}
