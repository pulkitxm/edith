import AVFoundation

@MainActor
final class VideoPreviewSeeker {
    typealias Seek = (CMTime, @escaping @Sendable (Bool) -> Void) -> Void

    private let seek: Seek
    private var pending: CMTime?
    private var flight: Int?
    private var generation = 0

    var isSeeking: Bool { flight != nil }

    init(seek: @escaping Seek) {
        self.seek = seek
    }

    convenience init(player: AVPlayer) {
        self.init { [weak player] time, completion in
            player?.seek(
                to: time, toleranceBefore: .zero, toleranceAfter: .zero,
                completionHandler: completion)
        }
    }

    func request(_ time: CMTime) {
        pending = time
        startNext()
    }

    func reset() {
        generation += 1
        flight = nil
        pending = nil
    }

    private func startNext() {
        guard flight == nil, let time = pending else { return }
        pending = nil
        generation += 1
        let version = generation
        flight = version
        seek(time) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.flight == version else { return }
                self.flight = nil
                self.startNext()
            }
        }
    }
}
