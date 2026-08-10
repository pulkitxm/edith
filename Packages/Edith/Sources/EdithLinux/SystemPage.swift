import Adwaita
import EdithCore
import Foundation

struct SystemPage: View {
    @State private var cpuPercent = 0.0
    @State private var memoryUsedBytes: UInt64 = 0
    @State private var memoryTotalBytes: UInt64 = 0
    @State private var started = false

    private static let reader = SystemMetricsReader()

    var view: Body {
        ScrollView {
            VStack {
                Text("System")
                    .title1()
                    .halign(.start)
                    .padding(4, .bottom)
                Text("Live readings from /proc on this machine.")
                    .dimLabel()
                    .halign(.start)
                    .padding(16, .bottom)
                meter(title: "Processor", value: cpuPercent, detail: percentText(cpuPercent))
                meter(
                    title: "Memory", value: memoryFraction,
                    detail: "\(bytesText(memoryUsedBytes)) of \(bytesText(memoryTotalBytes))")
            }
            .frame(maxWidth: 720)
            .padding()
        }
        .onAppear {
            guard !started else { return }
            started = true
            startSampling()
        }
    }

    private var memoryFraction: Double {
        guard memoryTotalBytes > 0 else { return 0 }
        return Double(memoryUsedBytes) / Double(memoryTotalBytes)
    }

    private func meter(title: String, value: Double, detail: String) -> View {
        VStack {
            HStack {
                Text(title)
                    .heading()
                    .halign(.start)
                    .hexpand()
                Text(detail)
                    .dimLabel()
                    .halign(.end)
            }
            .padding(6, .bottom)
            ProgressBar(value: value, total: 1)
        }
        .padding(16)
        .card()
        .padding(12, .bottom)
    }

    private func percentText(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }

    private func bytesText(_ bytes: UInt64) -> String {
        let gigabyte = 1_024.0 * 1_024.0 * 1_024.0
        return String(format: "%.1f GB", Double(bytes) / gigabyte)
    }

    private func startSampling() {
        var previous = Self.reader.readCPUSample()
        refreshMemory()
        Idle(delay: .seconds(1)) {
            if let current = Self.reader.readCPUSample() {
                if let last = previous {
                    cpuPercent = SystemMetricsParsing.cpuUsage(previous: last, current: current)
                }
                previous = current
            }
            refreshMemory()
            return true
        }
    }

    private func refreshMemory() {
        guard let memory = Self.reader.readMemorySample() else { return }
        memoryUsedBytes = memory.usedBytes
        memoryTotalBytes = memory.totalBytes
    }
}
