import Darwin
import Foundation

public enum ProcessUsage {
    private static let timebase: mach_timebase_info_data_t = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return tb
    }()

    public static func sample(pid: pid_t) -> (cpuNS: UInt64, memMB: Double) {
        var info = rusage_info_current()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, $0)
            }
        }
        guard result == 0 else { return (0, 0) }
        let ticks = info.ri_user_time &+ info.ri_system_time
        let nanos = ticks &* UInt64(timebase.numer) / UInt64(timebase.denom)
        return (nanos, Double(info.ri_phys_footprint) / 1_048_576)
    }

    public static func cpuPercent(nowNS: UInt64, previousNS: UInt64, elapsed: TimeInterval)
        -> Double
    {
        guard elapsed > 0 else { return 0 }
        return max(0, Double(nowNS &- previousNS) / (elapsed * 1e9) * 100)
    }
}
