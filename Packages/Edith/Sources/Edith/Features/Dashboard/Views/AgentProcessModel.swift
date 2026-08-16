import Darwin
import EdithKit
import Foundation

struct AgentProcessRow: Identifiable {
    let pid: pid_t
    let name: String
    var cpuPercent: Double
    var memoryMB: Double
    var id: pid_t { pid }
}

@MainActor
final class AgentProcessModel: ObservableObject {
    @Published private(set) var processes: [AgentProcessRow] = []

    private var lastCPU: [pid_t: (time: UInt64, at: Date)] = [:]

    func refresh() async {
        let mine = ProcessInfo.processInfo.processIdentifier
        let names = await Task.detached(priority: .utility) {
            Self.listAgentPIDs()
        }.value
        let previous = lastCPU
        let now = Date()
        var rows: [AgentProcessRow] = []
        var seen = Set<pid_t>()
        var nextCPU: [pid_t: (time: UInt64, at: Date)] = [:]
        for (pid, name) in names where pid != mine {
            seen.insert(pid)
            let usage = ProcessUsage.sample(pid: pid)
            var cpu = 0.0
            if let prev = previous[pid] {
                cpu = ProcessUsage.cpuPercent(
                    nowNS: usage.cpuNS, previousNS: prev.time,
                    elapsed: now.timeIntervalSince(prev.at))
            }
            nextCPU[pid] = (usage.cpuNS, now)
            rows.append(
                AgentProcessRow(pid: pid, name: name, cpuPercent: cpu, memoryMB: usage.memMB))
        }
        lastCPU = nextCPU.filter { seen.contains($0.key) }
        processes = rows.sorted { $0.cpuPercent > $1.cpuPercent }
    }

    func kill(_ row: AgentProcessRow, force: Bool = false) {
        Foundation.kill(row.pid, force ? SIGKILL : SIGTERM)
    }

    nonisolated private static func listAgentPIDs() -> [(pid_t, String)] {
        let needed = proc_listallpids(nil, 0)
        guard needed > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(needed) * 2)
        let count = proc_listallpids(&pids, Int32(pids.count) * Int32(MemoryLayout<pid_t>.size))
        guard count > 0 else { return [] }
        var result: [(pid_t, String)] = []
        for pid in pids.prefix(Int(count)) where pid > 0 {
            var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            let length = proc_name(pid, &buffer, UInt32(buffer.count))
            guard length > 0 else { continue }
            let name = String(cString: buffer)
            guard AgentProcessFilter.isAgentProcess(name: name) else { continue }
            result.append((pid, name))
        }
        return result
    }
}
