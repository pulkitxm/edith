import Foundation
import Testing
import ZIPFoundation

@testable import EdithStudio

@Suite struct DocsAuditFilesTests {
    static func project(in space: Workspace) throws -> URL {
        let folder = space.url("Proj")
        try FileManager.default.createDirectory(
            at: folder.appendingPathComponent("sub/empty"), withIntermediateDirectories: true)
        try "hi".write(
            to: folder.appendingPathComponent("Résumé ✓.txt"), atomically: true, encoding: .utf8)
        try "SECRET=1".write(
            to: folder.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        try "x".write(
            to: folder.appendingPathComponent("sub/a.txt"), atomically: true, encoding: .utf8)
        return folder
    }

    @Test func macZipsKeepUnicodeNamesAndDotfiles() async throws {
        let space = try Workspace()
        let folder = try Self.project(in: space)
        let ditto = space.url("Finder.zip")
        let result = try await StudioProcess.run(
            URL(fileURLWithPath: "/usr/bin/ditto"),
            ["-c", "-k", "--keepParent", folder.path, ditto.path])
        #expect(result.status == 0)
        let original = try Data(contentsOf: ditto)
        let extracted = try await space.run("files.unzip", [ditto])
        let root = try extracted.url()
        #expect(root.lastPathComponent == "Proj")
        #expect(
            try String(contentsOf: root.appendingPathComponent("Résumé ✓.txt"), encoding: .utf8)
                == "hi")
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(".env").path))
        let appleDouble = try FileManager.default.contentsOfDirectory(atPath: root.path).filter {
            $0.hasPrefix("._")
        }
        #expect(appleDouble.isEmpty)
        #expect(try Data(contentsOf: ditto) == original)

        let zipped = try await space.run("files.zip", [folder])
        let paths = Set(try Archive(url: try zipped.url(), accessMode: .read).map(\.path))
        #expect(
            paths.isSuperset(of: [
                "Proj/.env", "Proj/Résumé ✓.txt", "Proj/sub/a.txt", "Proj/sub/empty/",
            ]))

        let flat = space.url("flat")
        try FileManager.default.createDirectory(at: flat, withIntermediateDirectories: true)
        try "ignore".write(
            to: flat.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(
            at: flat.appendingPathComponent("src"), withIntermediateDirectories: true)
        try "code".write(
            to: flat.appendingPathComponent("src/main.swift"), atomically: true, encoding: .utf8)
        let flatZip = space.url("flat.zip")
        let archive = try Archive(url: flatZip, accessMode: .create)
        try archive.addEntry(with: ".gitignore", relativeTo: flat)
        try archive.addEntry(with: "src/main.swift", relativeTo: flat)
        let unpacked = try await space.run("files.unzip", [flatZip])
        let top = try unpacked.url()
        #expect(
            FileManager.default.fileExists(atPath: top.appendingPathComponent(".gitignore").path))
        #expect(
            FileManager.default.fileExists(
                atPath: top.appendingPathComponent("src/main.swift").path))
    }

    @Test func unsafeAndEncryptedArchivesAreRefused() async throws {
        let space = try Workspace()
        for path in ["/tmp/absolute-escape.txt", "..\\..\\windows-escape.txt", "ok/../../up.txt"] {
            let evil = space.url("evil-\(abs(path.hashValue)).zip")
            let archive = try Archive(url: evil, accessMode: .create)
            let payload = Data("owned".utf8)
            try archive.addEntry(
                with: path, type: .file, uncompressedSize: Int64(payload.count),
                provider: { _, _ in payload })
            do {
                _ = try await space.run("files.unzip", [evil])
                Issue.record("\(path) was extracted")
            } catch let error as StudioError {
                #expect(error.localizedDescription.contains("unsafe path"))
            }
        }
        let escaped = ["absolute-escape.txt", "windows-escape.txt", "up.txt"].filter {
            FileManager.default.fileExists(
                atPath: space.root.deletingLastPathComponent().appendingPathComponent($0).path)
                || FileManager.default.fileExists(atPath: "/tmp/" + $0)
        }
        #expect(escaped.isEmpty)

        let folder = try Self.project(in: space)
        let locked = space.url("locked.zip")
        let zip = try await StudioProcess.run(
            URL(fileURLWithPath: "/usr/bin/zip"), ["-q", "-r", "-P", "pw", locked.path, "Proj"],
            currentDirectory: space.root)
        #expect(zip.status == 0)
        do {
            _ = try await space.run("files.unzip", [locked])
            Issue.record("an encrypted zip was extracted")
        } catch let error as StudioError {
            #expect(error.localizedDescription.contains("password protected"))
        }
        let _ = folder
    }

    @Test func tarArchivesCarryNoMacMetadata() async throws {
        let space = try Workspace()
        let folder = try Self.project(in: space)
        let file = folder.appendingPathComponent("sub/a.txt")
        _ = try await StudioProcess.run(
            URL(fileURLWithPath: "/usr/bin/xattr"), ["-w", "com.example.tag", "hello", file.path])
        let packed = try await space.run("files.tar", [folder], ["format": .text("tar")])
        let data = try Data(contentsOf: try packed.url())
        #expect(data.range(of: Data("xattr".utf8)) == nil)
        #expect(data.range(of: Data("._a.txt".utf8)) == nil)
        let listing = try await StudioProcess.run(
            URL(fileURLWithPath: "/usr/bin/tar"), ["-tf", try packed.url().path])
        let names = Set(listing.output.split(separator: "\n").map(String.init))
        #expect(names.isSuperset(of: ["Proj/.env", "Proj/Résumé ✓.txt", "Proj/sub/a.txt"]))
    }
}
