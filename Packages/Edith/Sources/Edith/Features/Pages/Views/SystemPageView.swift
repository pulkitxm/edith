import EdithKit
import SwiftUI

struct SystemPage: View {
    @State private var model = RunningAppsModel()
    @Environment(\.colorScheme) private var scheme
    @Environment(\.compactLayout) private var compact
    @State private var confirmQuitAll = false
    @State private var pendingQuit: RunningAppRow?
    @State private var monitorSnapshot: SystemMonitorSnapshot?
    @State private var monitorSampler = SystemMonitorSampler()

    private var dark: Bool { scheme == .dark }

    var body: some View {
        VStack(spacing: UIScale.pt(0)) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: UIScale.pt(16)) {
                    if let status = model.actionStatus {
                        actionStatus(status)
                    }
                    summary
                    monitorCard
                    SkinCard(title: "Running apps", dark: dark) {
                        appList
                    }
                    CleanerCard(dark: dark)
                }
                .pageContent(compact)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DashSkin.paper(dark))
        .confirmationDialog(
            "Quit \(pendingQuit?.name ?? "app")?",
            isPresented: Binding(
                get: { pendingQuit != nil }, set: { if !$0 { pendingQuit = nil } }),
            titleVisibility: .visible
        ) {
            Button("Quit \(pendingQuit?.name ?? "app")", role: .destructive) {
                if let app = pendingQuit { model.quit(app) }
                pendingQuit = nil
            }
            Button("Cancel", role: .cancel) { pendingQuit = nil }
        } message: {
            Text("The app will close. Unsaved changes will prompt you first.")
        }
        .task {
            defer { monitorSampler.reset() }
            while !Task.isCancelled {
                monitorSnapshot = monitorSampler.sample()
                await model.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private var header: some View {
        PageHeader(
            "System",
            trailing: {
                Button(role: .destructive) {
                    confirmQuitAll = true
                } label: {
                    Label("Quit all apps", systemImage: "xmark.circle")
                }
                .buttonStyle(EdithButtonStyle(.destructive))
                .confirmationDialog(
                    "Quit all apps?", isPresented: $confirmQuitAll, titleVisibility: .visible
                ) {
                    Button("Quit \(model.quitAllTargetCount) apps", role: .destructive) {
                        model.quitAll()
                    }
                } message: {
                    Text("Finder and Edith stay open. Apps with unsaved changes will ask first.")
                }
            })
    }

    private func actionStatus(_ status: RunningAppActionStatus) -> some View {
        let presentation = actionStatusPresentation(status)
        return HStack(alignment: .firstTextBaseline, spacing: UIScale.pt(9)) {
            Image(systemName: presentation.symbol)
            Text(status.message)
                .font(.system(size: UIScale.pt(12), weight: .medium))
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                model.clearActionStatus()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(EdithButtonStyle(.iconOnly, tint: presentation.color))
            .accessibilityLabel("Dismiss status")
            .help("Dismiss")
        }
        .foregroundStyle(presentation.color)
        .padding(.horizontal, UIScale.pt(12))
        .padding(.vertical, UIScale.pt(10))
        .background(
            presentation.color.opacity(dark ? 0.16 : 0.1),
            in: RoundedRectangle(cornerRadius: UIScale.pt(10))
        )
        .accessibilityElement(children: .combine)
    }

    private func actionStatusPresentation(
        _ status: RunningAppActionStatus
    ) -> (symbol: String, color: Color) {
        switch status {
        case .accepted:
            ("checkmark.circle.fill", .green)
        case .partial:
            ("exclamationmark.triangle.fill", .orange)
        case .planRejected, .planningFailed, .rejected:
            ("xmark.octagon.fill", .red)
        }
    }

    private var summary: some View {
        HStack(spacing: UIScale.pt(12)) {
            summaryCard("Running apps", "\(model.apps.count)")
            summaryCard("App memory", String(format: "%.1f GB", model.totalMemoryMB / 1024))
        }
    }

    private var monitorCard: some View {
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
        value.map { String(format: "%.0f%%", $0) } ?? "Unavailable"
    }

    private var batteryValue: String {
        monitorSnapshot?.battery.map { "\($0.percent)%" } ?? "No battery"
    }

    private var batteryDetail: String {
        guard let battery = monitorSnapshot?.battery else { return "desktop power" }
        let watts = battery.watts.map { String(format: " · %+.1f W", $0) } ?? ""
        return battery.status + watts
    }

    private func summaryCard(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: UIScale.pt(4)) {
            Text(label.uppercased())
                .font(.system(size: UIScale.pt(10), weight: .semibold)).tracking(UIScale.pt(0.6))
                .foregroundStyle(DashSkin.inkFaint(dark))
            Text(value).font(.system(size: UIScale.pt(22), weight: .semibold)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(UIScale.pt(16))
        .background(DashSkin.paper2(dark), in: RoundedRectangle(cornerRadius: UIScale.pt(14)))
    }

    private var columnHeaders: some View {
        HStack(spacing: UIScale.pt(10)) {
            headerButton("App", .name, width: nil, alignment: .leading)
                .padding(.leading, UIScale.pt(32))
            Spacer()
            headerButton("CPU", .cpu, width: UIScale.pt(48), alignment: .trailing)
            headerButton("Memory", .memory, width: UIScale.pt(72), alignment: .trailing)
            Color.clear.frame(width: UIScale.pt(16))
        }
        .padding(.bottom, UIScale.pt(6))
    }

    private func headerButton(
        _ label: String, _ key: AppSortKey, width: CGFloat?, alignment: Alignment
    ) -> some View {
        Button {
            model.sort(by: key)
        } label: {
            HStack(spacing: UIScale.pt(3)) {
                if alignment == .trailing { Spacer(minLength: 0) }
                Text(label.uppercased())
                    .font(.system(size: UIScale.pt(10), weight: .semibold)).tracking(
                        UIScale.pt(0.5))
                if model.sortKey == key {
                    Image(systemName: model.ascending ? "chevron.up" : "chevron.down")
                        .font(.system(size: UIScale.pt(7), weight: .bold))
                }
                if alignment == .leading { Spacer(minLength: 0) }
            }
            .foregroundStyle(model.sortKey == key ? DashSkin.accent(dark) : DashSkin.inkFaint(dark))
            .frame(width: width, alignment: alignment)
        }
        .buttonStyle(
            EdithButtonStyle(
                .borderless, selected: model.sortKey == key, tint: DashSkin.accent(dark))
        )
    }

    private var appList: some View {
        VStack(spacing: UIScale.pt(0)) {
            columnHeaders
            Divider().opacity(0.4)
            if model.apps.isEmpty {
                HStack(spacing: UIScale.pt(8)) {
                    ProgressView().controlSize(.small)
                    Text("Reading running apps…")
                        .font(.system(size: UIScale.pt(12))).foregroundStyle(
                            DashSkin.inkFaint(dark))
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, UIScale.pt(24))
            }
            ForEach(model.apps) { app in
                SystemAppRow(app: app, dark: dark, canQuit: model.canQuit(app)) {
                    pendingQuit = app
                }
                if app.id != model.apps.last?.id {
                    Divider().opacity(0.3)
                }
            }
        }
    }

    fileprivate static func cpuLabel(_ percent: Double) -> String {
        percent >= 10 || percent == 0
            ? String(format: "%.0f%%", percent) : String(format: "%.1f%%", percent)
    }

    fileprivate static func memoryLabel(_ mb: Double) -> String {
        mb >= 1024 ? String(format: "%.1f GB", mb / 1024) : String(format: "%.0f MB", mb)
    }
}

private struct SystemAppRow: View {
    let app: RunningAppRow
    let dark: Bool
    let canQuit: Bool
    let onQuit: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: UIScale.pt(10)) {
            if let icon = app.icon {
                Image(nsImage: icon).resizable().frame(
                    width: UIScale.pt(22), height: UIScale.pt(22))
            }
            Text(app.name).font(.system(size: UIScale.pt(13))).lineLimit(1)
            Spacer()
            Text(SystemPage.cpuLabel(app.cpuPercent))
                .font(.system(size: UIScale.pt(12), design: .monospaced))
                .foregroundStyle(app.cpuPercent > 25 ? .orange : DashSkin.inkFaint(dark))
                .frame(width: UIScale.pt(48), alignment: .trailing)
            Text(SystemPage.memoryLabel(app.memoryMB))
                .font(.system(size: UIScale.pt(12), design: .monospaced))
                .foregroundStyle(DashSkin.inkFaint(dark))
                .frame(width: UIScale.pt(72), alignment: .trailing)
            Button {
                onQuit()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(EdithButtonStyle(.iconOnly, tint: DashSkin.accent(dark)))
            .disabled(!canQuit)
            .accessibilityLabel("Quit \(app.name)")
            .help(canQuit ? "Quit \(app.name)" : "\(app.name) stays open")
        }
        .padding(.horizontal, UIScale.pt(6))
        .padding(.vertical, UIScale.pt(7))
        .background(
            RoundedRectangle(cornerRadius: UIScale.pt(7))
                .fill(hovering ? DashSkin.inkFaint(dark).opacity(0.1) : .clear)
        )
        .onHover { hovering = $0 }
    }
}
