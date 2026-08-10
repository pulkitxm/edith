import Darwin
import Foundation

public struct CPUTicks: Equatable, Sendable {
    public var used: UInt64
    public var total: UInt64
    public init(used: UInt64, total: UInt64) {
        self.used = used
        self.total = total
    }
}

public enum SystemStatsReader {
    public static func cpuUsage(previous: CPUTicks, current: CPUTicks) -> Double {
        let usedDelta = Double(current.used &- previous.used)
        let totalDelta = Double(current.total &- previous.total)
        guard totalDelta > 0 else { return 0 }
        return min(100, max(0, usedDelta / totalDelta * 100))
    }

    public static func readCPUTicks() -> CPUTicks? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let user = UInt64(info.cpu_ticks.0)
        let system = UInt64(info.cpu_ticks.1)
        let idle = UInt64(info.cpu_ticks.2)
        let nice = UInt64(info.cpu_ticks.3)
        return CPUTicks(used: user &+ system &+ nice, total: user &+ system &+ nice &+ idle)
    }

    public static func memoryUsedPercent() -> Double {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let pageSize = Double(vm_page_size)
        let used =
            Double(stats.active_count) + Double(stats.wire_count)
            + Double(stats.compressor_page_count)
        let usedBytes = used * pageSize
        let total = Double(ProcessInfo.processInfo.physicalMemory)
        guard total > 0 else { return 0 }
        return min(100, max(0, usedBytes / total * 100))
    }
}
