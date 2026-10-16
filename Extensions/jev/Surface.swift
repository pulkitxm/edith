import EdithExtensionSupport
import Foundation

enum JevSurface {
    static func snapshot(_ status: JevStatus) -> SurfaceSnapshot {
        var metrics = [SurfaceMetric("decisions", "Decisions", status.decisions.description)]
        if let latency = status.medianMilliseconds {
            metrics.append(.init("latency", "Median latency", latency.description + " ms"))
        }
        return .init(
            providerID: "jev", metrics: metrics,
            rows: [
                .init(
                    "configuration", title: "Jev", value: String(status.summary.prefix(256)),
                    icon: "sparkle")
            ], message: status.message.map { String($0.prefix(2048)) }, updatedAt: status.checkedAt)
    }
}
