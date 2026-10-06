import AVFoundation
import EdithCore
import Foundation

struct TimeLapseRecording: Identifiable, Sendable {
    let session: TimeLapseSession
    let directory: URL
    var id: UUID { session.id }

    static func load(in root: URL) throws -> [Self] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        let directories = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        return directories.compactMap { directory in
            guard
                let data = try? Data(contentsOf: directory.appendingPathComponent("session.json")),
                let session = try? JSONDecoder().decode(TimeLapseSession.self, from: data),
                (try? session.validate()) != nil
            else { return nil }
            return Self(session: session, directory: directory)
        }.sorted { $0.session.startedAt > $1.session.startedAt }
    }
}

enum TimeLapseExportQuality: String, CaseIterable, Identifiable, Sendable {
    case compact = "Compact HEVC, up to 1080p"
    case high = "High quality HEVC, recorded resolution"
    case original = "Original video, no re-encoding"
    case editing = "ProRes 422, for editing"
    var id: String { rawValue }
    var preset: String {
        switch self {
        case .compact: AVAssetExportPresetHEVC1920x1080
        case .high: AVAssetExportPresetHEVCHighestQuality
        case .original: AVAssetExportPresetPassthrough
        case .editing: AVAssetExportPresetAppleProRes422LPCM
        }
    }
    var fileType: AVFileType { self == .editing ? .mov : .mp4 }
    var fileExtension: String { self == .editing ? "mov" : "mp4" }
}

enum TimeLapseExporter {
    static func composition(_ recording: TimeLapseRecording) async throws
        -> AVMutableComposition
    {
        try recording.session.validate()
        let composition = AVMutableComposition()
        let segments = recording.session.segments.filter { $0.kind == "video" }.sorted {
            $0.file < $1.file
        }
        guard let first = segments.first else { throw TimeLapseError.empty }
        try await append(recording, kind: "video", to: composition, origin: first.startedAt)
        do {
            let duration = composition.duration
            for audio in ["system", "microphone"] {
                if recording.session.segments.contains(where: { $0.kind == audio }) {
                    try await append(
                        recording, kind: audio, to: composition, origin: first.startedAt,
                        limit: duration, speed: recording.session.settings.speed)
                }
            }
        }
        return composition
    }

    private static func append(
        _ recording: TimeLapseRecording, kind: String,
        to composition: AVMutableComposition, origin: Date, limit: CMTime? = nil, speed: Double = 1
    ) async throws {
        let segments = recording.session.segments.filter { $0.kind == kind }.sorted {
            $0.file < $1.file
        }
        let mediaType: AVMediaType = kind == "video" ? .video : .audio
        guard
            let destination = composition.addMutableTrack(
                withMediaType: mediaType,
                preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw TimeLapseError.empty }
        var offset = CMTime.zero
        for segment in segments {
            try Task.checkCancellation()
            let url = recording.directory.appendingPathComponent(segment.file)
                .resolvingSymlinksInPath()
            guard
                url.deletingLastPathComponent().path
                    == recording.directory.resolvingSymlinksInPath().path
            else { throw TimeLapseError.invalidSession }
            let asset = AVURLAsset(url: url)
            guard let track = try await asset.loadTracks(withMediaType: mediaType).first else {
                throw TimeLapseError.encoding(
                    "A saved recording segment is missing its media track.")
            }
            var range = try await track.load(.timeRange)
            guard range.duration.isNumeric, range.duration.seconds > 0 else {
                throw TimeLapseError.empty
            }
            if kind != "video" || recording.session.settings.mode == .standard {
                let start = segment.startedAt.timeIntervalSince(origin)
                if start < 0 {
                    let trim = CMTime(seconds: -start, preferredTimescale: 60000)
                    range.start = CMTimeAdd(range.start, trim)
                    range.duration = CMTimeSubtract(range.duration, trim)
                }
                offset = CMTime(seconds: max(offset.seconds, start), preferredTimescale: 60000)
            }
            if let limit {
                range.duration = CMTimeMinimum(
                    range.duration,
                    CMTimeSubtract(CMTimeMultiplyByFloat64(limit, multiplier: speed), offset))
            }
            guard range.duration.seconds > 0 else { continue }
            try destination.insertTimeRange(range, of: track, at: offset)
            offset = CMTimeAdd(offset, range.duration)
        }
        if destination.segments.isEmpty {
            composition.removeTrack(destination)
        } else if speed != 1 {
            let range = CMTimeRange(start: .zero, duration: destination.timeRange.end)
            destination.scaleTimeRange(
                range,
                toDuration: CMTimeMultiplyByFloat64(
                    range.duration,
                    multiplier: 1 / speed))
        }
    }

    @available(macOS 15.0, *)
    private static func mixAudio(
        in composition: AVMutableComposition, directory: URL, speed: Double
    ) async throws
        -> URL?
    {
        let tracks = try await composition.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty, tracks.count > 1 || speed != 1 else { return nil }
        let audio = AVMutableComposition()
        for track in tracks {
            guard
                let destination = audio.addMutableTrack(
                    withMediaType: .audio,
                    preferredTrackID: kCMPersistentTrackID_Invalid)
            else { throw TimeLapseError.empty }
            let range = try await track.load(.timeRange)
            try destination.insertTimeRange(range, of: track, at: range.start)
            if speed != 1 {
                let timeline = CMTimeRange(start: .zero, duration: destination.timeRange.end)
                destination.scaleTimeRange(
                    timeline,
                    toDuration: CMTimeMultiplyByFloat64(timeline.duration, multiplier: speed))
            }
        }
        var temporary: [URL] = []
        var completed = false
        defer {
            for url in completed ? temporary.dropLast() : temporary[...] {
                try? FileManager.default.removeItem(at: url)
            }
        }
        var mixedURL = directory.appendingPathComponent(".\(UUID().uuidString).caf")
        temporary.append(mixedURL)
        try await writeAudioMix(audio, to: mixedURL)
        var remaining = speed
        while remaining > 1 {
            let factor = min(4, remaining)
            let next = directory.appendingPathComponent(".\(UUID().uuidString).caf")
            temporary.append(next)
            try await accelerateAudio(from: mixedURL, to: next, factor: factor)
            mixedURL = next
            remaining /= factor
        }
        let asset = AVURLAsset(url: mixedURL)
        guard let mixed = try await asset.loadTracks(withMediaType: .audio).first else {
            throw TimeLapseError.empty
        }
        for track in tracks { composition.removeTrack(track) }
        guard
            let destination = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw TimeLapseError.empty }
        var range = try await mixed.load(.timeRange)
        range.duration = CMTimeMinimum(range.duration, composition.duration)
        try destination.insertTimeRange(range, of: mixed, at: .zero)
        completed = true
        return mixedURL
    }

    private static func writeAudioMix(_ composition: AVComposition, to url: URL) async throws {
        let tracks = try await composition.loadTracks(withMediaType: .audio)
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: true)!
        let file = try AVAudioFile(
            forWriting: url, settings: format.settings,
            commonFormat: .pcmFormatFloat32, interleaved: true)
        let reader = try AVAssetReader(asset: composition)
        let output = AVAssetReaderAudioMixOutput(
            audioTracks: tracks,
            audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
            ])
        let mix = AVMutableAudioMix()
        mix.inputParameters = tracks.map { track in
            let parameters = AVMutableAudioMixInputParameters(track: track)
            parameters.setVolume(tracks.count > 1 ? 0.5 : 1, at: .zero)
            return parameters
        }
        output.audioMix = mix
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? TimeLapseError.empty }
        defer { reader.cancelReading() }
        let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096)!
        let silenceBytes = silence.mutableAudioBufferList.pointee.mBuffers
        memset(silenceBytes.mData!, 0, Int(silenceBytes.mDataByteSize))
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            let start = AVAudioFramePosition(
                (CMSampleBufferGetPresentationTimeStamp(sample).seconds * format.sampleRate)
                    .rounded())
            while file.length < start {
                try Task.checkCancellation()
                silence.frameLength = AVAudioFrameCount(min(4096, start - file.length))
                try file.write(from: silence)
            }
            let frames = CMSampleBufferGetNumSamples(sample)
            guard frames > 0, let block = CMSampleBufferGetDataBuffer(sample),
                let buffer = AVAudioPCMBuffer(
                    pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))
            else { throw TimeLapseError.empty }
            buffer.frameLength = AVAudioFrameCount(frames)
            let bytes = buffer.mutableAudioBufferList.pointee.mBuffers
            guard CMBlockBufferGetDataLength(block) == Int(bytes.mDataByteSize),
                CMBlockBufferCopyDataBytes(
                    block, atOffset: 0, dataLength: Int(bytes.mDataByteSize),
                    destination: bytes.mData!) == noErr
            else { throw TimeLapseError.empty }
            try file.write(from: buffer)
        }
        guard reader.status == .completed else { throw reader.error ?? TimeLapseError.empty }
    }

    private static func accelerateAudio(from source: URL, to destination: URL, factor: Double)
        async throws
    {
        let input = try AVAudioFile(forReading: source)
        let format = input.processingFormat
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let pitch = AVAudioUnitTimePitch()
        pitch.rate = Float(factor)
        engine.attach(player)
        engine.attach(pitch)
        engine.connect(player, to: pitch, format: format)
        engine.connect(pitch, to: engine.mainMixerNode, format: format)
        try engine.enableManualRenderingMode(
            .offline, format: format, maximumFrameCount: 4096)
        defer { engine.stop() }
        var settings = format.settings
        settings[AVLinearPCMIsNonInterleaved] = false
        let output = try AVAudioFile(forWriting: destination, settings: settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4096)!
        player.scheduleFile(input, at: nil, completionHandler: nil)
        try engine.start()
        player.play()
        let frames = AVAudioFramePosition((Double(input.length) / factor).rounded(.up))
        var stalled = 0
        while output.length < frames {
            try Task.checkCancellation()
            let count = AVAudioFrameCount(min(4096, frames - output.length))
            switch try engine.renderOffline(count, to: buffer) {
            case .success:
                guard buffer.frameLength > 0 else { throw TimeLapseError.empty }
                try output.write(from: buffer)
                stalled = 0
            case .cannotDoInCurrentContext, .insufficientDataFromInputNode:
                stalled += 1
                guard stalled <= 128 else {
                    throw TimeLapseError.encoding("Audio acceleration stopped producing samples.")
                }
                await Task.yield()
            case .error:
                throw TimeLapseError.encoding("Audio acceleration failed.")
            @unknown default:
                throw TimeLapseError.encoding("Audio acceleration is unavailable on this Mac.")
            }
        }
    }

    @available(macOS 15.0, *)
    static func export(
        _ recording: TimeLapseRecording, quality: TimeLapseExportQuality,
        to destination: URL
    ) async throws {
        let composition = try await composition(recording)
        let mixedAudio = try await mixAudio(
            in: composition,
            directory: destination.deletingLastPathComponent(),
            speed: recording.session.settings.speed)
        defer { if let mixedAudio { try? FileManager.default.removeItem(at: mixedAudio) } }
        let preset = quality.preset
        guard let export = AVAssetExportSession(asset: composition, presetName: preset) else {
            throw TimeLapseError.encoding("This Mac does not support the selected export quality.")
        }
        let fileType = quality.fileType
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(
            ".\(UUID().uuidString).partial")
        defer { try? FileManager.default.removeItem(at: temporary) }
        export.shouldOptimizeForNetworkUse = true
        try await export.export(to: temporary, as: fileType)
        try Task.checkCancellation()
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: destination)
        }
    }
}
