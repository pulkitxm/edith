import Darwin
import Foundation

public enum HostAppDiagnosticsCLI {
    public static func process(
        info: HostCLIJSON, startedAt: Date, agent: HostCLIJSON, extensionIDs: [String]
    ) throws -> HostCLIJSON {
        let seconds = max(0, Int64(Date().timeIntervalSince(startedAt)))
        return .object([
            "info": info, "pid": .integer(Int64(getpid())), "uptimeSeconds": .integer(seconds),
            "uptime": .string(uptime(seconds)), "idleWakeups": .integer(try idleWakeups()),
            "agent": agent, "extensions": .strings(extensionIDs.sorted()),
        ])
    }

    public static func core(snapshot: HostCoreSnapshot?, online: Bool, state: String, build: String)
        -> HostCLIJSON
    {
        var result: [String: HostCLIJSON] = ["state": .string(state), "running": .bool(online)]
        if online, let snapshot {
            result["build"] = .string(build)
            result["pid"] = .integer(Int64(snapshot.pid))
            result["uptimeSeconds"] = .integer(
                max(0, Int64(snapshot.collectedAt.timeIntervalSince(snapshot.startedAt))))
            result["residentBytes"] = .integer(Int64(clamping: snapshot.residentBytes))
            result["activeTasks"] = .integer(
                Int64(snapshot.tasks.filter { $0.phase == .running }.count))
            result["cloudAvailable"] = .bool(snapshot.cloudAvailable)
        }
        return .object(result)
    }

    static func uptime(_ seconds: Int64) -> String {
        let hours = seconds / 3600, minutes = (seconds % 3600) / 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }

    private static func idleWakeups() throws -> Int64 {
        var info = task_power_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_power_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_POWER_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            throw HostCLIError.rejected("macOS did not provide process power diagnostics.")
        }
        return Int64(clamping: info.task_platform_idle_wakeups)
    }
}
