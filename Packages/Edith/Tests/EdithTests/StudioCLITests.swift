import EdithStudio
import Foundation
import PDFKit
import Testing

@testable import EdithCLI
@testable import EdithKit

@Suite(.serialized) struct StudioCLITests {
    static func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ed-studio-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func pdf(_ url: URL, pages: Int) throws {
        var box = CGRect(x: 0, y: 0, width: 300, height: 400)
        guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else { return }
        for _ in 0..<pages {
            context.beginPage(mediaBox: &box)
            context.endPage()
        }
        context.closePDF()
    }

    static func json(_ text: String) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: Data(text.utf8))
        return try #require(object as? [String: Any])
    }

    @Test func runMergesThroughTheRealCommandAndReportsJSON() async throws {
        let folder = try Self.folder()
        let a = folder.appendingPathComponent("a.pdf")
        let b = folder.appendingPathComponent("b.pdf")
        try Self.pdf(a, pages: 2)
        try Self.pdf(b, pages: 3)
        let out = folder.appendingPathComponent("out", isDirectory: true)
        let run = await CLIProbe.run([
            "studio", "run", "pdf.merge", a.path, b.path, "--output-dir", out.path,
            "--set", "bookmarks=false", "--json",
        ])
        #expect(run.code == 0, "\(run.stderr)")
        let object = try Self.json(run.stdout)
        #expect(object["tool"] as? String == "pdf.merge")
        let outputs = try #require(object["outputs"] as? [[String: Any]])
        let path = try #require(outputs.first?["path"] as? String)
        #expect(path.hasPrefix(out.path))
        #expect(PDFDocument(url: URL(fileURLWithPath: path))?.pageCount == 5)
    }

    @Test func partialBatchesReportTheirFailuresAndExitOne() async throws {
        let folder = try Self.folder()
        let good = folder.appendingPathComponent("good.pdf")
        let bad = folder.appendingPathComponent("bad.pdf")
        try Self.pdf(good, pages: 1)
        try Data("not a pdf".utf8).write(to: bad)
        let run = await CLIProbe.run([
            "studio", "run", "pdf.rotate", good.path, bad.path, "--output-dir",
            folder.appendingPathComponent("out").path, "--json",
        ])
        #expect(run.code == 1)
        let object = try Self.json(run.stdout)
        #expect(object["executed"] as? Bool == true)
        #expect((object["failures"] as? [[String: Any]])?.count == 1)
        #expect((object["outputs"] as? [[String: Any]])?.count == 1)
    }

    @Test func runRejectsBadSettingsFilesAndTools() async throws {
        let folder = try Self.folder()
        let a = folder.appendingPathComponent("a.pdf")
        try Self.pdf(a, pages: 1)
        let unknownSetting = await CLIProbe.run([
            "studio", "run", "pdf.compress", a.path, "--set", "speed=fast",
        ])
        #expect(unknownSetting.code == 2)
        #expect(unknownSetting.stderr.contains("no setting called speed"))
        let badValue = await CLIProbe.run([
            "studio", "run", "pdf.compress", a.path, "--set", "level=max",
        ])
        #expect(badValue.code == 2)
        let missing = await CLIProbe.run([
            "studio", "run", "pdf.compress", folder.appendingPathComponent("nope.pdf").path,
        ])
        #expect(missing.code == 3)
        let tool = await CLIProbe.run(["studio", "info", "pdf.nothing"])
        #expect(tool.code == 3)
        let editor = await CLIProbe.run(["studio", "run", "pdf.edit", a.path])
        #expect(editor.code == 4)
        let wrongKind = await CLIProbe.run(["studio", "run", "image.compress", a.path])
        #expect(wrongKind.code == 2)
    }

    @Test func toolsInfoAndProbeDescribeTheCatalog() async throws {
        let list = await CLIProbe.run(["studio", "tools", "--kind", "pdf", "--json"])
        #expect(list.code == 0)
        let tools = try #require(
            try JSONSerialization.jsonObject(with: Data(list.stdout.utf8)) as? [[String: Any]])
        let ids = tools.compactMap { $0["id"] as? String }
        #expect(ids.contains("pdf.merge"))
        #expect(!ids.contains("image.compress"))
        let info = await CLIProbe.run(["studio", "info", "pdf.compress", "--json"])
        let options = try #require(try Self.json(info.stdout)["options"] as? [[String: Any]])
        #expect(options.contains { $0["key"] as? String == "level" })
        let folder = try Self.folder()
        let a = folder.appendingPathComponent("a.pdf")
        try Self.pdf(a, pages: 4)
        let probe = await CLIProbe.run(["studio", "probe", a.path, "--json"])
        let facts = try Self.json(probe.stdout)
        #expect(facts["kind"] as? String == "pdf")
        #expect(facts["pages"] as? Double == 4)
        #expect((facts["tools"] as? [String])?.contains("pdf.split") == true)
        let text = await CLIProbe.run(["studio"])
        #expect(text.code == 0)
        #expect(text.stdout.contains("pdf.merge"))
    }
}
