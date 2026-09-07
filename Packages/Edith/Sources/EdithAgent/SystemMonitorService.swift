import EdithKit
import Foundation

actor SystemMonitorService {
    static let shared = SystemMonitorService()
    private let sampler = SystemMonitorSampler()
    private var latest: SystemMonitorSnapshot?

    func snapshot() -> SystemMonitorSnapshot {
        let now = ProcessInfo.processInfo.systemUptime
        if let latest, now - latest.sampledAt < 2 { return latest }
        let value = sampler.sample(at: now)
        latest = value
        return value
    }

    func data() throws -> Data {
        try AgentPayload.encode(snapshot())
    }
}
