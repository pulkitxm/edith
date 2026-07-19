import Foundation

public enum TrustedTimeAssessment: Equatable {
    case plausible
    case rollbackSuspected
}

public struct TrustedTime: Codable, Equatable, Sendable {
    public static let rollbackToleranceSeconds: Double = 86_400

    public let lastServerTime: Int64
    public let wallClockAtSync: Int64
    public let monotonicAnchor: Double
    public let bootSessionId: String

    public init(
        lastServerTime: Int64, wallClockAtSync: Int64, monotonicAnchor: Double,
        bootSessionId: String
    ) {
        self.lastServerTime = lastServerTime
        self.wallClockAtSync = wallClockAtSync
        self.monotonicAnchor = monotonicAnchor
        self.bootSessionId = bootSessionId
    }

    public static func record(
        serverTime: Date,
        wallClock: Date = Date(),
        uptime: TimeInterval = ProcessInfo.processInfo.systemUptime,
        bootSessionId: String = TrustedTime.currentBootSessionId()
    ) -> TrustedTime {
        TrustedTime(
            lastServerTime: Int64(serverTime.timeIntervalSince1970),
            wallClockAtSync: Int64(wallClock.timeIntervalSince1970),
            monotonicAnchor: uptime,
            bootSessionId: bootSessionId)
    }

    public static func currentBootSessionId() -> String {
        var boottime = timeval()
        var size = MemoryLayout<timeval>.stride
        guard sysctlbyname("kern.boottime", &boottime, &size, nil, 0) == 0 else {
            return "unknown"
        }
        return "\(boottime.tv_sec).\(boottime.tv_usec)"
    }

    public func assess(now: Date) -> TrustedTimeAssessment {
        now.timeIntervalSince1970 < Double(lastServerTime) - Self.rollbackToleranceSeconds
            ? .rollbackSuspected
            : .plausible
    }

    public static func load(from store: any LicenseCredentialStoring) -> TrustedTime? {
        guard let raw = ((try? store.read(.trustedTime)) ?? nil) else { return nil }
        return try? JSONDecoder().decode(TrustedTime.self, from: Data(raw.utf8))
    }

    public func save(to store: any LicenseCredentialStoring) throws {
        let data = try JSONEncoder().encode(self)
        try store.write(String(decoding: data, as: UTF8.self), item: .trustedTime)
    }
}
