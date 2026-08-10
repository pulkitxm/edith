import Foundation

public struct CPUSample: Equatable, Sendable {
    public let used: UInt64
    public let total: UInt64

    public init(used: UInt64, total: UInt64) {
        self.used = used
        self.total = total
    }
}

public struct MemorySample: Equatable, Sendable {
    public let totalBytes: UInt64
    public let availableBytes: UInt64

    public init(totalBytes: UInt64, availableBytes: UInt64) {
        self.totalBytes = totalBytes
        self.availableBytes = availableBytes
    }

    public var usedBytes: UInt64 {
        totalBytes > availableBytes ? totalBytes - availableBytes : 0
    }

    public var usedFraction: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(usedBytes) / Double(totalBytes)
    }
}

public enum SystemMetricsParsing {
    public static func cpuSample(fromProcStat text: String) -> CPUSample? {
        guard
            let line = text.split(separator: "\n", omittingEmptySubsequences: true).first(where: {
                $0.hasPrefix("cpu ")
            })
        else { return nil }
        let fields = line.split(separator: " ", omittingEmptySubsequences: true).dropFirst()
            .compactMap { UInt64($0) }
        guard fields.count >= 4 else { return nil }
        let idle = fields.count > 4 ? fields[3] + fields[4] : fields[3]
        let total = fields.reduce(UInt64(0), &+)
        guard total >= idle else { return nil }
        return CPUSample(used: total - idle, total: total)
    }

    public static func memorySample(fromProcMeminfo text: String) -> MemorySample? {
        var total: UInt64?
        var available: UInt64?
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let value = parts[1].split(separator: " ", omittingEmptySubsequences: true).first
                .flatMap { UInt64($0) }
            switch parts[0] {
            case "MemTotal": total = value
            case "MemAvailable": available = value
            default: continue
            }
        }
        guard let total, let available else { return nil }
        return MemorySample(totalBytes: total * 1_024, availableBytes: available * 1_024)
    }

    public static func cpuUsage(previous: CPUSample, current: CPUSample) -> Double {
        let usedDelta = Double(current.used &- previous.used)
        let totalDelta = Double(current.total &- previous.total)
        guard totalDelta > 0 else { return 0 }
        return min(1, max(0, usedDelta / totalDelta))
    }
}

public struct SystemMetricsReader: Sendable {
    private let procStatURL: URL
    private let procMeminfoURL: URL

    public init(
        procStatURL: URL = URL(fileURLWithPath: "/proc/stat"),
        procMeminfoURL: URL = URL(fileURLWithPath: "/proc/meminfo")
    ) {
        self.procStatURL = procStatURL
        self.procMeminfoURL = procMeminfoURL
    }

    public func readCPUSample() -> CPUSample? {
        guard let text = try? String(contentsOf: procStatURL, encoding: .utf8) else { return nil }
        return SystemMetricsParsing.cpuSample(fromProcStat: text)
    }

    public func readMemorySample() -> MemorySample? {
        guard let text = try? String(contentsOf: procMeminfoURL, encoding: .utf8) else {
            return nil
        }
        return SystemMetricsParsing.memorySample(fromProcMeminfo: text)
    }
}
