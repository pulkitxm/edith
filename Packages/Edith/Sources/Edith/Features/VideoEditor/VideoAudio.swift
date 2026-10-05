import AVFoundation
import EdithKit
import Foundation
import SwiftUI

struct VideoAudioEnvelope: Sendable {
    let peaks: [Float]
    let interval: Double
    let duration: Double

    func silence(threshold: Float = 0.01, minimum: Double = 0.5) -> [ClosedRange<Double>] {
        var result: [ClosedRange<Double>] = []
        var start: Int?
        for index in 0...peaks.count {
            if index < peaks.count, peaks[index] < threshold {
                if start == nil { start = index }
            } else if let first = start {
                let lower = Double(first) * interval + 0.08
                let upper = min(duration, Double(index) * interval) - 0.08
                if upper - lower >= minimum { result.append(lower...upper) }
                start = nil
            }
        }
        return result
    }

    static func read(_ url: URL) async throws -> VideoAudioEnvelope {
        let task = Task.detached(priority: .utility) {
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration).seconds
            guard duration.isFinite, duration > 0,
                let track = try await asset.loadTracks(withMediaType: .audio).first
            else {
                throw VideoRenderPipeline.RenderError.exportFailed(
                    "This source has no audio track.")
            }
            let interval = max(0.02, duration / 200_000)
            let bucketSize = max(1, Int(interval * 8000))
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(
                track: track,
                outputSettings: [
                    AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 8000,
                    AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 32,
                    AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
                ])
            reader.add(output)
            guard reader.startReading() else { throw reader.error ?? CancellationError() }
            defer { reader.cancelReading() }
            var peaks: [Float] = []
            var peak: Float = 0
            var count = 0
            while let sample = output.copyNextSampleBuffer() {
                try Task.checkCancellation()
                guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
                let length = CMBlockBufferGetDataLength(block)
                var samples = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
                let status = samples.withUnsafeMutableBytes {
                    CMBlockBufferCopyDataBytes(
                        block, atOffset: 0, dataLength: length, destination: $0.baseAddress!)
                }
                guard status == kCMBlockBufferNoErr else { continue }
                for value in samples {
                    peak = max(peak, abs(value))
                    count += 1
                    if count == bucketSize { peaks.append(peak); peak = 0; count = 0 }
                }
            }
            if count > 0 { peaks.append(peak) }
            if let error = reader.error { throw error }
            return VideoAudioEnvelope(
                peaks: peaks, interval: Double(bucketSize) / 8000, duration: duration)
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
}

actor VideoWaveformCache {
    static let shared = VideoWaveformCache()
    private var entries: [URL: VideoAudioEnvelope] = [:]

    func envelope(_ url: URL) async throws -> VideoAudioEnvelope {
        if let value = entries[url] { return value }
        let value = try await VideoAudioEnvelope.read(url)
        if entries.count >= 32 { entries.removeAll() }
        entries[url] = value
        return value
    }
}

struct VideoWaveform: View {
    let url: URL
    let start: Double
    let end: Double
    var loop = false
    @State private var envelope: VideoAudioEnvelope?

    var body: some View {
        Canvas { context, size in
            guard let envelope, !envelope.peaks.isEmpty, end > start else { return }
            var bars = Path()
            let count = max(1, min(2000, Int(size.width / 3)))
            for index in 0..<count {
                var time = start + (end - start) * Double(index) / Double(count)
                if loop, envelope.duration > 0 {
                    time.formTruncatingRemainder(dividingBy: envelope.duration)
                }
                let bucket = min(envelope.peaks.count - 1, max(0, Int(time / envelope.interval)))
                let height = max(
                    1, min(size.height, CGFloat(sqrt(envelope.peaks[bucket])) * size.height))
                bars.addRect(
                    CGRect(
                        x: Double(index) * size.width / Double(count),
                        y: (size.height - height) / 2, width: 1.5, height: height))
            }
            context.fill(bars, with: .color(.white.opacity(0.65)))
        }
        .allowsHitTesting(false)
        .pageTask(id: url) {
            let result = try? await VideoWaveformCache.shared.envelope(url)
            guard !Task.isCancelled else { return }
            envelope = result
        }
    }
}

enum VideoAudioProcessing {
    static func clean(_ source: URL, denoise: Bool) async throws -> URL {
        guard let executable = CLIToolEnvironment.executable(named: "ffmpeg") else {
            throw VideoRenderPipeline.RenderError.exportFailed(
                "Install FFmpeg in Extensions to use audio cleanup.")
        }
        let destination = VideoProject.libraryURL.appendingPathComponent("Audio", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let url = destination.appendingPathComponent("\(UUID().uuidString).m4a")
        let filter =
            (denoise ? "highpass=f=80,afftdn=nf=-25," : "") + "loudnorm=I=-16:TP=-1.5:LRA=11"
        do {
            let result = try await CLICommandRunner.runLocal(
                CLICommandRequest(
                    executableURL: executable,
                    arguments: [
                        "-nostdin", "-v", "error", "-i", source.path, "-vn", "-af", filter,
                        "-c:a", "aac", "-b:a", "192k", url.path,
                    ],
                    environment: CLIToolEnvironment.sanitized(), timeout: 1800,
                    maximumOutputBytes: 65536,
                    terminatesProcessGroup: true), onLine: { _ in })
            guard result.terminationStatus == 0 else {
                throw VideoRenderPipeline.RenderError.exportFailed(result.output)
            }
            return url
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }
}

extension VideoEditorModel {
    func processAudio(assetID: String, denoise: Bool) {
        guard audioTask == nil else { return }
        guard let project,
            let source = project.assets.first(where: { $0.id == assetID })
        else { return }
        audioStatus = denoise ? "Reducing noise and normalizing…" : "Normalizing to -16 LUFS…"
        audioTask = Task {
            defer { audioTask = nil; audioStatus = nil }
            do {
                let url = try await VideoAudioProcessing.clean(source.url, denoise: denoise)
                guard !Task.isCancelled, self.project?.id == project.id else { return }
                mutate { document in
                    var assets = document.assets.map(\.raw)
                    guard let index = assets.firstIndex(where: { $0["id"] as? String == assetID })
                    else { return }
                    assets[index]["edithAudioPath"] = url.path
                    document.root["assets"] = assets
                }
                rebuild()
            } catch {
                if !Task.isCancelled { errorMessage = error.localizedDescription }
            }
        }
    }

    func detectSilence() {
        guard audioTask == nil else { return }
        guard let project,
            let clip = project.clips.first(where: { $0.id == selectedClipID }),
            let source = project.assets.first(where: { $0.id == clip.assetID })
        else { return }
        audioStatus = "Finding quiet sections…"
        audioTask = Task {
            defer { audioTask = nil; audioStatus = nil }
            do {
                let envelope = try await VideoWaveformCache.shared.envelope(source.url)
                guard !Task.isCancelled, self.project?.id == project.id, selectedClipID == clip.id
                else { return }
                silenceClipID = clip.id
                silentRanges = envelope.silence().compactMap {
                    let lower = max(clip.start, $0.lowerBound)
                    let upper = min(clip.end, $0.upperBound)
                    return upper - lower >= 0.1 ? lower...upper : nil
                }
            } catch { if !Task.isCancelled { errorMessage = error.localizedDescription } }
        }
    }

    func removeSilence() {
        guard let id = silenceClipID, id == selectedClipID else { return }
        mutate { document in
            for range in silentRanges {
                document.addTrim(clipID: id, start: range.lowerBound, end: range.upperBound)
            }
        }
        silentRanges = []
        rebuild()
    }

    func setClipAudio(gain: Double? = nil, muted: Bool? = nil) {
        guard let selectedClipID else { return }
        mutate { $0.setClipAudio(clipID: selectedClipID, gain: gain, muted: muted) }
        rebuild()
    }
}
