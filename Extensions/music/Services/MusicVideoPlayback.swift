import Darwin
import EdithExtensionSupport
import Foundation
import UniformTypeIdentifiers

@MainActor final class MusicVideoPlayback {
    let track: Track
    let lease: MusicVideoLease
    private let file: MusicVideoFile
    private var stopped = false
    private var inFlight = 0
    private var sequences: Set<UInt64> = []
    private var largestSequence: UInt64 = 0
    private(set) var duration = 0.0
    private(set) var elapsed: Double
    private(set) var playing = false
    private(set) var volume: Double
    private(set) var control: MusicVideoControl

    init(track: Track, position: Double, playing: Bool, volume: Double) throws {
        self.track = track
        file = try MusicVideoFile(url: track.url)
        let id = UUID()
        let ext = track.url.pathExtension.lowercased()
        lease = MusicVideoLease(
            id: id, revision: UUID(), length: file.length,
            contentType: ext == "mov"
                ? UTType.quickTimeMovie.identifier : UTType.mpeg4Movie.identifier,
            fileExtension: ext, position: position, playing: playing, volume: volume)
        elapsed = position; self.volume = volume
        control = .init(id: id, revision: 0, playing: playing, volume: volume)
    }

    func read(_ request: MusicVideoRange) async throws -> MusicVideoBytes {
        guard !stopped, request.id == lease.id, request.revision == lease.revision,
            request.offset >= 0, request.offset < lease.length,
            (1...262_144).contains(request.count), request.sequence > 0,
            request.sequence > largestSequence || largestSequence - request.sequence < 64,
            request.sequence <= largestSequence || request.sequence - largestSequence <= 64,
            !sequences.contains(request.sequence), inFlight < 4
        else { throw ExtensionPeerError.invalidRequest }
        largestSequence = max(largestSequence, request.sequence)
        sequences.insert(request.sequence)
        sequences = sequences.filter { largestSequence - $0 < 64 }
        inFlight += 1
        defer { inFlight -= 1 }
        let file = file
        let bytes = try await Task.detached { try file.read(request.offset, count: request.count) }
            .value
        try Task.checkCancellation()
        guard !stopped else { throw CancellationError() }
        return .init(
            id: lease.id, revision: lease.revision, sequence: request.sequence,
            offset: request.offset, data: bytes)
    }

    func report(_ value: MusicVideoReport) throws {
        guard !stopped, value.id == lease.id, value.revision == lease.revision,
            [value.elapsed, value.duration, value.volume].allSatisfy({ $0.isFinite && $0 >= 0 }),
            value.elapsed <= value.duration + 1, value.duration <= 604_800,
            (0...1).contains(value.volume), value.controlRevision <= control.revision
        else { throw ExtensionPeerError.invalidRequest }
        elapsed = value.elapsed; duration = value.duration; playing = value.playing
        if value.controlRevision == control.revision {
            volume = value.volume; control.volume = value.volume
            control.playing = value.playing; control.seek = nil
        }
    }

    func toggle() { control.playing.toggle(); control.revision &+= 1 }
    func pause() { control.playing = false; control.revision &+= 1 }
    func resume() { control.playing = true; control.revision &+= 1 }
    func seek(_ fraction: Double) { control.seek = fraction * duration; control.revision &+= 1 }
    func setVolume(_ value: Double) {
        control.volume = value; control.revision &+= 1
    }
    func stop() { stopped = true; playing = false; file.stop(); sequences.removeAll() }
}

private final class MusicVideoFile: @unchecked Sendable {
    let length: Int64
    private let lock = NSLock()
    private var descriptor: Int32
    private let identity: stat

    init(url: URL) throws {
        descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        var value = stat()
        guard descriptor >= 0, fstat(descriptor, &value) == 0,
            value.st_mode & S_IFMT == S_IFREG, value.st_size > 0,
            value.st_size <= 1_099_511_627_776
        else {
            if descriptor >= 0 { Darwin.close(descriptor) }
            throw ExtensionPeerError.invalidRequest
        }
        identity = value; length = value.st_size
    }

    deinit { if descriptor >= 0 { Darwin.close(descriptor) } }

    func read(_ offset: Int64, count: Int) throws -> Data {
        try lock.withLock {
            var current = stat()
            guard descriptor >= 0, fstat(descriptor, &current) == 0,
                current.st_ino == identity.st_ino, current.st_dev == identity.st_dev,
                current.st_size == length,
                current.st_mtimespec.tv_sec == identity.st_mtimespec.tv_sec,
                current.st_mtimespec.tv_nsec == identity.st_mtimespec.tv_nsec
            else { throw ExtensionPeerError.unavailable }
            var bytes = Data(count: min(count, Int(length - offset)))
            let read = bytes.withUnsafeMutableBytes {
                pread(descriptor, $0.baseAddress, $0.count, offset)
            }
            guard read == bytes.count else { throw ExtensionPeerError.unavailable }
            return bytes
        }
    }

    func stop() {
        lock.withLock {
            if descriptor >= 0 { Darwin.close(descriptor); descriptor = -1 }
        }
    }
}
