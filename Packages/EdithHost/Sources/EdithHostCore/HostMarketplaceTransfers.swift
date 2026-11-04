import Foundation

public struct HostExtensionOperation: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case working
        case queued
        case downloading
        case installing
    }

    public var phase: Phase
    public var receivedBytes: Int64 = 0
    public var totalBytes: Int64 = 0
    public var bytesPerSecond: Double = 0
    public var fraction: Double = 0

    public init(
        phase: Phase, receivedBytes: Int64 = 0, totalBytes: Int64 = 0, bytesPerSecond: Double = 0,
        fraction: Double = 0
    ) {
        self.phase = phase
        self.receivedBytes = receivedBytes
        self.totalBytes = totalBytes
        self.bytesPerSecond = bytesPerSecond
        self.fraction = fraction
    }

    public var summary: String {
        switch phase {
        case .working: return "Working"
        case .queued: return "Queued"
        case .installing: return "Installing"
        case .downloading:
            guard totalBytes > 0, receivedBytes > 0 else { return "Downloading" }
            let progress =
                "Downloading \(Self.bytes(receivedBytes)) of \(Self.bytes(totalBytes))"
            guard bytesPerSecond >= 1 else { return progress }
            return progress + " · " + Self.rate(bytesPerSecond)
        }
    }

    public static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    public static func rate(_ bytesPerSecond: Double) -> String {
        bytes(Int64(bytesPerSecond.rounded())) + "/s"
    }
}

public struct HostExtensionBatch: Equatable, Sendable {
    public private(set) var ids: [String] = []
    public private(set) var completed: Set<String> = []
    public private(set) var failed: Set<String> = []

    public init() {}

    public var total: Int { ids.count }
    public var finished: Int { completed.count + failed.count }
    public func isDone(_ id: String) -> Bool { completed.contains(id) || failed.contains(id) }

    mutating func add(_ id: String) {
        if !ids.contains(id) { ids.append(id) }
        completed.remove(id)
        failed.remove(id)
    }

    mutating func complete(_ id: String, failed failure: Bool) {
        if failure { failed.insert(id) } else { completed.insert(id) }
    }
}

struct HostDownloadSlotWaiter {
    let id: String
    var priority: Int
    let sequence: Int
    let continuation: CheckedContinuation<Void, Never>
}

struct HostTransferSample {
    var instant: ContinuousClock.Instant
    var bytes: Int64
    var rate: Double?

    mutating func update(bytes received: Int64, at now: ContinuousClock.Instant) -> Double? {
        let elapsed = now - instant
        guard elapsed >= .milliseconds(500) else { return rate }
        let seconds =
            Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        let current = Double(max(0, received - bytes)) / seconds
        let smoothed = rate.map { $0 * 0.6 + current * 0.4 } ?? current
        instant = now
        bytes = received
        rate = smoothed
        return smoothed
    }
}

public final class HostTransferProgress: @unchecked Sendable {
    public typealias Observer = @Sendable (URL, Int64) -> Void
    private let lock = NSLock()
    private var observer: Observer?

    public init() {}

    func observe(_ observer: @escaping Observer) { lock.withLock { self.observer = observer } }

    public func report(_ url: URL, bytes: Int64) { lock.withLock { observer }?(url, bytes) }
}
