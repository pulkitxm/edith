import Foundation
import Testing
import ZIPFoundation

@testable import EdithStudio

@Suite struct FileToolsTests {
    @Test func zipRoundTripKeepsFoldersAndUnicodeNames() async throws {
        let space = try Workspace()
        let folder = space.url("Project")
        try FileManager.default.createDirectory(
            at: folder.appendingPathComponent("docs/nested"), withIntermediateDirectories: true)
        try "readme".write(
            to: folder.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try "deep".write(
            to: folder.appendingPathComponent("docs/nested/Résumé ✓.txt"), atomically: true,
            encoding: .utf8)
        let loose = space.url("notes.txt")
        try String(repeating: "compress me ", count: 500).write(
            to: loose, atomically: true, encoding: .utf8)

        let zipped = try await space.run("files.zip", [folder, loose])
        let archive = try zipped.url()
        #expect(archive.lastPathComponent == "Archive.zip")
        #expect(zipped.outputs[0].bytes < StudioRunner.fileSize(loose))
        let paths = Set(try Archive(url: archive, accessMode: .read).map(\.path))
        #expect(paths.contains("Project/docs/nested/Résumé ✓.txt"))
        #expect(paths.contains("notes.txt"))

        let extractSpace = try Workspace()
        let copy = extractSpace.url("Archive.zip")
        try FileManager.default.copyItem(at: archive, to: copy)
        let extracted = try await extractSpace.run("files.unzip", [copy])
        let root = try extracted.url()
        #expect(root.lastPathComponent == "Archive")
        let deep = root.appendingPathComponent("Project/docs/nested/Résumé ✓.txt")
        #expect(try String(contentsOf: deep, encoding: .utf8) == "deep")
        #expect(extracted.notes.first?.contains("item") == true)
    }

    @Test func singleFileZipIsNamedAfterTheFileAndUnzipsFlat() async throws {
        let space = try Workspace()
        let file = space.url("report.pdf")
        try Fixtures.pdf(at: file, pages: ["Report"])
        let zipped = try await space.run("files.zip", [file], ["method": .text("store")])
        #expect(try zipped.url().lastPathComponent == "report.zip")
        let extractSpace = try Workspace()
        let copy = extractSpace.url("report.zip")
        try FileManager.default.copyItem(at: try zipped.url(), to: copy)
        let extracted = try await extractSpace.run("files.unzip", [copy])
        #expect(try extracted.url().lastPathComponent == "report.pdf")
        #expect(Fixtures.text(of: try extracted.url()).contains("Report"))
    }

    @Test func tarArchivesRoundTrip() async throws {
        let space = try Workspace()
        let folder = space.url("logs")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "one".write(
            to: folder.appendingPathComponent("a.log"), atomically: true, encoding: .utf8)
        try "two".write(
            to: folder.appendingPathComponent("b.log"), atomically: true, encoding: .utf8)
        let packed = try await space.run("files.tar", [folder])
        let tarball = try packed.url()
        #expect(tarball.lastPathComponent == "logs.tar.gz")

        let extractSpace = try Workspace()
        let copy = extractSpace.url("logs.tar.gz")
        try FileManager.default.copyItem(at: tarball, to: copy)
        let extracted = try await extractSpace.run("files.unzip", [copy])
        let root = try extracted.url()
        #expect(
            try String(contentsOf: root.appendingPathComponent("b.log"), encoding: .utf8) == "two")
    }

    @Test func gzipSingleFileDecompresses() async throws {
        let space = try Workspace()
        let text = space.url("data.csv")
        try "a,b\n1,2\n".write(to: text, atomically: true, encoding: .utf8)
        let result = try await StudioProcess.run(
            URL(fileURLWithPath: "/usr/bin/gzip"), ["-k", text.path])
        #expect(result.status == 0)
        let gz = space.url("data.csv.gz")
        let extracted = try await space.run("files.unzip", [gz])
        #expect(try String(contentsOf: try extracted.url(), encoding: .utf8) == "a,b\n1,2\n")
    }

    @Test func archivesThatEscapeTheFolderAreRefused() async throws {
        let space = try Workspace()
        let evil = space.url("evil.zip")
        let archive = try Archive(url: evil, accessMode: .create)
        let payload = Data("owned".utf8)
        try archive.addEntry(
            with: "../../escaped.txt", type: .file, uncompressedSize: Int64(payload.count),
            provider: { _, _ in payload })
        await #expect(throws: StudioError.self) { try await space.run("files.unzip", [evil]) }
        #expect(
            !FileManager.default.fileExists(
                atPath: space.root.deletingLastPathComponent().appendingPathComponent("escaped.txt")
                    .path))
        #expect(Extractor.contained("a/../../b", in: space.root) == nil)
        #expect(Extractor.contained("/etc/passwd", in: space.root) == nil)
        #expect(Extractor.contained("safe/inner.txt", in: space.root) != nil)
    }
}

@Suite struct DocumentCatalogTests {
    @Test func docsFamilyIsRegisteredWithQuickActions() {
        let ids = [
            "document.to-pdf", "document.word-to-pdf", "document.excel-to-pdf",
            "document.powerpoint-to-pdf", "document.to-markdown", "document.to-text", "web.to-pdf",
            "web.to-image", "web.html-to-pdf", "files.zip", "files.unzip", "files.tar",
            "ai.summarize",
            "ai.translate",
        ]
        for id in ids { #expect(StudioCatalog.tool(id) != nil, "\(id) is not registered") }
        #expect(StudioCatalog.quickTool(.convert, for: .document)?.id == "document.to-pdf")
        #expect(StudioCatalog.quickTool(.convert, for: .presentation)?.id == "document.to-pdf")
        #expect(StudioCatalog.quickTool(.compress, for: .other)?.id == "files.zip")
        #expect(StudioCatalog.quickTool(.convert, for: .archive)?.id == "files.unzip")
        let html = URL(fileURLWithPath: "/tmp/page.html")
        #expect(StudioCatalog.tools(accepting: [html]).contains { $0.id == "web.html-to-pdf" })
        #expect(
            !StudioCatalog.tools(accepting: [URL(fileURLWithPath: "/tmp/a.md")]).contains {
                $0.id == "document.to-markdown"
            })
    }
}
