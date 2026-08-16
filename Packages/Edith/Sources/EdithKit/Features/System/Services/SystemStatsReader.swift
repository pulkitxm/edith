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
        let usedBytes = memoryUsedBytes(
            anonymousPages: UInt64(stats.internal_page_count),
            wiredPages: UInt64(stats.wire_count),
            compressedPages: UInt64(stats.compressor_page_count),
            pageSize: UInt64(vm_page_size))
        return memoryUsedPercent(
            usedBytes: usedBytes, totalBytes: ProcessInfo.processInfo.physicalMemory)
    }

    static func memoryUsedBytes(
        anonymousPages: UInt64, wiredPages: UInt64, compressedPages: UInt64, pageSize: UInt64
    ) -> UInt64 {
        let pageCount = anonymousPages.addingReportingOverflow(wiredPages)
        guard !pageCount.overflow else { return UInt64.max }
        let allPages = pageCount.partialValue.addingReportingOverflow(compressedPages)
        guard !allPages.overflow else { return UInt64.max }
        let bytes = allPages.partialValue.multipliedReportingOverflow(by: pageSize)
        return bytes.overflow ? UInt64.max : bytes.partialValue
    }

    static func memoryUsedPercent(usedBytes: UInt64, totalBytes: UInt64) -> Double {
        guard totalBytes > 0 else { return 0 }
        return min(100, Double(usedBytes) / Double(totalBytes) * 100)
    }
}
