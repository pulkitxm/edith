import EdithKit
import SwiftUI

struct SystemMonitorPage: View {
    @State private var snapshot: SystemMonitorSnapshot?
    @State private var errorMessage: String?
    @Environment(\.colorScheme) private var scheme
    @Environment(\.compactLayout) private var compact

    var body: some View {
        VStack(spacing: 0) {
            PageHeader("System Monitor")
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let errorMessage { Text(errorMessage).foregroundStyle(.secondary) }
                    SystemMonitorSummary(monitorSnapshot: snapshot, dark: scheme == .dark)
                }
                .pageContent(compact)
            }
        }
        .background(DashSkin.paper(scheme == .dark))
        .task {
            do {
                snapshot = try await SystemMonitorClient.snapshot()
                let subscription = try await AgentClient.shared.subscribeAsync(.systemMonitor) {
                    data in
                    guard
                        let value = try? AgentPayload.decode(SystemMonitorSnapshot.self, from: data)
                    else { return }
                    Task { @MainActor in snapshot = value }
                }
                defer { subscription.cancel() }
                while !Task.isCancelled { try await Task.sleep(for: .seconds(3600)) }
            } catch is CancellationError {
            } catch { errorMessage = error.localizedDescription }
        }
    }
}

struct SystemMonitorSummary: View {
    let monitorSnapshot: SystemMonitorSnapshot?
    let dark: Bool

    var body: some View {
        SkinCard(title: "System Monitor", note: "live", dark: dark) {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: UIScale.pt(135)), spacing: UIScale.pt(10))],
                spacing: UIScale.pt(10)
            ) {
                monitorMetric(
                    "CPU", value: percent(monitorSnapshot?.cpuPercent), symbol: "cpu",
                    detail: "processor load")
                monitorMetric(
                    "Memory", value: percent(monitorSnapshot?.memoryPercent),
                    symbol: "memorychip", detail: "active, wired, compressed")
                monitorMetric(
                    "GPU", value: percent(monitorSnapshot?.gpuPercent), symbol: "display",
                    detail: monitorSnapshot?.gpuPercent == nil
                        ? "not exposed" : "device utilization")
                monitorMetric(
                    "Network",
                    value: ByteFormatter.rate(
                        monitorSnapshot?.network.inboundBytesPerSecond ?? 0),
                    symbol: "arrow.down.arrow.up",
                    detail:
                        "up \(ByteFormatter.rate(monitorSnapshot?.network.outboundBytesPerSecond ?? 0))"
                )
                monitorMetric(
                    "Disk I/O",
                    value: ByteFormatter.rate(monitorSnapshot?.disk.inboundBytesPerSecond ?? 0),
                    symbol: "internaldrive",
                    detail:
                        "write \(ByteFormatter.rate(monitorSnapshot?.disk.outboundBytesPerSecond ?? 0))"
                )
                monitorMetric(
                    "Startup disk", value: percent(monitorSnapshot?.rootDiskUsedPercent),
                    symbol: "externaldrive.fill", detail: "capacity used")
                monitorMetric(
                    "Battery", value: batteryValue, symbol: "battery.75percent",
                    detail: batteryDetail)
            }
        }
    }

    private func monitorMetric(_ label: String, value: String, symbol: String, detail: String)
        -> some View
    {
        VStack(alignment: .leading, spacing: UIScale.pt(4)) {
            HStack(spacing: UIScale.pt(5)) {
                Image(systemName: symbol)
                Text(label.uppercased()).tracking(UIScale.pt(0.5))
            }
            .font(.system(size: UIScale.pt(9.5), weight: .semibold))
            .foregroundStyle(DashSkin.inkFaint(dark))
            Text(value)
                .font(.system(size: UIScale.pt(18), weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text(detail)
                .font(.system(size: UIScale.pt(9.5)))
                .foregroundStyle(DashSkin.inkFaint(dark))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(UIScale.pt(11))
        .background(DashSkin.paper(dark), in: RoundedRectangle(cornerRadius: UIScale.pt(10)))
    }

    private func percent(_ value: Double?) -> String {
        guard let value else { return "Unavailable" }
        return String(format: "%.0f%%", value)
    }

    private var batteryValue: String {
        guard let battery = monitorSnapshot?.battery else { return "No battery" }
        return "\(battery.percent)%"
    }

    private var batteryDetail: String {
        guard let battery = monitorSnapshot?.battery else { return "desktop power" }
        let watts: String
        if let value = battery.watts {
            watts = String(format: " · %+.1f W", value)
        } else {
            watts = ""
        }
        return battery.status + watts
    }

}
