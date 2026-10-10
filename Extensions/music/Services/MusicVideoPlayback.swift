import AVFoundation
import AppKit
import Foundation

@MainActor final class MusicVideoPlayback {
    let track: Track
    let player: AVPlayer
    private let generator: AVAssetImageGenerator
    private var stopped = false
    private(set) var duration = 0.0
    private var load: Task<Void, Never>?

    init(track: Track, position: Double, playing: Bool, volume: Double) {
        self.track = track
        let asset = AVURLAsset(url: track.url)
        player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        player.volume = Float(volume)
        generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1280, height: 720)
        if position > 0 { player.seek(to: CMTime(seconds: position, preferredTimescale: 600)) }
        if playing { player.play() }
        load = Task { [weak self] in
            guard let value = try? await asset.load(.duration), !Task.isCancelled else { return }
            self?.duration = value.seconds.isFinite ? max(0, value.seconds) : 0
        }
    }

    var playing: Bool { player.timeControlStatus != .paused }
    var elapsed: Double {
        let value = player.currentTime().seconds
        return value.isFinite ? max(0, value) : 0
    }
    var volume: Double { Double(player.volume) }
    func toggle() { if playing { player.pause() } else { player.play() } }
    func pause() { player.pause() }
    func resume() { player.play() }
    func seek(_ fraction: Double) {
        player.seek(to: CMTime(seconds: fraction * duration, preferredTimescale: 600))
    }
    func setVolume(_ value: Double) { player.volume = Float(value) }

    func frame() async throws -> Data {
        guard !stopped else { throw CancellationError() }
        let value = try await generator.image(at: CMTime(seconds: elapsed, preferredTimescale: 600))
        try Task.checkCancellation()
        guard !stopped,
            let data = NSBitmapImageRep(cgImage: value.image).representation(
                using: .jpeg, properties: [.compressionFactor: 0.7]), data.count <= 1_048_576
        else { throw CancellationError() }
        return data
    }

    func stop() {
        guard !stopped else { return }
        stopped = true; load?.cancel(); load = nil
        generator.cancelAllCGImageGeneration()
        player.pause(); player.replaceCurrentItem(with: nil)
    }
}
