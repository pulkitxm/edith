import AVFoundation
import Foundation
import Testing
@testable import Edith

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
        let image = try file(sources, "still.png", "image bytes")
        var project = VideoProject.create(title: "Synthetic reel")
        project.root["customSetting"] = ["keep": 42]
        project.addAsset(original, duration: 5, width: 100, height: 100, sourceImage: image)
        project.addAsset(copy, duration: 5, width: 100, height: 100)
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
        #expect(reopened.clips.map(\.duration) == [5, 5])
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
            try project.packageOriginalMedia(to: destination) {
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
            }
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

    @Test func probesActualVideoCodecDimensionsTransformAndFrameRate() async throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("portrait.mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
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
