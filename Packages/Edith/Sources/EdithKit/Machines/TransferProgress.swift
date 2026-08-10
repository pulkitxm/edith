import Foundation

public struct RsyncProgressSample: Equatable, Sendable {
    public var bytesTransferred: Int64
    public var percent: Int
    public var bytesPerSecond: Double
    public var filesRemaining: Int?
    public var filesTotal: Int?
    public var totalIsEstimate: Bool

    public init(
        bytesTransferred: Int64, percent: Int, bytesPerSecond: Double,
        filesRemaining: Int? = nil, filesTotal: Int? = nil, totalIsEstimate: Bool = false
    ) {
        self.bytesTransferred = bytesTransferred
        self.percent = percent
        self.bytesPerSecond = bytesPerSecond
        self.filesRemaining = filesRemaining
        self.filesTotal = filesTotal
        self.totalIsEstimate = totalIsEstimate
    }
}

public enum RsyncProgress {
    static let counterKeys = ["to-chk=", "to-check=", "ir-chk="]

    public static func parse(_ line: String) -> RsyncProgressSample? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let fields = trimmed.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard fields.count >= 3, fields[1].hasSuffix("%") else { return nil }
        let digits = fields[0].replacingOccurrences(of: ",", with: "")
        guard digits.allSatisfy(\.isNumber), let bytes = Int64(digits) else { return nil }
        guard let percent = Int(fields[1].dropLast()) else { return nil }
        var sample = RsyncProgressSample(
            bytesTransferred: bytes, percent: percent, bytesPerSecond: rate(fields[2]))
        for key in counterKeys {
            guard let marker = trimmed.range(of: key) else { continue }
            let tail = trimmed[marker.upperBound...].prefix { $0.isNumber || $0 == "/" }
            let parts = tail.split(separator: "/")
            guard parts.count == 2, let remaining = Int(parts[0]), let total = Int(parts[1])
            else { continue }
            sample.filesRemaining = remaining
            sample.filesTotal = total
            sample.totalIsEstimate = key == "ir-chk="
            break
        }
        return sample
    }

    static func rate(_ field: String) -> Double {
        let units: [(String, Double)] = [
            ("GB/s", 1_000_000_000), ("MB/s", 1_000_000), ("kB/s", 1000), ("B/s", 1),
        ]
        for (suffix, multiplier) in units where field.hasSuffix(suffix) {
            let number = field.dropLast(suffix.count).replacingOccurrences(of: ",", with: "")
            guard let value = Double(number) else { return 0 }
            return value * multiplier
        }
        return 0
    }

    public static func lines(from chunk: String) -> [RsyncProgressSample] {
        chunk.split(whereSeparator: { $0 == "\r" || $0 == "\n" })
            .compactMap { parse(String($0)) }
    }
}

public struct TransferEstimate: Equatable, Sendable {
    public var bytesPerSecond: Double
    public var secondsRemaining: Double?

    public init(bytesPerSecond: Double, secondsRemaining: Double?) {
        self.bytesPerSecond = bytesPerSecond
        self.secondsRemaining = secondsRemaining
    }
}

public struct ThroughputEstimator: Sendable {
    private var smoothed: Double?
    private let weight: Double

    public init(weight: Double = 0.25) {
        self.weight = weight
    }

    public mutating func record(bytesPerSecond: Double) {
        guard bytesPerSecond > 0 else { return }
        guard let current = smoothed else {
            smoothed = bytesPerSecond
            return
        }
        smoothed = current + weight * (bytesPerSecond - current)
    }

    public func estimate(bytesRemaining: Int64) -> TransferEstimate {
        guard let smoothed, smoothed > 0 else {
            return TransferEstimate(bytesPerSecond: 0, secondsRemaining: nil)
        }
        return TransferEstimate(
            bytesPerSecond: smoothed,
            secondsRemaining: Double(max(bytesRemaining, 0)) / smoothed)
    }
}
