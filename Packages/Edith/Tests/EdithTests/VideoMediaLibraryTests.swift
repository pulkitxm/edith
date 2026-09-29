import AVFoundation
import Foundation
import Testing
@testable import Edith

@Suite struct VideoMediaLibraryTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("media-tests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func file(_ directory: URL, _ name: String, _ contents: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    @Test func copiedFilesHaveExactIdentityRegardlessOfPath() throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = try file(folder, "original.mov", "abc")
        let copy = folder.appendingPathComponent("renamed.mp4")
        try FileManager.default.copyItem(at: first, to: copy)
        let different = try file(folder, "alternate.mov", "abd")
        let identity = try VideoMediaLibrary.identity(of: first)
        #expect(identity.sha256 == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(identity.byteCount == 3)
        #expect(try VideoMediaLibrary.identity(of: copy) == identity)
        #expect(try VideoMediaLibrary.identity(of: different) != identity)
        let groups = try VideoMediaLibrary.duplicates(in: [first, copy, different, first])
        #expect(groups.count == 1)
        #expect(Set(groups[0].urls) == Set([first, copy]))
        #expect(try JSONDecoder().decode(VideoMediaLibrary.Identity.self, from: JSONEncoder().encode(identity)) == identity)
    }

    @Test func hashingIsBoundedAndCancellable() throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("large.mov")
        try Data(repeating: 7, count: 3_000_000).write(to: source)
        var checks = 0
        #expect(throws: CancellationError.self) {
            try VideoMediaLibrary.identity(of: source) {
                checks += 1
                if checks == 3 { throw CancellationError() }
            }
        }
        #expect(checks == 3)
        #expect(throws: VideoMediaLibrary.Failure.self) {
            try VideoMediaLibrary.identity(of: folder)
        }
    }

    @Test func reservationsAreAtomicAndSafeToRelease() throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = VideoMediaLibrary.Source(identity: try VideoMediaLibrary.identity(of: file(folder, "a", "a")))
        let second = VideoMediaLibrary.Source(identity: try VideoMediaLibrary.identity(of: file(folder, "b", "b")))
        let ledger = VideoMediaLibrary.Ledger(url: folder.appendingPathComponent("ledger.json"))
        let receipt = try ledger.reserve([first, first], reelID: "reel-a")
        #expect(receipt.keys.count == 1)
        #expect(throws: VideoMediaLibrary.Failure.self) {
            try ledger.reserve([second, first], reelID: "reel-b")
        }
        let secondReceipt = try ledger.reserve([second], reelID: "reel-b")
        #expect(try ledger.reservations().count == 2)
        let forged = VideoMediaLibrary.Reservation(token: receipt.token, reelID: "reel-b", keys: receipt.keys)
        #expect(throws: VideoMediaLibrary.Failure.invalidReceipt) { try ledger.release(forged) }
        try ledger.release(receipt)
        let replacement = try ledger.reserve([first], reelID: "reel-c")
        #expect(throws: VideoMediaLibrary.Failure.invalidReceipt) { try ledger.release(receipt) }
        #expect(try ledger.reservations().contains(replacement))
        try ledger.release(replacement)
        try ledger.release(secondReceipt)
        #expect(try ledger.reservations().isEmpty)
    }

    @Test func declaredAlternateExportsShareAReservationFamily() throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let a = try VideoMediaLibrary.identity(of: file(folder, "a", "original"))
        let b = try VideoMediaLibrary.identity(of: file(folder, "b", "alternate export"))
        let provenance = VideoMediaLibrary.Provenance(sourceFamilyID: "shoot-42", declaration: "Declared alternate exports")
        let ledger = VideoMediaLibrary.Ledger(url: folder.appendingPathComponent("ledger.json"))
        let receipt = try ledger.reserve([.init(identity: a, provenance: provenance)], reelID: "first")
        #expect(throws: VideoMediaLibrary.Failure.self) {
            try ledger.reserve([.init(identity: b, provenance: provenance)], reelID: "second")
        }
        #expect(throws: VideoMediaLibrary.Failure.self) {
            try ledger.reserve([.init(identity: a)], reelID: "second")
        }
        try ledger.release(receipt)
        let second = try ledger.reserve([.init(identity: b, provenance: provenance)], reelID: "second")
        #expect(throws: VideoMediaLibrary.Failure.self) {
            try ledger.reserve([.init(identity: a)], reelID: "third")
        }
        try ledger.release(second)
    }

    @Test func simultaneousReservationsHaveExactlyOneWinner() async throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = VideoMediaLibrary.Source(identity: try VideoMediaLibrary.identity(of: file(folder, "a", "shared")))
        let ledgerURL = folder.appendingPathComponent("ledger.json")
        let receipts = await withTaskGroup(of: VideoMediaLibrary.Reservation?.self) { group in
            for index in 0..<16 {
                group.addTask {
                    try? VideoMediaLibrary.Ledger(url: ledgerURL).reserve([source], reelID: "reel-\(index)")
                }
            }
            var receipts: [VideoMediaLibrary.Reservation] = []
            for await receipt in group { if let receipt { receipts.append(receipt) } }
            return receipts
        }
        #expect(receipts.count == 1)
        #expect(try VideoMediaLibrary.Ledger(url: ledgerURL).reservations() == receipts)
    }

    @Test func corruptLedgerFailsClosedAndCancellationDoesNotReserve() throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = VideoMediaLibrary.Source(identity: try VideoMediaLibrary.identity(of: file(folder, "a", "shared")))
        let url = try file(folder, "ledger.json", "broken")
        let ledger = VideoMediaLibrary.Ledger(url: url)
        #expect(throws: (any Error).self) { try ledger.reserve([source], reelID: "reel") }
        #expect(try String(contentsOf: url, encoding: .utf8) == "broken")
        try FileManager.default.removeItem(at: url)
        #expect(throws: CancellationError.self) {
            try ledger.reserve([source], reelID: "reel") { throw CancellationError() }
        }
        #expect(try ledger.reservations().isEmpty)
    }

    @Test func probesActualAudioFormat() async throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("tone.wav")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480))
        buffer.frameLength = 480
        do {
            let output = try AVAudioFile(forWriting: url, settings: format.settings)
            try output.write(from: buffer)
        }
        let media = try await VideoMediaLibrary.inspect(url)
        #expect(media.metadata.audio.first?.codec == "lpcm")
        #expect(media.metadata.audio.first?.sampleRate == 48_000)
        #expect(media.metadata.audio.first?.channels == 2)
        #expect(media.metadata.video.isEmpty)
        #expect(abs((media.metadata.duration ?? 0) - 0.01) < 0.001)
    }
}
