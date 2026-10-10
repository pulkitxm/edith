import AVFoundation
import AVKit
import CoreVideo
import EdithExtensionCommands
import EdithExtensionSupport
import Foundation
import Testing

@testable import MusicEmbeddedUI
@testable import MusicExtension

@MainActor @Suite(.serialized) struct MusicNativeVideoTests {
    private func movie(at url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 16, AVVideoHeightKey: 16,
            ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: 16, kCVPixelBufferHeightKey as String: 16,
            ])
        writer.add(input)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for index in 0..<3 {
            while !input.isReadyForMoreMediaData {
                try Task.checkCancellation()
                if let error = writer.error { throw error }
                try await Task.sleep(for: .milliseconds(10))
            }
            var buffer: CVPixelBuffer?
            #expect(
                CVPixelBufferCreate(
                    kCFAllocatorDefault, 16, 16, kCVPixelFormatType_32ARGB, nil, &buffer)
                    == kCVReturnSuccess)
            let pixels = try #require(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            memset(
                CVPixelBufferGetBaseAddress(pixels), Int32(32 + index * 40),
                CVPixelBufferGetDataSize(pixels))
            CVPixelBufferUnlockBaseAddress(pixels, [])
            #expect(
                adaptor.append(
                    pixels, withPresentationTime: CMTime(value: Int64(index), timescale: 2)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        #expect(writer.status == .completed)
    }

    @Test func realMovieMetadataCodecAndRangesUseOnlyTheOwnedEngineLease() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "music-video-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Mock Garden.mov")
        try await movie(at: url)
        let file = try Data(contentsOf: url)
        let engine = try MusicVideoPlayback(
            track: Track(url: url, relativePath: "Mock Garden.mov"), position: 0, playing: false,
            volume: 0.5)
        defer { engine.stop() }
        let lease = try JSONDecoder().decode(
            EmbeddedMusicVideoLease.self, from: JSONEncoder().encode(engine.lease))
        var requests: [MusicVideoRange] = []
        let invoke: (String, Data) async throws -> Data = { operation, payload in
            switch operation {
            case "music.ui.video.range":
                let request = try JSONDecoder().decode(MusicVideoRange.self, from: payload)
                requests.append(request)
                return try JSONEncoder().encode(await engine.read(request))
            case "music.ui.video.close": engine.stop(); return Data("{}".utf8)
            default: throw ExtensionPeerError.invalidRequest
            }
        }
        let loader = try EmbeddedMusicAssetLoader(lease: lease, invoke: invoke)
        defer { loader.stop() }
        let bytes = try await loader.read(offset: 0, count: min(262_144, file.count))
        #expect(bytes == file.prefix(bytes.count))
        let asset = loader.asset()
        let duration = try await asset.load(.duration)
        #expect(duration.seconds > 0)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let descriptions = try await #require(tracks.first).load(.formatDescriptions)
        #expect(
            descriptions.contains {
                CMFormatDescriptionGetMediaSubType($0) == kCMVideoCodecType_H264
            })
        #expect(!requests.isEmpty)
        #expect(requests.allSatisfy { $0.count <= 262_144 && $0.offset >= 0 && $0.id == lease.id })
        loader.stop(); await loader.drain()
        let presentationEngine = try MusicVideoPlayback(
            track: engine.track, position: 0, playing: false, volume: 0.5)
        let presentationLease = try JSONDecoder().decode(
            EmbeddedMusicVideoLease.self, from: JSONEncoder().encode(presentationEngine.lease))
        let session = try EmbeddedMusicVideoSession(lease: presentationLease) {
            operation, payload in
            if operation == "music.ui.video.range" {
                return try JSONEncoder().encode(
                    await presentationEngine.read(
                        JSONDecoder().decode(MusicVideoRange.self, from: payload)))
            }
            if operation == "music.ui.video.close" {
                presentationEngine.stop(); return Data("{}".utf8)
            }
            throw ExtensionPeerError.invalidRequest
        }
        let native = session.nativeView()
        #expect(native.player === session.player)
        #expect(native.controlsStyle == .floating)
        #expect(native.showsFullScreenToggleButton)
        #expect(native.allowsPictureInPicturePlayback)
        #expect(!native.updatesNowPlayingInfoCenter)
        #expect(session.player.rate == 0)
        session.stop(); native.player = nil
        await EmbeddedMusicVideoSession.drainAll()
        #expect(session.player.currentItem == nil)
        #expect(session.loader.stopped)
        #expect(session.stopped)
        #expect(native.window == nil)
        engine.stop()
        #expect(throws: (any Error).self) {
            try engine.report(
                .init(
                    id: lease.id, revision: lease.revision, elapsed: 0, duration: 1, playing: false,
                    volume: 0.5, controlRevision: 0))
        }
    }

    @Test func nativeReportsAndCLIControlShareTheEnginePreviewTimeline() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "music-video-cli-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let defaults = SharedDefaults.store
        let prior = [MusicStorage.musicFolderPathKey, "musicFolderExternalConfirmation"].map {
            defaults.object(forKey: $0)
        }
        defer {
            for (key, value) in zip(
                [MusicStorage.musicFolderPathKey, "musicFolderExternalConfirmation"], prior)
            { defaults.set(value, forKey: key) }
            TrackMeta.invalidateCaches(); try? FileManager.default.removeItem(at: root)
        }
        MusicStorage.setMusicDirectory(root)
        let url = root.appendingPathComponent("Mock Garden.mov")
        try await movie(at: url)
        let worker = MusicWorker(startImmediately: false)
        let service = MusicUIService(worker: worker)
        defer { service.stop(); worker.stop() }
        let lease = try JSONDecoder().decode(
            MusicVideoLease.self,
            from: await service.execute(
                "music.ui.video.open",
                payload: JSONEncoder().encode(
                    MusicUIAction(kind: .videoOpen, path: "Mock Garden.mov"))))
        _ = try await service.execute(
            "music.ui.video.update",
            payload: JSONEncoder().encode(
                MusicVideoReport(
                    id: lease.id, revision: lease.revision, elapsed: 0.5, duration: 1,
                    playing: false, volume: 0.5, controlRevision: 0)))
        let status = try JSONDecoder().decode(
            ExtensionCLIReply.self,
            from: await service.execute(
                "music.cli",
                payload: JSONEncoder().encode(
                    ExtensionCLIRequest(arguments: ["status", "--player", "builtin", "--json"]))))
        #expect(status.exitCode == 0)
        #expect(status.stdout.contains("Mock Garden.mov"))
        #expect(status.stdout.contains("0.5"))
        for arguments in [
            ["pause", "--player", "builtin"], ["seek", "0.25"],
            ["volume", "0.2", "--player", "builtin"],
        ] {
            let reply = try JSONDecoder().decode(
                ExtensionCLIReply.self,
                from: await service.execute(
                    "music.cli",
                    payload: JSONEncoder().encode(ExtensionCLIRequest(arguments: arguments))))
            #expect(reply.exitCode == 0)
        }
        let state = try JSONDecoder().decode(
            MusicUIState.self,
            from: await service.execute(
                "music.ui.read", payload: JSONEncoder().encode(MusicUIQuery())))
        #expect(state.playback.path == "Mock Garden.mov")
        #expect(state.playback.elapsed == 0.5)
        #expect(state.videoControl?.playing == false)
        #expect(state.videoControl?.volume == 0.2)
        #expect(state.videoControl?.seek == 0.25)
        #expect(state.videoControl?.revision == 3)
        service.stop()
        await #expect(throws: (any Error).self) {
            try await service.execute(
                "music.ui.video.range",
                payload: JSONEncoder().encode(
                    MusicVideoRange(
                        id: lease.id, revision: lease.revision, sequence: 1, offset: 0, count: 8)))
        }
    }

    @Test func canceledAndRevokedRangeRequestsNeverDeliverLateBytes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "music-video-cancel-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Mock.mov")
        try Data(repeating: 42, count: 1024).write(to: url)
        let engine = try MusicVideoPlayback(
            track: Track(url: url, relativePath: "Mock.mov"), position: 0, playing: false,
            volume: 0.5)
        defer { engine.stop() }
        let lease = try JSONDecoder().decode(
            EmbeddedMusicVideoLease.self, from: JSONEncoder().encode(engine.lease))
        let range = MusicVideoRange(
            id: lease.id, revision: lease.revision, sequence: 1, offset: 10, count: 8)
        #expect(try await engine.read(range).data == Data(repeating: 42, count: 8))
        await #expect(throws: (any Error).self) { try await engine.read(range) }
        for invalid in [
            MusicVideoRange(id: UUID(), revision: lease.revision, sequence: 2, offset: 0, count: 8),
            MusicVideoRange(id: lease.id, revision: UUID(), sequence: 2, offset: 0, count: 8),
            MusicVideoRange(
                id: lease.id, revision: lease.revision, sequence: 2, offset: -1, count: 8),
            MusicVideoRange(
                id: lease.id, revision: lease.revision, sequence: 2, offset: 0, count: 262_145),
        ] { await #expect(throws: (any Error).self) { try await engine.read(invalid) } }
        var pending: CheckedContinuation<Data, Error>?
        let loader = try EmbeddedMusicAssetLoader(lease: lease) { _, _ in
            try await withCheckedThrowingContinuation { pending = $0 }
        }
        let task = Task { try await loader.read(offset: 0, count: 8) }
        for _ in 0..<50 where pending == nil { await Task.yield() }
        #expect(pending != nil)
        loader.stop(); task.cancel()
        pending?.resume(
            returning: try JSONEncoder().encode(
                EmbeddedMusicVideoBytes(
                    id: lease.id, revision: lease.revision, sequence: 1, offset: 0,
                    data: Data(repeating: 42, count: 8))))
        await #expect(throws: CancellationError.self) { try await task.value }
        engine.stop()
        await #expect(throws: (any Error).self) {
            try await engine.read(
                .init(id: lease.id, revision: lease.revision, sequence: 2, offset: 0, count: 8))
        }
    }
}
