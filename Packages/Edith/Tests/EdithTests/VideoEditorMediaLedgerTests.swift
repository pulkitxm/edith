import ArgumentParser
import Foundation
import EdithDocs
import Testing
@testable import Edith
@testable import EdithCLI

@Suite struct VideoEditorMediaLedgerTests {
    @Test func oversizedReceiptsAndLedgerExpansionFailBeforeCommit() async throws {
        let folder = try VideoEditorServiceTests.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = try VideoEditorMediaServiceTests.fixture(folder)
        var project = try VideoProject.open(source)
        try project.indexMedia(provenanceByAssetID: [
            project.assets[0].id: .init(
                sourceFamilyID: String(repeating: "f", count: 1024 * 1024),
                declaration: "synthetic imported family")
        ])
        try project.save(to: source)
        let ledger = VideoMediaLibrary.Ledger(url: folder.appendingPathComponent("ledger.json"))
        await #expect(throws: (any Error).self) {
            try await VideoEditorService.mediaReserve(source, ledger: ledger.url, reelID: "r")
        }
        #expect(try ledger.reservations().isEmpty)
        let identities = (1...1000).map { index in
            VideoMediaLibrary.Source(
                identity: .init(sha256: String(format: "%064x", index), byteCount: 0))
        }
        #expect(throws: VideoMediaLibrary.Failure.invalidLedger) {
            try ledger.reserve(identities, reelID: "large")
        }
        #expect(try ledger.reservations().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: ledger.url.path))
    }

    @Test func reserveListReleaseAreIndependentOfProjectWritesAndRequireExactReceipts() async throws
    {
        let folder = try VideoEditorServiceTests.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let project = try VideoEditorMediaServiceTests.fixture(folder)
        let before = try Data(contentsOf: project)
        let ledger = folder.appendingPathComponent("ledger.json")
        let data = try await VideoEditorService.mediaReserve(
            project, ledger: ledger, reelID: "reel-one")
        let report = try VideoEditorMediaServiceTests.decode(
            VideoEditorService.MediaReservation.self, data)
        #expect(report.written && report.result.receipt.reelID == "reel-one")
        #expect(try Data(contentsOf: project) == before)
        let originalLedger = try Data(contentsOf: ledger)
        await #expect(throws: (any Error).self) {
            try await VideoEditorService.mediaReserve(project, ledger: ledger, reelID: "reel-two")
        }
        #expect(try Data(contentsOf: ledger) == originalLedger)
        let list = try VideoEditorMediaServiceTests.decode(
            VideoEditorService.MediaReservations.self,
            await VideoEditorService.mediaReservations(ledger, limit: 1))
        #expect(list.result.total == 1 && list.result.receipts == [report.result.receipt])
        let receiptFile = folder.appendingPathComponent("receipt.json")
        var tampered = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var result = tampered["result"] as! [String: Any]
        var receipt = result["receipt"] as! [String: Any]
        receipt["token"] = UUID().uuidString
        result["receipt"] = receipt
        tampered["result"] = result
        try JSONSerialization.data(withJSONObject: tampered).write(to: receiptFile)
        await #expect(throws: (any Error).self) {
            try await VideoEditorService.mediaRelease(ledger, receiptFile: receiptFile)
        }
        #expect(try Data(contentsOf: ledger) == originalLedger)
        try data.write(to: receiptFile)
        let released = try VideoEditorMediaServiceTests.decode(
            VideoEditorService.MediaRelease.self,
            await VideoEditorService.mediaRelease(ledger, receiptFile: receiptFile))
        #expect(released.result.released && released.result.token == report.result.receipt.token)
        #expect(try VideoMediaLibrary.Ledger(url: ledger).reservations().isEmpty)
        await #expect(throws: (any Error).self) {
            try await VideoEditorService.mediaRelease(ledger, receiptFile: receiptFile)
        }
        _ = try await VideoEditorService.mediaReserve(project, ledger: ledger, reelID: "reel-two")
        #expect(try Data(contentsOf: project) == before)
    }

    @Test func ledgerRejectsSourceDestinationsOversizedInputAndUnknownReceiptFields() async throws {
        let folder = try VideoEditorServiceTests.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("original.json")
        try Data("synthetic media".utf8).write(to: source)
        var project = VideoProject.create()
        project.addAsset(source, duration: 1, width: 64, height: 64)
        let projectURL = folder.appendingPathComponent("project.openscreen")
        try project.save(to: projectURL)
        await #expect(throws: (any Error).self) {
            try await VideoEditorService.mediaReserve(projectURL, ledger: source, reelID: "r")
        }
        #expect(try String(contentsOf: source, encoding: .utf8) == "synthetic media")
        let ledger = folder.appendingPathComponent("ledger.json")
        let data = try await VideoEditorService.mediaReserve(
            projectURL, ledger: ledger, reelID: "r")
        let unchanged = try Data(contentsOf: ledger)
        let receiptFile = folder.appendingPathComponent("receipt.json")
        var root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        root["typo"] = true
        try JSONSerialization.data(withJSONObject: root).write(to: receiptFile)
        await #expect(throws: (any Error).self) {
            try await VideoEditorService.mediaRelease(ledger, receiptFile: receiptFile)
        }
        try Data(repeating: 32, count: 1024 * 1024 + 1).write(to: receiptFile)
        await #expect(throws: (any Error).self) {
            try await VideoEditorService.mediaRelease(ledger, receiptFile: receiptFile)
        }
        try data.write(to: receiptFile)
        await #expect(throws: (any Error).self) {
            try await VideoEditorService.mediaRelease(
                folder.appendingPathComponent("other.json"), receiptFile: receiptFile)
        }
        #expect(try Data(contentsOf: ledger) == unchanged)
        let oversized = folder.appendingPathComponent("oversized.json")
        try Data().write(to: oversized)
        let handle = try FileHandle(forWritingTo: oversized)
        try handle.truncate(atOffset: 32 * 1024 * 1024 + 1)
        try handle.close()
        await #expect(throws: (any Error).self) {
            try await VideoEditorService.mediaReservations(oversized)
        }
        await #expect(throws: (any Error).self) {
            try await VideoEditorService.mediaReservations(ledger, limit: 101)
        }
    }

    @Test func receiptValidationRollsBackReservationAndPaginationIsStable() async throws {
        let folder = try VideoEditorServiceTests.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = try VideoEditorMediaServiceTests.fixture(folder)
        let project = try VideoProject.open(source)
        let ledger = VideoMediaLibrary.Ledger(url: folder.appendingPathComponent("ledger.json"))
        #expect(throws: (any Error).self) {
            try project.reserveOriginalMedia(
                in: ledger, reelID: "r",
                validateReceipt: { _ in
                    throw VideoEditorService.Failure(
                        "invalid_value", "Synthetic receipt size failure")
                })
        }
        #expect(try ledger.reservations().isEmpty)
        let first = try await VideoEditorService.mediaReserve(
            source, ledger: ledger.url, reelID: "first")
        var other = VideoProject.create()
        let media = folder.appendingPathComponent("other.mov")
        try Data("different original".utf8).write(to: media)
        other.addAsset(media, duration: 1, width: 64, height: 64)
        let path = folder.appendingPathComponent("other.openscreen")
        try other.save(to: path)
        _ = try await VideoEditorService.mediaReserve(path, ledger: ledger.url, reelID: "second")
        let a = try VideoEditorMediaServiceTests.decode(
            VideoEditorService.MediaReservations.self,
            await VideoEditorService.mediaReservations(ledger.url, offset: 0, limit: 1)
        ).result
        let b = try VideoEditorMediaServiceTests.decode(
            VideoEditorService.MediaReservations.self,
            await VideoEditorService.mediaReservations(ledger.url, offset: 1, limit: 1)
        ).result
        #expect(a.total == 2 && a.nextOffset == 1 && b.nextOffset == nil)
        #expect(a.receipts[0].token.uuidString < b.receipts[0].token.uuidString)
        #expect(try VideoEditorService.decodeMediaReceipt(first).receipt.reelID == "first")
    }

    @Test func ledgerRoutesHaveParsingTreeCatalogAndStructuredRuntimeErrors() async throws {
        let examples = [
            (
                "reserve",
                [
                    "/nonexistent/project.openscreen", "--ledger", "/nonexistent/ledger.json",
                    "--reel", "r",
                ]
            ),
            ("reservations", ["--ledger", "/nonexistent/ledger.invalid"]),
            (
                "release",
                ["--ledger", "/nonexistent/ledger.json", "--receipt", "/nonexistent/receipt.json"]
            ),
        ]
        for (name, arguments) in examples {
            let route = ["studio", "edit", "media", name]
            let command = try EdRoot.parseAsRoot(route + arguments + ["--json"])
            #expect(!EdRoot.helpMessage(for: type(of: command)).isEmpty)
            #expect(CommandTree.node(at: route)?.options.contains("--ledger") == true)
            let tool = try #require(
                OperationMCPCatalog.tool(named: "edith_studio_edit_media_\(name)"))
            #expect(tool.route == route && tool.effect == (name == "reservations" ? .read : .write))
            let manual = try #require(DocsLibrary.bundled())
            let location = try #require(
                manual.location(forCommand: "ed " + route.joined(separator: " ")))
            #expect(location.path == "studio/edit-media-storage.md")
            let result = await CLIProbe.run(route + arguments + ["--json"])
            #expect(result.code != 0 && result.stdout.isEmpty)
            let error = try #require(
                JSONSerialization.jsonObject(with: Data(result.stderr.utf8)) as? [String: Any])
            #expect(error["version"] as? Int == 1 && error["error"] is [String: String])
        }
    }
}
