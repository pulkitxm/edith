import EdithExtensionSupport
import Foundation

enum SystemStatsSurface {
    static func snapshot(cpu: Double, memory: Double, freeDiskBytes: Int64?) -> SurfaceSnapshot {
        var metrics: [SurfaceMetric] = [
            .init("cpu", "CPU", String(format: "%.0f%%", cpu), fraction: min(1, max(0, cpu / 100))),
            .init(
                "memory", "Memory", String(format: "%.0f%%", memory),
                fraction: min(1, max(0, memory / 100))),
        ]
        if let freeDiskBytes {
            metrics.append(
                .init(
                    "disk", "Free storage",
                    ByteCountFormatter.string(fromByteCount: freeDiskBytes, countStyle: .file)))
        }
        return .init(providerID: "systemStats", metrics: metrics, updatedAt: Date())
    }
}
