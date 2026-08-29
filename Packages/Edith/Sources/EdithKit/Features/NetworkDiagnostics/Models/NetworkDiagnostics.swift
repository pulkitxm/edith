import EdithCore
import Foundation

public enum NetworkDiagnosticState: String, Codable, CaseIterable, Sendable {
    case healthy
    case warning
    case failed
    case skipped

    public var rank: Int {
        switch self {
        case .healthy: 0
        case .skipped: 0
        case .warning: 2
        case .failed: 3
        }
    }
}

public enum NetworkDiagnosticOperation: String, CaseIterable, Sendable {
    case diagnose
    case baseline

    public var descriptor: UserOperationDescriptor {
        switch self {
        case .diagnose:
            UserOperationDescriptor(
                id: UserOperationID(rawValue: "network.diagnose"),
                summary: "Run a read-only network diagnostic snapshot.",
                cli: ["network", "diagnose"], effect: .read)
        case .baseline:
            UserOperationDescriptor(
                id: UserOperationID(rawValue: "network.baseline"),
                summary: "Read the saved healthy network baseline.",
                cli: ["network", "baseline"], effect: .read)
        }
    }
}

public struct NetworkServiceTarget: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: String { "\(host):\(port)" }
    public var host: String
    public var port: Int

    public init(host: String, port: Int) {
        self.host = host
        self.port = port
    }
}

public struct NetworkDiagnosticsConfiguration: Codable, Equatable, Sendable {
    public var targetHost: String
    public var dnsName: String
    public var httpTarget: String
    public var httpsTarget: String
    public var serviceTargets: [NetworkServiceTarget]
    public var exclusions: [String]
    public var publicIPEnabled: Bool
    public var scheduledSamplingEnabled: Bool
    public var notificationsEnabled: Bool
    public var sampleIntervalMinutes: Int
    public var timeoutSeconds: Double
    public var retries: Int
    public var pingCount: Int
    public var timelineLimit: Int

    public init(
        targetHost: String = "", dnsName: String = "", httpTarget: String = "",
        httpsTarget: String = "", serviceTargets: [NetworkServiceTarget] = [],
        exclusions: [String] = [], publicIPEnabled: Bool = false,
        scheduledSamplingEnabled: Bool = false, notificationsEnabled: Bool = false,
        sampleIntervalMinutes: Int = 15, timeoutSeconds: Double = 4, retries: Int = 1,
        pingCount: Int = 4, timelineLimit: Int = 100
    ) {
        self.targetHost = targetHost
        self.dnsName = dnsName
        self.httpTarget = httpTarget
        self.httpsTarget = httpsTarget
        self.serviceTargets = serviceTargets
        self.exclusions = exclusions
        self.publicIPEnabled = publicIPEnabled
        self.scheduledSamplingEnabled = scheduledSamplingEnabled
        self.notificationsEnabled = notificationsEnabled
        self.sampleIntervalMinutes = sampleIntervalMinutes
        self.timeoutSeconds = timeoutSeconds
        self.retries = retries
        self.pingCount = pingCount
        self.timelineLimit = timelineLimit
    }

    public var normalized: Self {
        var value = self
        value.targetHost = targetHost.trimmingCharacters(in: .whitespacesAndNewlines)
        value.dnsName = dnsName.trimmingCharacters(in: .whitespacesAndNewlines)
        value.httpTarget = httpTarget.trimmingCharacters(in: .whitespacesAndNewlines)
        value.httpsTarget = httpsTarget.trimmingCharacters(in: .whitespacesAndNewlines)
        value.serviceTargets = serviceTargets.filter {
            !$0.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && (1...65535).contains($0.port)
        }
        value.exclusions = exclusions.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }.filter { !$0.isEmpty }
        value.sampleIntervalMinutes = min(1440, max(5, sampleIntervalMinutes))
        value.timeoutSeconds = min(30, max(1, timeoutSeconds))
        value.retries = min(3, max(0, retries))
        value.pingCount = min(10, max(1, pingCount))
        value.timelineLimit = min(500, max(10, timelineLimit))
        return value
    }

    public func excludes(_ host: String) -> Bool {
        let candidate = host.lowercased()
        return exclusions.contains { candidate == $0 || candidate.hasSuffix("." + $0) }
    }
}

public struct NetworkDiagnosticCheck: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let state: NetworkDiagnosticState
    public let summary: String
    public let detail: String
    public let durationMS: Double?
    public let packetLossPercent: Double?

    public init(
        id: String, title: String, state: NetworkDiagnosticState, summary: String,
        detail: String = "", durationMS: Double? = nil, packetLossPercent: Double? = nil
    ) {
        self.id = id
        self.title = title
        self.state = state
        self.summary = summary
        self.detail = detail
        self.durationMS = durationMS
        self.packetLossPercent = packetLossPercent
    }
}

public struct NetworkPathSummary: Codable, Equatable, Sendable {
    public let interfaceName: String?
    public let localAddress: String?
    public let gateway: String?
    public let dnsServers: [String]
    public let wifiName: String?
    public let wifiBSSID: String?
    public let wifiRSSI: Int?
    public let proxyHint: String?
    public let vpnHint: String?
    public let publicAddress: String?

    public init(
        interfaceName: String? = nil, localAddress: String? = nil, gateway: String? = nil,
        dnsServers: [String] = [], wifiName: String? = nil, wifiBSSID: String? = nil,
        wifiRSSI: Int? = nil, proxyHint: String? = nil, vpnHint: String? = nil,
        publicAddress: String? = nil
    ) {
        self.interfaceName = interfaceName
        self.localAddress = localAddress
        self.gateway = gateway
        self.dnsServers = dnsServers
        self.wifiName = wifiName
        self.wifiBSSID = wifiBSSID
        self.wifiRSSI = wifiRSSI
        self.proxyHint = proxyHint
        self.vpnHint = vpnHint
        self.publicAddress = publicAddress
    }
}

public struct NetworkDiagnosticSnapshot: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let createdAt: Date
    public let durationMS: Double
    public let state: NetworkDiagnosticState
    public let path: NetworkPathSummary
    public let checks: [NetworkDiagnosticCheck]
    public let baselineChanges: [String]

    public init(
        id: UUID = UUID(), createdAt: Date = Date(), durationMS: Double,
        state: NetworkDiagnosticState, path: NetworkPathSummary,
        checks: [NetworkDiagnosticCheck], baselineChanges: [String] = []
    ) {
        self.id = id
        self.createdAt = createdAt
        self.durationMS = durationMS
        self.state = state
        self.path = path
        self.checks = checks
        self.baselineChanges = baselineChanges
    }

    public func compared(with baseline: Self?) -> Self {
        guard let baseline else { return self }
        let old = Dictionary(uniqueKeysWithValues: baseline.checks.map { ($0.id, $0) })
        let changes = checks.compactMap { check -> String? in
            guard let previous = old[check.id] else { return "\(check.title) is new" }
            if check.state != previous.state {
                return "\(check.title): \(previous.state.rawValue) to \(check.state.rawValue)"
            }
            if let now = check.durationMS, let before = previous.durationMS,
                now > max(before * 2, before + 50)
            {
                return "\(check.title): latency increased from \(Int(before)) ms to \(Int(now)) ms"
            }
            return nil
        }
        return Self(
            id: id, createdAt: createdAt, durationMS: durationMS, state: state, path: path,
            checks: checks, baselineChanges: changes)
    }
}

public enum NetworkDiagnosticsRedactor {
    public static func redact(_ text: String) -> String {
        var value = text
        let patterns = [
            #"(?i)(authorization|token|password|secret|api[_-]?key)(\s*[:=]\s*)[^\s&,;]+"#,
            #"\b(?:\d{1,3}\.){3}\d{1,3}\b"#,
            #"\b[0-9a-fA-F]{0,4}:[0-9a-fA-F:]{2,}\b"#,
            #"\b(?:[0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}\b"#,
        ]
        for (index, pattern) in patterns.enumerated() {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            let replacement = index == 0 ? "$1$2<redacted>" : "<address>"
            value = expression.stringByReplacingMatches(
                in: value, range: NSRange(value.startIndex..., in: value),
                withTemplate: replacement)
        }
        guard
            let detector = try? NSDataDetector(
                types: NSTextCheckingResult.CheckingType.link.rawValue)
        else { return value }
        let source = value
        for match in detector.matches(
            in: source, range: NSRange(source.startIndex..., in: source)
        ).reversed() {
            guard let range = Range(match.range, in: value), let url = match.url,
                var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            else { continue }
            if components.user != nil { components.user = "redacted" }
            if components.password != nil { components.password = "redacted" }
            if components.query != nil { components.query = "<redacted>" }
            value.replaceSubrange(range, with: components.string ?? "<redacted-url>")
        }
        return value
    }

    public static func report(_ snapshot: NetworkDiagnosticSnapshot) -> String {
        let formatter = ISO8601DateFormatter()
        var lines = [
            "Network Diagnostics", "Captured: \(formatter.string(from: snapshot.createdAt))",
            "Overall: \(snapshot.state.rawValue)",
            "Interface: \(snapshot.path.interfaceName ?? "unavailable")",
            "Local address: \(snapshot.path.localAddress ?? "unavailable")",
            "Gateway: \(snapshot.path.gateway ?? "unavailable")",
            "DNS: \(snapshot.path.dnsServers.joined(separator: ", "))",
            "Wi-Fi: \(snapshot.path.wifiName == nil ? "unavailable" : "<network>")",
            "Proxy: \(snapshot.path.proxyHint ?? "none detected")",
            "VPN: \(snapshot.path.vpnHint ?? "none detected")",
            "Public address: \(snapshot.path.publicAddress ?? "disabled or unavailable")", "",
        ]
        for check in snapshot.checks {
            let timing = check.durationMS.map { " \(Int($0)) ms" } ?? ""
            let loss = check.packetLossPercent.map { " loss \(String(format: "%.1f", $0))%" } ?? ""
            lines.append(
                "[\(check.state.rawValue)] \(check.title): \(check.summary)\(timing)\(loss)")
            if !check.detail.isEmpty { lines.append("  \(check.detail)") }
        }
        if !snapshot.baselineChanges.isEmpty {
            lines.append("")
            lines.append("Changes from saved baseline:")
            lines.append(contentsOf: snapshot.baselineChanges.map { "- \($0)" })
        }
        return redact(lines.joined(separator: "\n"))
    }
}
