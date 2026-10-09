import EdithExtensionUI
import EdithExtensionSupport
import AVFoundation
import Foundation
import ImageIO
import Testing
@testable import StudioExtension

@Suite struct VideoMediaLibraryTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "media-tests-\(UUID())")
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
        #expect(
            identity.sha256 == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(identity.byteCount == 3)
        #expect(try VideoMediaLibrary.identity(of: copy) == identity)
        #expect(try VideoMediaLibrary.identity(of: different) != identity)
        let groups = try VideoMediaLibrary.duplicates(in: [first, copy, different, first])
        #expect(groups.count == 1)
        #expect(Set(groups[0].urls) == Set([first, copy]))
        #expect(
            try JSONDecoder().decode(
                VideoMediaLibrary.Identity.self, from: JSONEncoder().encode(identity)) == identity)
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

    @Test func replacingPathDuringReadRejectsStaleIdentity() throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = try file(folder, "source.mov", "original bytes")
        let replacement = try file(folder, "replacement.mov", "replacement bytes")
        var checks = 0
        #expect(throws: VideoMediaLibrary.Failure.changedDuringRead(source.path)) {
            try VideoMediaLibrary.identity(of: source) {
                checks += 1
                if checks == 3 {
                    try FileManager.default.removeItem(at: source)
                    try FileManager.default.moveItem(at: replacement, to: source)
                }
            }
        }
    }

    @Test func conflictingBatchRollsBackProvenanceDeclarations() throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let a = try VideoMediaLibrary.identity(of: file(folder, "a", "first"))
        let b = try VideoMediaLibrary.identity(of: file(folder, "b", "second"))
        let ledger = VideoMediaLibrary.Ledger(url: folder.appendingPathComponent("ledger.json"))
        let receipt = try ledger.reserve([.init(identity: a)], reelID: "first")
        #expect(throws: VideoMediaLibrary.Failure.self) {
            try ledger.reserve(
                [
                    .init(
                        identity: b,
                        provenance: .init(sourceFamilyID: "rolled-back", declaration: "test")),
                    .init(identity: a),
                ], reelID: "second")
        }
        let other = try ledger.reserve(
            [
                .init(
                    identity: b, provenance: .init(sourceFamilyID: "retained", declaration: "test"))
            ], reelID: "second")
        try ledger.release(other)
        try ledger.release(receipt)
    }

    @Test func reservationsAreAtomicAndSafeToRelease() throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = VideoMediaLibrary.Source(
            identity: try VideoMediaLibrary.identity(of: file(folder, "a", "a")))
        let second = VideoMediaLibrary.Source(
            identity: try VideoMediaLibrary.identity(of: file(folder, "b", "b")))
        let ledger = VideoMediaLibrary.Ledger(url: folder.appendingPathComponent("ledger.json"))
        let receipt = try ledger.reserve([first, first], reelID: "reel-a")
        #expect(receipt.keys.count == 1)
        #expect(throws: VideoMediaLibrary.Failure.self) {
            try ledger.reserve([second, first], reelID: "reel-b")
        }
        let secondReceipt = try ledger.reserve([second], reelID: "reel-b")
        #expect(try ledger.reservations().count == 2)
        let forged = VideoMediaLibrary.Reservation(
            token: receipt.token, reelID: "reel-b", keys: receipt.keys)
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
        let provenance = VideoMediaLibrary.Provenance(
            sourceFamilyID: "shoot-42", declaration: "Declared alternate exports")
        let ledger = VideoMediaLibrary.Ledger(url: folder.appendingPathComponent("ledger.json"))
        let receipt = try ledger.reserve(
            [.init(identity: a, provenance: provenance)], reelID: "first")
        #expect(throws: VideoMediaLibrary.Failure.self) {
            try ledger.reserve([.init(identity: b, provenance: provenance)], reelID: "second")
        }
        #expect(throws: VideoMediaLibrary.Failure.self) {
            try ledger.reserve([.init(identity: a)], reelID: "second")
        }
        try ledger.release(receipt)
        let second = try ledger.reserve(
            [.init(identity: b, provenance: provenance)], reelID: "second")
        #expect(throws: VideoMediaLibrary.Failure.self) {
            try ledger.reserve([.init(identity: a)], reelID: "third")
        }
        try ledger.release(second)
    }

    @Test func simultaneousReservationsHaveExactlyOneWinner() async throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = VideoMediaLibrary.Source(
            identity: try VideoMediaLibrary.identity(of: file(folder, "a", "shared")))
        let ledgerURL = folder.appendingPathComponent("ledger.json")
        let receipts = await withTaskGroup(of: VideoMediaLibrary.Reservation?.self) { group in
            for index in 0..<16 {
                group.addTask {
                    try? VideoMediaLibrary.Ledger(url: ledgerURL).reserve(
                        [source], reelID: "reel-\(index)")
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
        let source = VideoMediaLibrary.Source(
            identity: try VideoMediaLibrary.identity(of: file(folder, "a", "shared")))
        let url = try file(folder, "ledger.json", "broken")
        let ledger = VideoMediaLibrary.Ledger(url: url)
        #expect(throws: (any Error).self) { try ledger.reserve([source], reelID: "reel") }
        #expect(try String(contentsOf: url, encoding: .utf8) == "broken")
        try FileManager.default.removeItem(at: url)
        #expect(throws: CancellationError.self) {
            try ledger.reserve(
                [source], reelID: "reel", checkCancellation: { throw CancellationError() })
        }
        #expect(try ledger.reservations().isEmpty)
    }

    @Test func ledgerRejectsSymlinkAliasesAndIncompleteReceipts() throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = VideoMediaLibrary.Source(
            identity: try VideoMediaLibrary.identity(of: file(folder, "a", "shared")),
            provenance: .init(sourceFamilyID: "session", declaration: "original"))
        let url = folder.appendingPathComponent("ledger.json")
        let ledger = VideoMediaLibrary.Ledger(url: url)
        let receipt = try ledger.reserve([source], reelID: "first")
        let alias = folder.appendingPathComponent("alias.json")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: url)
        #expect(throws: VideoMediaLibrary.Failure.invalidLedger) {
            try VideoMediaLibrary.Ledger(url: alias).release(receipt)
        }
        #expect(try ledger.reservations() == [receipt])
        var raw = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var reservations = try #require(raw["reservations"] as? [String: Any])
        reservations.removeValue(forKey: "family:session")
        raw["reservations"] = reservations
        try JSONSerialization.data(withJSONObject: raw).write(to: url)
        #expect(throws: VideoMediaLibrary.Failure.invalidLedger) { try ledger.reservations() }
        #expect(throws: VideoMediaLibrary.Failure.invalidLedger) {
            try ledger.reserve([source], reelID: "second")
        }
    }

    @Test func reservationsRejectMissingTimelineAssets() throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = try file(folder, "source.mov", "original")
        var project = VideoProject.create()
        project.addAsset(original, duration: 1, width: 1, height: 1)
        var clips = project.clips
        clips.append(
            .init(raw: ["id": "missing-clip", "assetId": "missing-asset", "sourceEndSec": 1.0]))
        project.setClips(clips)
        let ledger = VideoMediaLibrary.Ledger(url: folder.appendingPathComponent("ledger.json"))
        #expect(throws: VideoMediaLibrary.Failure.self) {
            try project.reserveOriginalMedia(in: ledger, reelID: "reel")
        }
        #expect(try ledger.reservations().isEmpty)
    }

    @Test func probesActualAudioFormat() async throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let sources = folder.appendingPathComponent("sources")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: false)
        let url = sources.appendingPathComponent("tone.wav")
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
        var project = VideoProject.create()
        project.addAsset(url, duration: 0.01, width: 1, height: 1)
        let package = try project.packageOriginalMedia(to: folder.appendingPathComponent("package"))
        try FileManager.default.removeItem(at: sources)
        let moved = folder.appendingPathComponent("moved")
        try FileManager.default.moveItem(at: package.directory, to: moved)
        let reopened = try VideoProject.openMediaPackage(moved)
        #expect(
            try await VideoMediaLibrary.probe(reopened.assets[0].url).audio.first?.sampleRate
                == 48_000)
    }

    @Test func differentSectionsOfCopiedSourceCannotBeReservedAcrossReels() throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = try file(folder, "source.mov", "same original footage")
        let copy = folder.appendingPathComponent("copy.mov")
        try FileManager.default.copyItem(at: original, to: copy)
        var first = VideoProject.create(title: "First reel")
        first.addAsset(original, duration: 10, width: 100, height: 100)
        first.trim(clipID: first.clips[0].id, start: 0, end: 2)
        var second = VideoProject.create(title: "Second reel")
        second.addAsset(copy, duration: 10, width: 100, height: 100)
        second.trim(clipID: second.clips[0].id, start: 7, end: 10)
        let ledger = VideoMediaLibrary.Ledger(url: folder.appendingPathComponent("ledger.json"))
        let receipt = try first.reserveOriginalMedia(in: ledger, reelID: first.id)
        #expect(throws: VideoMediaLibrary.Failure.self) {
            try second.reserveOriginalMedia(in: ledger, reelID: second.id)
        }
        try ledger.release(receipt)
        #expect(try second.reserveOriginalMedia(in: ledger, reelID: second.id).reelID == second.id)
    }

    @Test func packageRoundtripPreservesAllOriginalBytesAndUnknownSettings() throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let sources = folder.appendingPathComponent("sources")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: false)
        let original = try file(sources, "source.mov", "video bytes")
        let copy = try file(sources, "copy.mov", "video bytes")
        let audio = try file(sources, "audio.wav", "audio bytes")
        let camera = try file(sources, "camera.mov", "camera bytes")
        let still = try image(sources, name: "still.jpg", exif: [:])
        var project = VideoProject.create(title: "Synthetic reel")
        project.root["customSetting"] = ["keep": 42]
        project.addAsset(original, duration: 5, width: 100, height: 100)
        project.addAsset(copy, duration: 5, width: 100, height: 100)
        try project.addStillAsset(still, duration: 5, metadata: VideoStillMedia.metadata(at: still))
        project.addAudio(audio, duration: 10, at: 0)
        project.attachCamera(camera, to: project.assets[0].id, offsetMs: 120)
        let sourceProject = sources.appendingPathComponent("original.openscreen")
        try project.save(to: sourceProject)
        let sourceDocument = try Data(contentsOf: sourceProject)
        let beforeRoot = try JSONSerialization.data(
            withJSONObject: project.root, options: .sortedKeys)
        let result = try project.packageOriginalMedia(to: folder.appendingPathComponent("package"))
        #expect(result.copiedFileCount == 4)
        #expect(result.manifest.entries.count == 5)
        #expect(try Data(contentsOf: sourceProject) == sourceDocument)
        #expect(
            try JSONSerialization.data(withJSONObject: project.root, options: .sortedKeys)
                == beforeRoot)
        #expect(try Data(contentsOf: original) == Data("video bytes".utf8))
        #expect(
            try VideoProject.open(result.projectURL).assets[0].url.path.hasPrefix(
                result.directory.path))
        let moved = folder.appendingPathComponent("moved-package")
        try FileManager.default.moveItem(at: result.directory, to: moved)
        try FileManager.default.removeItem(at: sources)
        let reopened = try VideoProject.openMediaPackage(moved)
        #expect(reopened.title == "Synthetic reel")
        #expect((reopened.root["customSetting"] as? [String: Int])?["keep"] == 42)
        #expect(reopened.assets[0].cameraTrack?["offsetMs"] as? Int == 120)
        #expect(reopened.clips.map(\.duration) == [5, 5, 5])
        #expect(reopened.assets[2].isStill)
        for entry in result.manifest.entries {
            let url = try reopened.mediaURL(for: entry.reference)
            #expect(url.path.hasPrefix(moved.path))
            #expect(try VideoMediaLibrary.identity(of: url) == entry.source.identity)
        }
        #expect(
            try JSONDecoder().decode(
                VideoMediaLibrary.PackageResult.self, from: JSONEncoder().encode(result)) == result)
    }

    @Test func packageCollisionMissingMediaAndCancellationLeaveNoPartialFolder() throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("large.mov")
        try Data(repeating: 3, count: 3_000_000).write(to: source)
        var project = VideoProject.create()
        project.addAsset(source, duration: 1, width: 1, height: 1)
        let destination = folder.appendingPathComponent("package")
        var cancelledDuringCopy = false
        #expect(throws: CancellationError.self) {
            try project.packageOriginalMedia(
                to: destination,
                checkCancellation: {
                    let stages = try FileManager.default.contentsOfDirectory(
                        at: folder, includingPropertiesForKeys: nil
                    )
                    .filter { $0.lastPathComponent.hasPrefix(".media-stage-") }
                    if let stage = stages.first {
                        let files = try FileManager.default.contentsOfDirectory(
                            at: stage.appendingPathComponent("originals"),
                            includingPropertiesForKeys: nil)
                        if let first = files.first,
                            (try FileManager.default.attributesOfItem(atPath: first.path)[.size]
                                as? NSNumber)?.intValue ?? 0 > 0
                        {
                            cancelledDuringCopy = true
                            throw CancellationError()
                        }
                    }
                })
        }
        #expect(cancelledDuringCopy)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["large.mov"])
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        let sentinel = try file(destination, "keep", "untouched")
        #expect(throws: VideoMediaLibrary.Failure.self) {
            try project.packageOriginalMedia(to: destination)
        }
        #expect(try String(contentsOf: sentinel, encoding: .utf8) == "untouched")
        try FileManager.default.removeItem(at: source)
        #expect(throws: (any Error).self) {
            try project.packageOriginalMedia(to: folder.appendingPathComponent("missing"))
        }
        #expect(
            !FileManager.default.fileExists(atPath: folder.appendingPathComponent("missing").path))
    }

    @Test func strictRelinkRecoversMissingMediaAndRejectsChangedBytes() throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = try file(folder, "original.mov", "original")
        let same = try file(folder, "same.mov", "original")
        let other = try file(folder, "other.mov", "different")
        var project = VideoProject.create()
        project.addAsset(original, duration: 3, width: 10, height: 10)
        let reference = VideoMediaLibrary.Reference(assetID: project.assets[0].id, role: .original)
        let provenance = VideoMediaLibrary.Provenance(
            sourceFamilyID: "session-1", declaration: "Original camera recording")
        try project.indexMedia(provenanceByAssetID: [reference.assetID: provenance])
        try FileManager.default.removeItem(at: original)
        #expect(throws: VideoMediaLibrary.Failure.self) {
            try project.relinkOriginalMedia(reference, to: other)
        }
        #expect(project.assets[0].url == original)
        let result = try project.relinkOriginalMedia(reference, to: same)
        #expect(!result.contentChanged)
        #expect(try project.mediaManifest().entries[0].source.provenance == provenance)
        #expect(project.assets[0].url == same)
        let replaced = try project.relinkOriginalMedia(
            reference, to: other, policy: .allowReplacement)
        #expect(replaced.contentChanged)
        #expect(try project.mediaManifest().entries[0].source.provenance == nil)
        #expect(try project.mediaManifest().entries[0].packagedPath == nil)
    }

    @Test func missingUnindexedRelinkRequiresAnExpectedIdentityOrExplicitReplacement() throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let same = try file(folder, "same.mov", "original")
        var project = VideoProject.create()
        project.addAsset(
            folder.appendingPathComponent("missing.mov"), duration: 1, width: 1, height: 1)
        let reference = VideoMediaLibrary.Reference(assetID: project.assets[0].id, role: .original)
        #expect(throws: (any Error).self) { try project.relinkOriginalMedia(reference, to: same) }
        let expected = try VideoMediaLibrary.identity(of: same)
        #expect(
            try project.relinkOriginalMedia(reference, to: same, expectedIdentity: expected)
                .identity == expected)
    }

    @Test func indexedMutationAndTamperedPackageFailValidation() throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = try file(folder, "original.mov", "original")
        var project = VideoProject.create()
        project.addAsset(source, duration: 1, width: 1, height: 1)
        try project.indexMedia()
        let result = try project.packageOriginalMedia(to: folder.appendingPathComponent("package"))
        let packaged = try VideoProject.openMediaPackage(result.directory).assets[0].url
        try Data("modified".utf8).write(to: packaged)
        #expect(throws: VideoMediaLibrary.Failure.self) {
            try VideoProject.openMediaPackage(result.directory)
        }
        try Data("modified".utf8).write(to: source)
        #expect(throws: VideoMediaLibrary.Failure.self) { try project.indexMedia() }
        #expect(throws: VideoMediaLibrary.Failure.self) {
            try project.packageOriginalMedia(to: folder.appendingPathComponent("other"))
        }
    }

    @Test func packageCommitNeverOverwritesARacingDestination() throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = try file(folder, "original.mov", "original")
        var project = VideoProject.create()
        project.addAsset(source, duration: 1, width: 1, height: 1)
        let destination = folder.appendingPathComponent("package")
        var raced = false
        #expect(throws: VideoMediaLibrary.Failure.self) {
            try project.packageOriginalMedia(
                to: destination,
                checkCancellation: {
                    let stages = try FileManager.default.contentsOfDirectory(
                        at: folder, includingPropertiesForKeys: nil
                    )
                    .filter { $0.lastPathComponent.hasPrefix(".media-stage-") }
                    if !raced, let stage = stages.first,
                        FileManager.default.fileExists(
                            atPath: stage.appendingPathComponent("project.openscreen").path)
                    {
                        try FileManager.default.createDirectory(
                            at: destination, withIntermediateDirectories: false)
                        _ = try file(destination, "keep", "winner")
                        raced = true
                    }
                })
        }
        #expect(raced)
        #expect(
            try String(contentsOf: destination.appendingPathComponent("keep"), encoding: .utf8)
                == "winner")
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() == [
                "original.mov", "package",
            ])
    }

    @Test func packageRejectsSymlinksThatEscapeItsOriginalsFolder() throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = try file(folder, "original.mov", "original")
        var project = VideoProject.create()
        project.addAsset(source, duration: 1, width: 1, height: 1)
        let result = try project.packageOriginalMedia(to: folder.appendingPathComponent("package"))
        let packaged = try VideoProject.openMediaPackage(result.directory).assets[0].url
        try FileManager.default.removeItem(at: packaged)
        try FileManager.default.createSymbolicLink(at: packaged, withDestinationURL: source)
        #expect(throws: VideoMediaLibrary.Failure.self) {
            try VideoProject.openMediaPackage(result.directory)
        }
    }

    @Test(arguments: [false, true])
    func concurrentLedgerAliasCannotBypassTheCanonicalReservation(parentAlias: Bool) async throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = VideoMediaLibrary.Source(
            identity: try VideoMediaLibrary.identity(of: file(folder, "source", "same")))
        let url = folder.appendingPathComponent("ledger.json")
        let link = folder.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(
            at: link, withDestinationURL: parentAlias ? folder : url)
        let alias = parentAlias ? link.appendingPathComponent("ledger.json") : link
        let receipts = await withTaskGroup(of: VideoMediaLibrary.Reservation?.self) { group in
            for index in 0..<16 {
                group.addTask {
                    try? VideoMediaLibrary.Ledger(url: index.isMultiple(of: 2) ? url : alias)
                        .reserve([source], reelID: "reel-\(index)")
                }
            }
            var result: [VideoMediaLibrary.Reservation] = []
            for await receipt in group { if let receipt { result.append(receipt) } }
            return result
        }
        #expect(receipts.count == 1)
        #expect(try VideoMediaLibrary.Ledger(url: url).reservations() == receipts)
        #expect(
            try FileManager.default.destinationOfSymbolicLink(atPath: link.path)
                == (parentAlias ? folder : url).path)
    }

    @Test func packagePreservesProcessedAudioWallpaperAndBothAnnotationImageFields() throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let sources = folder.appendingPathComponent("sources")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: false)
        let video = try file(sources, "video.mov", "video")
        let processed = try file(sources, "clean.wav", "clean audio")
        let wallpaper = try file(sources, "wallpaper.png", "wallpaper")
        let image = try file(sources, "overlay.png", "overlay")
        let fallback = try file(sources, "fallback.jpg", "fallback")
        var project = VideoProject.create()
        project.addAsset(video, duration: 1, width: 10, height: 10)
        var assets = project.assets.map(\.raw)
        assets[0]["edithAudioPath"] = processed.path
        project.root["assets"] = assets
        project.backgroundColor = wallpaper.path
        project.addOverlay(type: "image", startMs: 0, endMs: 1000, x: 0, y: 0, content: image.path)
        var annotations = project.annotations.map(\.raw)
        annotations[0]["content"] = fallback.absoluteString
        project.root["annotations"] = annotations
        project.addOverlay(
            type: "image", startMs: 0, endMs: 1000, x: 0, y: 0,
            content: "data:image/png;base64,c3ludGhldGlj")
        project.addOverlay(type: "image", startMs: 0, endMs: 1000, x: 0, y: 0, content: "#ffffff")
        let result = try project.packageOriginalMedia(to: folder.appendingPathComponent("package"))
        #expect(result.copiedFileCount == 5)
        #expect(
            Set(result.manifest.entries.map(\.reference.role)) == [
                .original, .processedAudio, .wallpaper, .annotationImage, .annotationContent,
            ])
        try FileManager.default.removeItem(at: sources)
        let reopened = try VideoProject.openMediaPackage(result.directory)
        #expect(
            try String(
                contentsOfFile: reopened.assets[0].raw["edithAudioPath"] as! String, encoding: .utf8
            ) == "clean audio")
        #expect(
            try String(contentsOfFile: reopened.backgroundColor, encoding: .utf8) == "wallpaper")
        #expect(
            try String(
                contentsOfFile: reopened.annotations[0].raw["imageContent"] as! String,
                encoding: .utf8) == "overlay")
        #expect(
            try String(
                contentsOfFile: reopened.annotations[0].raw["content"] as! String, encoding: .utf8)
                == "fallback")
        #expect(
            reopened.annotations[1].raw["imageContent"] as? String
                == "data:image/png;base64,c3ludGhldGlj")
        #expect(reopened.annotations[2].raw["content"] as? String == "#ffffff")
        let cleaned = try reopened.mediaURL(
            for: .init(assetID: reopened.assets[0].id, role: .processedAudio))
        try Data("tampered".utf8).write(to: cleaned)
        #expect(throws: VideoMediaLibrary.Failure.self) {
            try VideoProject.openMediaPackage(result.directory)
        }
    }

    @Test func identicalVideosWithDifferentCursorTelemetryKeepDistinctAssociations() throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let sources = folder.appendingPathComponent("sources")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: false)
        let first = try file(sources, "first.mov", "identical video")
        let second = try file(sources, "second.mov", "identical video")
        let third = try file(sources, "third.mov", "identical video")
        let a =
            "{\"samples\":[{\"timeMs\":200,\"cx\":0.2,\"cy\":0.3,\"interactionType\":\"click\"}]}"
        let b =
            "{\"samples\":[{\"timeMs\":500,\"cx\":0.8,\"cy\":0.7,\"interactionType\":\"click\"}]}"
        _ = try file(sources, "first.mov.cursor.json", a)
        _ = try file(sources, "second.mov.cursor.json", b)
        var project = VideoProject.create()
        for video in [first, second, third] {
            project.addAsset(video, duration: 1, width: 10, height: 10)
        }
        let result = try project.packageOriginalMedia(to: folder.appendingPathComponent("package"))
        #expect(result.copiedFileCount == 5)
        #expect(result.manifest.entries.filter { $0.reference.role == .cursor }.count == 2)
        let moved = folder.appendingPathComponent("moved")
        try FileManager.default.moveItem(at: result.directory, to: moved)
        try FileManager.default.removeItem(at: sources)
        var reopened = try VideoProject.openMediaPackage(moved)
        #expect(Set(reopened.assets.map(\.url)).count == 3)
        #expect(
            try String(
                contentsOfFile: reopened.assets[0].url.path + ".cursor.json", encoding: .utf8) == a)
        #expect(
            try String(
                contentsOfFile: reopened.assets[1].url.path + ".cursor.json", encoding: .utf8) == b)
        #expect(
            !FileManager.default.fileExists(atPath: reopened.assets[2].url.path + ".cursor.json"))
        #expect(reopened.addAutomaticZooms() == 2)
        #expect(reopened.zooms.map(\.focusX) == [0.2, 0.8])
        let cursor = URL(fileURLWithPath: reopened.assets[0].url.path + ".cursor.json")
        try Data(b.utf8).write(to: cursor)
        #expect(throws: VideoMediaLibrary.Failure.self) { try VideoProject.openMediaPackage(moved) }
        try FileManager.default.removeItem(at: cursor)
        #expect(throws: (any Error).self) { try reopened.indexMedia() }
    }

    @Test(arguments: [false, true])
    func strictOriginalRelinkAlsoValidatesAssociatedTelemetry(indexed: Bool) throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = try file(folder, "first.mov", "same")
        let second = try file(folder, "second.mov", "same")
        _ = try file(folder, "first.mov.cursor.json", "first telemetry")
        let otherCursor = try file(folder, "second.mov.cursor.json", "different telemetry")
        var project = VideoProject.create()
        project.addAsset(first, duration: 1, width: 1, height: 1)
        if indexed { try project.indexMedia() }
        let reference = VideoMediaLibrary.Reference(assetID: project.assets[0].id, role: .original)
        #expect(throws: VideoMediaLibrary.Failure.self) {
            try project.relinkOriginalMedia(reference, to: second)
        }
        #expect(project.assets[0].url == first)
        try FileManager.default.removeItem(at: otherCursor)
        #expect(throws: (any Error).self) { try project.relinkOriginalMedia(reference, to: second) }
        try Data("first telemetry".utf8).write(to: otherCursor)
        #expect(try !project.relinkOriginalMedia(reference, to: second).contentChanged)
    }

    @Test func replacingOriginalClearsDerivedAudio() throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        var project = VideoProject.create()
        project.addAsset(try file(folder, "old.mov", "old"), duration: 1, width: 1, height: 1)
        var assets = project.assets.map(\.raw)
        assets[0]["edithAudioPath"] = try file(folder, "clean.wav", "old audio").path
        project.root["assets"] = assets
        try project.indexMedia()
        try project.relinkOriginalMedia(
            .init(assetID: project.assets[0].id, role: .original),
            to: file(folder, "new.mov", "new"), policy: .allowReplacement)
        #expect(project.assets[0].raw["edithAudioPath"] == nil)
        #expect(
            try !project.mediaManifest().entries.contains { $0.reference.role == .processedAudio })
    }

    @Test(arguments: [0, 1, 2])
    func unindexedReplacementComparesReadableOriginalBeforeClearingAudio(mode: Int) throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = try file(folder, "original.mov", "same")
        let copy = try file(folder, "copy.mov", "same")
        let audio = try file(folder, "clean.wav", "derived")
        var project = VideoProject.create()
        project.addAsset(original, duration: 1, width: 1, height: 1)
        var assets = project.assets.map(\.raw)
        assets[0]["edithAudioPath"] = audio.path
        project.root["assets"] = assets
        if mode == 2 { try FileManager.default.removeItem(at: original) }
        let result = try project.relinkOriginalMedia(
            .init(assetID: project.assets[0].id, role: .original),
            to: mode == 0 ? original : copy, policy: .allowReplacement)
        #expect(result.contentChanged == (mode == 2))
        #expect(
            project.assets[0].raw["edithAudioPath"] as? String == (mode == 2 ? nil : audio.path))
    }

    @Test func subsecondCaptureOrderPrecedesOpposingHashOrder() {
        func media(_ fraction: String, hash: String, digitized: Bool = false)
            -> VideoMediaLibrary.InspectedMedia
        {
            let field = digitized ? "Digitized" : "Original"
            let capture = VideoMediaLibrary.captureDate(exif: [
                "DateTime\(field)": "2020:01:01 00:00:00",
                "OffsetTime\(field)": "+00:00", "SubsecTime\(field)": fraction,
            ])
            return .init(
                url: URL(fileURLWithPath: "/synthetic/\(fraction).jpg"),
                source: .init(
                    identity: .init(sha256: String(repeating: hash, count: 64), byteCount: 1)),
                metadata: .init(
                    duration: nil, video: [], audio: [], image: nil, captureDate: capture))
        }
        let early = media("100", hash: "f")
        let late = media("900", hash: "0")
        #expect(early.source.identity.sha256 > late.source.identity.sha256)
        #expect(VideoMediaLibrary.chronologicalOrder([late, early]) == [early, late])
        #expect(early.metadata.captureDate.rawValues.contains("100"))
        #expect(
            media("900", hash: "0", digitized: true).metadata.captureDate.utc
                == "2020-01-01T00:00:00.900Z")
        #expect(
            media("1000001", hash: "0").metadata.captureDate.utc == "2020-01-01T00:00:00.1000001Z")
        #expect(
            VideoMediaLibrary.chronologicalOrder([media("1000001", hash: "0"), early]).first
                == early)
    }

    private func image(_ folder: URL, name: String, exif: [String: Any]) throws -> URL {
        let url = folder.appendingPathComponent(name)
        let context = try #require(
            CGContext(
                data: nil, width: 2, height: 2, bitsPerComponent: 8,
                bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let image = try #require(context.makeImage())
        let output = try #require(
            CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(
            output, image, [kCGImagePropertyExifDictionary: exif] as CFDictionary)
        try #require(CGImageDestinationFinalize(output))
        return url
    }

    @Test func captureDatesNormalizeOffsetsAndSortDeterministically() async throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let sources = folder.appendingPathComponent("sources")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: false)
        let a = try image(
            sources, name: "a.jpg",
            exif: [
                "DateTimeOriginal": "2020:02:29 10:00:00", "OffsetTimeOriginal": "+05:30",
                "DateTimeDigitized": "2026:01:01 00:00:00", "SubsecTimeOriginal": "100",
            ])
        let b = try image(
            sources, name: "b.jpg",
            exif: ["DateTimeOriginal": "2020:02:28 23:00:00", "OffsetTimeOriginal": "-06:00"])
        let unknown = try image(sources, name: "unknown.jpg", exif: [:])
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 0)], ofItemAtPath: unknown.path)
        let first = try await VideoMediaLibrary.inspect(a)
        let second = try await VideoMediaLibrary.inspect(b)
        let missing = try await VideoMediaLibrary.inspect(unknown)
        #expect(first.metadata.captureDate.utc == "2020-02-29T04:30:00.100Z")
        #expect(second.metadata.captureDate.utc == "2020-02-29T05:00:00.000Z")
        #expect(first.metadata.captureDate.source == "exif.DateTimeOriginal")
        #expect(first.metadata.captureDate.offsetMinutes == 330)
        #expect(first.metadata.captureDate.timezone == .explicitOffset)
        #expect(missing.metadata.captureDate.source == nil)
        #expect(missing.metadata.captureDate.utc == nil)
        #expect(
            VideoMediaLibrary.chronologicalOrder([missing, second, first]).map(\.url) == [
                a, b, unknown,
            ])
        #expect(
            VideoMediaLibrary.chronologicalOrder([second, missing, first])
                == VideoMediaLibrary.chronologicalOrder([missing, first, second]))
        #expect(
            try JSONDecoder().decode(
                VideoMediaLibrary.Metadata.self, from: JSONEncoder().encode(first.metadata))
                == first.metadata)
        var project = VideoProject.create()
        project.addAsset(a, duration: 1, width: 2, height: 2)
        project.backgroundColor = b.path
        let package = try project.packageOriginalMedia(to: folder.appendingPathComponent("package"))
        try FileManager.default.removeItem(at: sources)
        let moved = folder.appendingPathComponent("moved")
        try FileManager.default.moveItem(at: package.directory, to: moved)
        let reopened = try VideoProject.openMediaPackage(moved)
        #expect(try await VideoMediaLibrary.probe(reopened.assets[0].url).image?.width == 2)
        #expect(
            try await VideoMediaLibrary.probe(URL(fileURLWithPath: reopened.backgroundColor))
                .captureDate == second.metadata.captureDate)
    }

    @Test func captureDatesPreserveUnknownInvalidAndConflictingValues() {
        let key = AVMetadataIdentifier.quickTimeMetadataCreationDate.rawValue
        let original = "mdta/com.apple.quicktime.original_creation_time"
        let export = [key: ["2026-09-29T12:00:00Z"]]
        let unknown = VideoMediaLibrary.captureDate(
            exif: ["DateTimeOriginal": "2020:02:29 10:00:00"], quickTime: export)
        #expect(unknown.utc == nil)
        #expect(unknown.timezone == .unknown)
        #expect(unknown.isOriginalMetadata)
        for value in ["invalid", "2020:02:30 10:00:00", "2020:01:01 25:00:00"] {
            #expect(
                VideoMediaLibrary.captureDate(exif: ["DateTimeOriginal": value], quickTime: export)
                    .timezone == .invalid)
        }
        #expect(
            VideoMediaLibrary.captureDate(exif: [
                "DateTimeOriginal": "2020:01:01 00:00:00", "OffsetTimeOriginal": "+25:00",
            ]).timezone == .invalid)
        let selected = VideoMediaLibrary.captureDate(
            quickTime: export.merging([original: ["2020-01-01T02:00:00+0200"]]) { $1 })
        #expect(selected.utc == "2020-01-01T00:00:00.000Z")
        #expect(selected.isOriginalMetadata)
        #expect(!VideoMediaLibrary.captureDate(quickTime: export).isOriginalMetadata)
        #expect(
            VideoMediaLibrary.captureDate(quickTime: [key: ["2020-01-01T00:00:00-00:00"]]).timezone
                == .unknown)
        #expect(
            VideoMediaLibrary.captureDate(quickTime: [key: ["a", "b"]]).timezone == .conflicting)
    }

    @Test func probesActualVideoCodecDimensionsTransformAndFrameRate() async throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("portrait.mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        writer.metadata = [
            (AVMetadataIdentifier.quickTimeMetadataCreationDate, "2026-01-01T00:00:00Z"),
            (
                AVMetadataIdentifier(rawValue: "mdta/com.apple.quicktime.original_creation_time"),
                "2020-01-01T02:00:00+0200"
            ),
        ].map { identifier, date in
            let item = AVMutableMetadataItem()
            item.identifier = identifier
            item.value = date as NSString
            item.dataType = kCMMetadataBaseDataType_UTF8 as String
            return item
        }
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 32,
            ])
        input.transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 32, ty: 0)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 32,
            ])
        writer.add(input)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        var buffer: CVPixelBuffer?
        #expect(
            CVPixelBufferCreate(
                kCFAllocatorDefault, 64, 32, kCVPixelFormatType_32ARGB, nil, &buffer)
                == kCVReturnSuccess)
        let pixels = try #require(buffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        memset(CVPixelBufferGetBaseAddress(pixels), 0, CVPixelBufferGetDataSize(pixels))
        CVPixelBufferUnlockBaseAddress(pixels, [])
        for frame in 0..<3 {
            let deadline = Date().addingTimeInterval(5)
            while !input.isReadyForMoreMediaData, writer.status == .writing, Date() < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            try #require(input.isReadyForMoreMediaData)
            #expect(
                adaptor.append(
                    pixels, withPresentationTime: CMTime(value: Int64(frame), timescale: 24)))
        }
        writer.endSession(atSourceTime: CMTime(value: 3, timescale: 24))
        input.markAsFinished()
        await writer.finishWriting()
        #expect(writer.status == .completed)
        var project = VideoProject.create()
        project.addAsset(url, duration: 0.125, width: 999, height: 999)
        let manifest = try await project.inspectMedia()
        #expect(manifest.entries.first?.metadata?.captureDate.utc == "2020-01-01T00:00:00.000Z")
        #expect(manifest.entries.first?.metadata?.captureDate.isOriginalMetadata == true)
        let metadata = try #require(manifest.entries.first?.metadata?.video.first)
        #expect(metadata.codecs == ["avc1"])
        #expect(metadata.width == 64)
        #expect(metadata.height == 32)
        #expect(metadata.displayWidth == 32)
        #expect(metadata.displayHeight == 64)
        #expect(metadata.transform == [0, 1, -1, 0, 32, 0])
        #expect(abs(metadata.nominalFrameRate - 24) < 0.1)
    }
}
