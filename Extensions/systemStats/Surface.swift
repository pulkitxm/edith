import EdithExtensionSupport
import Foundation

enum SystemStatsSurface {
    static func snapshot(
        cpu: Double, memory: Double, freeDiskBytes: Int64?, totalDiskBytes: Int64? = nil
    ) -> SurfaceSnapshot {
        var metrics: [SurfaceMetric] = [
            .init("cpu", "CPU", String(format: "%.0f%%", cpu), fraction: min(1, max(0, cpu / 100))),
            .init(
                "memory", "Memory used", String(format: "%.0f%%", memory),
                fraction: min(1, max(0, memory / 100))),
        ]
        if let freeDiskBytes {
            let fraction = totalDiskBytes.flatMap { total in
                total > 0 ? min(1, max(0, 1 - Double(freeDiskBytes) / Double(total))) : nil
            }
            metrics.append(
                .init(
                    "disk", "Storage free",
                    ByteCountFormatter.string(fromByteCount: freeDiskBytes, countStyle: .file),
                    fraction: fraction))
        }
        return .init(providerID: "systemStats", metrics: metrics, updatedAt: Date())
    }
}
