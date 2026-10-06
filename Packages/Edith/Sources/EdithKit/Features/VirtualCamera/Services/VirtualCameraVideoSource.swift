@preconcurrency import AVFoundation
import CoreVideo
import Foundation

public final class VirtualCameraVideoSource: @unchecked Sendable {
    private let queue: DispatchQueue
    private var player: AVPlayer?
    private var itemOutput: AVPlayerItemVideoOutput?
    private var timer: DispatchSourceTimer?
    private var endToken: NSObjectProtocol?
    private var path: String?
    private var configuration = VirtualCameraMedia()
    private var lastFrame: CVPixelBuffer?
    private var frameHandler: ((CVPixelBuffer) -> Void)?
    private var failureHandler: ((String) -> Void)?
    private var reportedFailure = false

    public init(queue: DispatchQueue) { self.queue = queue }

    public func update(
        _ configuration: VirtualCameraMedia, frameRate: Int,
        failed: @escaping (String) -> Void, frame: @escaping (CVPixelBuffer) -> Void
    ) {
        self.configuration = configuration
        frameHandler = frame
        failureHandler = failed
        if path != configuration.path || player == nil {
            stop()
            self.configuration = configuration
            frameHandler = frame
            failureHandler = failed
            guard let path = configuration.path else { return }
            self.path = path
            let item = AVPlayerItem(url: URL(fileURLWithPath: path))
            let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ])
            item.add(output)
            itemOutput = output
            player = AVPlayer(playerItem: item)
            endToken = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: nil
            ) { [weak self] _ in
                self?.queue.async { [weak self] in
                    guard let self else { return }
                    if self.configuration.loop, self.configuration.playback == .playing {
                        self.player?.seek(to: .zero)
                        self.player?.play()
                    } else {
                        self.player?.pause()
                    }
                }
            }
        }
        player?.isMuted = true
        switch configuration.playback {
        case .playing: player?.play()
        case .paused: player?.pause()
        case .stopped:
            player?.pause()
            player?.seek(to: .zero)
        }
        if timer == nil {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: 1 / Double(max(frameRate, 1)))
            timer.setEventHandler { [weak self] in self?.tick() }
            timer.resume()
            self.timer = timer
        }
    }

    private func tick() {
        guard let player, let itemOutput else { return }
        if player.currentItem?.status == .failed, !reportedFailure {
            reportedFailure = true
            failureHandler?(
                player.currentItem?.error?.localizedDescription ?? "Cannot play this video.")
        }
        let time = player.currentTime()
        if itemOutput.hasNewPixelBuffer(forItemTime: time),
            let buffer = itemOutput.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil)
        {
            lastFrame = buffer
        }
        if let lastFrame { frameHandler?(lastFrame) }
    }

    public func suspend() {
        player?.pause()
        timer?.cancel()
        timer = nil
    }

    public func stop() {
        timer?.cancel()
        timer = nil
        player?.pause()
        player = nil
        itemOutput = nil
        lastFrame = nil
        path = nil
        reportedFailure = false
        if let endToken { NotificationCenter.default.removeObserver(endToken) }
        endToken = nil
    }
}
