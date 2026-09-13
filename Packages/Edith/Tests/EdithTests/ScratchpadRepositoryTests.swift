import Foundation
import Testing

@testable import EdithKit

@Suite(.serialized) struct ScratchpadRepositoryTests {
    private func withRepository(_ body: (URL) throws -> Void) throws {
        let original = ScratchpadPaths.root
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-scratchpad-tests-\(UUID().uuidString)")
        ScratchpadPaths.root = root
        defer {
            ScratchpadPaths.root = original
            try? FileManager.default.removeItem(at: root)
        }
        try body(root)
    }

    @Test func initialDocumentHasOneNamedPad() throws {
        try withRepository { _ in
            let document = try ScratchpadRepository.load()
            #expect(document.pads.count == 1)
            #expect(document.selectedPad?.name == "Scratchpad 1")
            #expect(document.selectedPad?.text == "")
        }
    }

    @Test func createsRenamesDuplicatesAndRemovesPads() throws {
        try withRepository { _ in
            let created = try ScratchpadRepository.create(name: "Meeting", text: "Decisions")
            let pad = try #require(created.selectedPad)
            #expect(pad.name == "Meeting")
            #expect(pad.text == "Decisions")

            let renamed = try ScratchpadRepository.rename(pad.id.uuidString, to: "Standup")
            #expect(renamed.selectedPad?.name == "Standup")

            let duplicated = try ScratchpadRepository.duplicate("Standup")
            #expect(duplicated.pads.count == 3)
            #expect(duplicated.selectedPad?.name == "Standup copy")
            #expect(duplicated.selectedPad?.text == "Decisions")

            let removed = try ScratchpadRepository.remove("Standup copy")
            #expect(removed.pads.count == 2)
            #expect(!removed.pads.contains { $0.name == "Standup copy" })
        }
    }

    @Test func autosaveUpdatePersistsAcrossLoads() throws {
        try withRepository { _ in
            let initial = try ScratchpadRepository.load()
            let id = try #require(initial.selectedPad?.id)
            _ = try ScratchpadRepository.update(id.uuidString, text: "# Today\n\nShip it")
            let reloaded = try ScratchpadRepository.load()
            #expect(reloaded.selectedPad?.text == "# Today\n\nShip it")
            #expect(reloaded.selectedPad?.modifiedAt != nil)
        }
    }

    @Test func retentionClearsOnlyExpiredNonemptyPads() throws {
        try withRepository { _ in
            let edited = Date(timeIntervalSince1970: 1_000)
            let initial = try ScratchpadRepository.load(now: edited)
            let id = try #require(initial.selectedPad?.id)
            _ = try ScratchpadRepository.update(id.uuidString, text: "temporary", now: edited)

            let kept = try ScratchpadRepository.load(
                retention: .hour, now: edited.addingTimeInterval(3_600))
            #expect(kept.selectedPad?.text == "temporary")

            let cleared = try ScratchpadRepository.load(
                retention: .hour, now: edited.addingTimeInterval(3_601))
            #expect(cleared.selectedPad?.text == "")
            #expect(cleared.selectedPad?.modifiedAt == nil)
        }
    }

    @Test func searchFindsNamesAndRepeatedText() throws {
        try withRepository { _ in
            _ = try ScratchpadRepository.create(
                name: "Launch notes", text: "Ready for launch. Launch after lunch.")
            let document = try ScratchpadRepository.load()
            let results = ScratchpadRepository.search("launch", in: document)
            #expect(results.count == 1)
            #expect(results[0].matchCount == 3)
        }
    }

    @Test func namesAreTrimmedUniqueAndBounded() throws {
        try withRepository { _ in
            _ = try ScratchpadRepository.create(name: "  Project\n  notes  ")
            let duplicateName = try ScratchpadRepository.create(name: "project notes")
            #expect(duplicateName.selectedPad?.name == "project notes 2")
            #expect(
                duplicateName.selectedPad?.name.count ?? 0 <= ScratchpadDocument.maximumNameLength)

            let longest = String(repeating: "x", count: ScratchpadDocument.maximumNameLength)
            _ = try ScratchpadRepository.create(name: longest)
            let boundedDuplicate = try ScratchpadRepository.create(name: longest)
            #expect(boundedDuplicate.selectedPad?.name.hasSuffix(" 2") == true)
            #expect(
                boundedDuplicate.selectedPad?.name.count == ScratchpadDocument.maximumNameLength)
        }
    }

    @Test func exportWritesExactPlainText() throws {
        try withRepository { root in
            let document = try ScratchpadRepository.create(name: "Export", text: "plain **text**")
            let pad = try #require(document.selectedPad)
            let destination = root.appendingPathComponent("export.md")
            try ScratchpadRepository.export(pad, to: destination)
            #expect(try String(contentsOf: destination, encoding: .utf8) == "plain **text**")
        }
    }
}
