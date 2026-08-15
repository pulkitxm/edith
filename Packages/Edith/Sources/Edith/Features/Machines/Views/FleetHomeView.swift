import EdithKit
import SwiftUI

struct FleetHomeView: View {
    let model: MachinesModel
    let onSelect: (UUID) -> Void
    @Environment(\.colorScheme) private var scheme
    @Environment(\.compactLayout) private var compact
    @State private var tick = 0
    @State private var cpuHistory: [Double] = []
    @State private var memHistory: [Double] = []
    @State private var loaded = false

    private var dark: Bool { scheme == .dark }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: UIScale.pt(16)) {
                if !loaded {
                    FleetHomeSkeleton(dark: dark)
                } else {
                    fleetBanner
                    metricsGrid
                    storageCard
                    if !model.fleet.alerts.isEmpty { alertsCard }
                    machinesCard
                }
            }
            .pageContent(compact)
        }
        .task {
            while !Task.isCancelled {
                tick += 1
                let fleet = model.fleet
                if !loaded, model.snapshots.allSatisfy({ !$0.online }) || fleet.memoryTotalKB > 0 {
                    loaded = true
                }
                cpuHistory = MachineSession.appending(fleet.cpuPercent, to: cpuHistory)
                memHistory = MachineSession.appending(fleet.memoryPercent, to: memHistory)
                try? await Task.sleep(for: .seconds(MetricsCadence.sampleInterval))
            }
        }
    }

    private var fleetBanner: some View {
        let fleet = model.fleet
        return HStack(spacing: UIScale.pt(10)) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: UIScale.pt(12)))
                .foregroundStyle(DashSkin.inkFaint(dark))
            Text("\(fleet.machinesOnline) of \(fleet.machinesTotal) machines online")
                .font(.system(size: UIScale.pt(12.5), weight: .medium))
                .foregroundStyle(DashSkin.ink(dark))
            Spacer(minLength: 0)
            Text(bannerDetail(fleet))
                .font(DashSkin.mono(10.5))
                .foregroundStyle(DashSkin.inkFaint(dark))
                .lineLimit(1)
        }
        .padding(.horizontal, UIScale.pt(14))
        .padding(.vertical, UIScale.pt(10))
        .background(DashSkin.paper2(dark), in: RoundedRectangle(cornerRadius: UIScale.pt(12)))
        .overlay {
            RoundedRectangle(cornerRadius: UIScale.pt(12)).strokeBorder(DashSkin.line(dark))
        }
    }

    private func bannerDetail(_ fleet: FleetSummary) -> String {
        var parts = ["\(fleet.totalCores) cores"]
        if fleet.containersTotal > 0 {
            parts.append("\(fleet.containersRunning) of \(fleet.containersTotal) containers")
        }
        if fleet.swapTotalKB > 0 {
            parts.append("swap \(ByteFormatter.string(fleet.swapUsedKB * 1024))")
        }
        return parts.joined(separator: "  ·  ")
    }

    private var metricsGrid: some View {
        let fleet = model.fleet
        return LazyVGrid(
            columns: [
                GridItem(.flexible(), spacing: UIScale.pt(12)),
                GridItem(.flexible(), spacing: UIScale.pt(12)),
            ], spacing: UIScale.pt(12)
        ) {
            MetricCard(
                title: "CPU", value: String(format: "%.0f%%", fleet.cpuPercent),
                fraction: fleet.cpuPercent / 100, history: cpuHistory, maximum: 100,
                color: DashSkin.accent(dark), footnote: "\(fleet.totalCores) cores total",
                dark: dark)
            MetricCard(
                title: "Memory",
                value: String(format: "%.0f%%", fleet.memoryPercent),
                fraction: fleet.memoryPercent / 100, history: memHistory, maximum: 100,
                color: DashSkin.sage,
                footnote: "\(ByteFormatter.string(fleet.memoryUsedKB * 1024)) of "
                    + ByteFormatter.string(fleet.memoryTotalKB * 1024),
                dark: dark)
        }
    }

    @ViewBuilder
    private var storageCard: some View {
        let rows = model.snapshots.filter { $0.diskTotalKB > 0 }
        if !rows.isEmpty {
            SkinCard(title: "Storage", dark: dark) {
                VStack(spacing: UIScale.pt(10)) {
                    ForEach(rows, id: \.id) { row in
                        VStack(alignment: .leading, spacing: UIScale.pt(5)) {
                            HStack {
                                Text(row.name)
                                    .font(.system(size: UIScale.pt(12), weight: .medium))
                                    .foregroundStyle(DashSkin.ink(dark))
                                    .lineLimit(1)
                                Spacer()
                                Text(
                                    "\(ByteFormatter.string(row.diskUsedKB * 1024)) of "
                                        + ByteFormatter.string(row.diskTotalKB * 1024)
                                )
                                .font(DashSkin.mono(10.5))
                                .foregroundStyle(DashSkin.inkFaint(dark))
                            }
                            let percent = Double(row.diskUsedKB) / Double(max(row.diskTotalKB, 1))
                            MeterBar(
                                fraction: percent,
                                color: percent > 0.9
                                    ? DashSkin.danger
                                    : (percent > 0.75 ? DashSkin.warn : DashSkin.accent(dark)),
                                track: DashSkin.line(dark))
                        }
                    }
                }
            }
        }
    }

    private var alertsCard: some View {
        SkinCard(title: "Needs attention", dark: dark) {
            VStack(alignment: .leading, spacing: UIScale.pt(7)) {
                ForEach(model.fleet.alerts) { alert in
                    HStack(spacing: UIScale.pt(8)) {
                        Image(systemName: alert.symbol)
                            .font(.system(size: UIScale.pt(11)))
                            .foregroundStyle(
                                alert.kind == .updates ? DashSkin.gold : DashSkin.warn
                            )
                            .frame(width: UIScale.pt(16))
                        Text(alert.machineName)
                            .font(.system(size: UIScale.pt(12), weight: .medium))
                            .foregroundStyle(DashSkin.ink(dark))
                        Text(alert.detail)
                            .font(.system(size: UIScale.pt(11.5)))
                            .foregroundStyle(DashSkin.inkFaint(dark))
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    private var machinesCard: some View {
        SkinCard(title: "Machines", dark: dark) {
            VStack(spacing: UIScale.pt(0)) {
                ForEach(FleetMath.sortedByPressure(model.snapshots), id: \.id) { snapshot in
                    FleetMachineRow(snapshot: snapshot, dark: dark) {
                        onSelect(snapshot.id)
                    }
                    if snapshot.id != FleetMath.sortedByPressure(model.snapshots).last?.id {
                        Divider().opacity(0.25)
                    }
                }
            }
        }
    }
}

private struct FleetMachineRow: View {
    let snapshot: MachineSnapshot
    let dark: Bool
    let onOpen: () -> Void
    @State private var hovering = false

    private var hostsCompanion: Bool {
        guard let deployment = CompanionDeploymentStore.load() else { return false }
        return deployment.isLocal ? snapshot.isLocal : deployment.machineID == snapshot.id
    }

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: UIScale.pt(12)) {
                Image(systemName: snapshot.isLocal ? "laptopcomputer" : "server.rack")
                    .font(.system(size: UIScale.pt(13)))
                    .foregroundStyle(DashSkin.inkSoft(dark))
                    .frame(width: UIScale.pt(18))
                VStack(alignment: .leading, spacing: UIScale.pt(1)) {
                    HStack(spacing: UIScale.pt(5)) {
                        Text(snapshot.name)
                            .font(.system(size: UIScale.pt(12.5), weight: .medium))
                            .foregroundStyle(DashSkin.ink(dark))
                        if hostsCompanion {
                            Image(systemName: "brain.head.profile")
                                .font(.system(size: UIScale.pt(9.5)))
                                .foregroundStyle(DashSkin.accent(dark))
                                .help("Runs the companion")
                        }
                    }
                    Text(snapshot.online ? snapshot.os : "Not connected")
                        .font(.system(size: UIScale.pt(10.5)))
                        .foregroundStyle(DashSkin.inkFaint(dark))
                        .lineLimit(1)
                }
                .frame(width: UIScale.pt(190), alignment: .leading)
                if snapshot.online {
                    meter("CPU", percent: snapshot.cpuPercent, color: DashSkin.accent(dark))
                    meter("MEM", percent: snapshot.memoryPercent, color: DashSkin.sage)
                    meter(
                        "DISK", percent: snapshot.diskPercent,
                        color: snapshot.diskPercent > FleetMath.diskWarningPercent
                            ? DashSkin.danger : DashSkin.gold)
                    Text("\(snapshot.cores) cores")
                        .font(DashSkin.mono(10))
                        .foregroundStyle(DashSkin.inkFaint(dark))
                        .frame(width: UIScale.pt(60), alignment: .trailing)
                } else {
                    Text("Offline")
                        .font(.system(size: UIScale.pt(11)))
                        .foregroundStyle(DashSkin.inkFaint(dark))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: UIScale.pt(9)))
                    .foregroundStyle(DashSkin.inkFaint(dark))
            }
            .padding(.vertical, UIScale.pt(8))
            .padding(.horizontal, UIScale.pt(4))
            .background(
                RoundedRectangle(cornerRadius: UIScale.pt(7))
                    .fill(hovering ? DashSkin.inkFaint(dark).opacity(0.07) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { hovering = $0 }
    }

    private func meter(_ label: String, percent: Double, color: Color) -> some View {
        VStack(alignment: .leading, spacing: UIScale.pt(3)) {
            HStack(spacing: UIScale.pt(4)) {
                Text(label)
                    .font(.system(size: UIScale.pt(8.5), weight: .semibold))
                    .foregroundStyle(DashSkin.inkFaint(dark))
                Text(String(format: "%.0f%%", percent))
                    .font(DashSkin.mono(9.5))
                    .foregroundStyle(DashSkin.inkSoft(dark))
            }
            MeterBar(fraction: percent / 100, color: color, track: DashSkin.line(dark))
        }
        .frame(maxWidth: .infinity)
    }
}

enum MachinesMode: String {
    case fleet
    case workspace
    case machine
}

struct FleetChip: View {
    let title: String
    let subtitle: String
    let symbol: String
    let selected: Bool
    let dark: Bool
    let onSelect: () -> Void

    var body: some View {
        SelectableChipRow(
            icon: symbol, title: title, subtitle: subtitle, selected: selected, dark: dark,
            onSelect: onSelect
        ) { EmptyView() }
    }
}
