import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

struct FleetHomeView: View {
    let model: MachinesModel
    let onSelect: (UUID) -> Void
    var onAddMachine: () -> Void = {}
    @Environment(\.colorScheme) private var scheme
    @Environment(\.compactLayout) private var compact
    @Environment(\.windowVisible) private var windowVisible
    @State private var cpuHistory: [Double] = []
    @State private var memHistory: [Double] = []
    @State private var companionMachineID: UUID?

    private var dark: Bool { scheme == .dark }

    private var loaded: Bool {
        model.snapshots.allSatisfy { !$0.online } || model.fleet.memoryTotalKB > 0
    }

    var body: some View {
        PageScaffold(pinnedHeader: true, header: {}) {
            PageLoading(
                state: loaded ? .content : .loading, layout: .analytics,
                showsSkeletonControls: false
            ) {
                if FleetFirstRun.needsRemoteMachine(model.snapshots) { firstRunCard }
                fleetBanner
                metricsGrid
                storageCard
                if !model.fleet.alerts.isEmpty { alertsCard }
                machinesCard
            }
        }
        .machineActivity(model.allMachines.map { model.session(for: $0.id) })
        .pageRefresh(interval: { .seconds(MetricsCadence.sampleInterval) }) {
            let values = ExtensionSharedState.current?.values(for: "companion") ?? [:]
            let host = values["machineID"].flatMap(UUID.init(uuidString:))
            if companionMachineID != host { companionMachineID = host }
            let fleet = model.fleet
            cpuHistory = MachineSession.appending(fleet.cpuPercent, to: cpuHistory)
            memHistory = MachineSession.appending(fleet.memoryPercent, to: memHistory)
        }
    }

    private var fleetBanner: some View {
        let fleet = model.fleet
        return HStack(spacing: UIScale.pt(10)) {
            EdithIconView(.layers)
                .font(.edithText(.callout))
                .foregroundStyle(DashSkin.inkFaint(dark))
            Text(FleetFirstRun.onlineSummary(fleet))
                .font(.edithText(.callout).weight(.medium))
                .foregroundStyle(DashSkin.ink(dark))
                .lineLimit(1)
            Spacer(minLength: UIScale.pt(8))
            Text(bannerDetail(fleet))
                .font(.edithText(.caption).monospacedDigit())
                .foregroundStyle(DashSkin.inkFaint(dark))
                .lineLimit(1)
        }
        .padding(.horizontal, UIScale.pt(PageMetrics.cardPadding))
        .padding(.vertical, UIScale.pt(12))
        .widgetBar(
            cornerRadius: PageMetrics.cardCornerRadius, fill: DashSkin.paper2(dark),
            stroke: DashSkin.line(dark))
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
            columns: Array(
                repeating: GridItem(
                    .flexible(), spacing: UIScale.pt(PageMetrics.cardSpacing), alignment: .top),
                count: 2),
            spacing: UIScale.pt(PageMetrics.cardSpacing)
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
            PageCard(title: "Storage") {
                VStack(spacing: UIScale.pt(10)) {
                    ForEach(rows, id: \.id) { row in
                        VStack(alignment: .leading, spacing: UIScale.pt(5)) {
                            HStack {
                                Text(row.name)
                                    .font(.edithText(.callout).weight(.medium))
                                    .foregroundStyle(DashSkin.ink(dark))
                                    .lineLimit(1)
                                Spacer()
                                Text(
                                    "\(ByteFormatter.string(row.diskUsedKB * 1024)) of "
                                        + ByteFormatter.string(row.diskTotalKB * 1024)
                                )
                                .font(.edithText(.caption).monospacedDigit())
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
        PageCard(title: "Needs attention") {
            VStack(alignment: .leading, spacing: UIScale.pt(7)) {
                ForEach(model.fleet.alerts) { alert in
                    HStack(spacing: UIScale.pt(8)) {
                        EdithIconView(alert.icon)
                            .font(.edithText(.subheadline))
                            .foregroundStyle(
                                alert.kind == .updates ? DashSkin.gold : DashSkin.warn
                            )
                            .frame(width: UIScale.pt(16))
                        Text(alert.machineName)
                            .font(.edithText(.callout).weight(.medium))
                            .foregroundStyle(DashSkin.ink(dark))
                        Text(alert.detail)
                            .font(.edithText(.callout))
                            .foregroundStyle(DashSkin.inkFaint(dark))
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    private var firstRunCard: some View {
        FleetFirstRunCard(dark: dark, onAddMachine: onAddMachine)
    }

    private var machinesCard: some View {
        let snapshots = FleetMath.sortedByPressure(model.snapshots)
        return PageCard(title: "Machines") {
            VStack(spacing: UIScale.pt(0)) {
                ForEach(snapshots, id: \.id) { snapshot in
                    FleetMachineRow(
                        snapshot: snapshot, dark: dark,
                        hostsCompanion: snapshot.id == companionMachineID
                    ) {
                        onSelect(snapshot.id)
                    }
                    if snapshot.id != snapshots.last?.id {
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
    let hostsCompanion: Bool
    let onOpen: () -> Void
    @Environment(\.compactLayout) private var compact

    var body: some View {
        Button(action: onOpen) {
            Group {
                if compact {
                    VStack(alignment: .leading, spacing: UIScale.pt(10)) {
                        HStack(spacing: UIScale.pt(12)) {
                            EdithIconView(snapshot.isLocal ? .laptop : .server)
                                .font(.edithText(.body))
                                .foregroundStyle(DashSkin.inkSoft(dark))
                            VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                                Text(snapshot.name).font(.edithText(.body).weight(.medium))
                                    .lineLimit(1)
                                Text(snapshot.online ? snapshot.os : offlineDetail)
                                    .font(.edithText(.caption)).foregroundStyle(
                                        DashSkin.inkFaint(dark)
                                    )
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .help(snapshot.connectionFailure ?? "")
                            }
                            Spacer(minLength: 0)
                            if hostsCompanion {
                                EdithIconView(.companion).foregroundStyle(
                                    DashSkin.accent(dark))
                            }
                            if snapshot.online {
                                Text("\(snapshot.cores) cores").font(
                                    .edithText(.caption).monospacedDigit()
                                )
                                .foregroundStyle(DashSkin.inkFaint(dark))
                            }
                            EdithIconView(.chevronRight).font(.edithText(.caption))
                                .foregroundStyle(DashSkin.inkFaint(dark))
                        }
                        if snapshot.online {
                            HStack(spacing: UIScale.pt(12)) {
                                meter(
                                    "CPU", percent: snapshot.cpuPercent,
                                    color: DashSkin.accent(dark))
                                meter("MEM", percent: snapshot.memoryPercent, color: DashSkin.sage)
                                meter(
                                    "DISK", percent: snapshot.diskPercent,
                                    color: snapshot.diskPercent > FleetMath.diskWarningPercent
                                        ? DashSkin.danger : DashSkin.gold)
                            }
                        }
                    }
                } else {
                    HStack(spacing: UIScale.pt(12)) {
                        EdithIconView(snapshot.isLocal ? .laptop : .server)
                            .font(.edithText(.body))
                            .foregroundStyle(DashSkin.inkSoft(dark))
                            .frame(width: UIScale.pt(18))
                        VStack(alignment: .leading, spacing: UIScale.pt(1)) {
                            HStack(spacing: UIScale.pt(5)) {
                                Text(snapshot.name)
                                    .font(.edithText(.body).weight(.medium))
                                    .foregroundStyle(DashSkin.ink(dark))
                                if hostsCompanion {
                                    EdithIconView(.companion)
                                        .font(.system(size: UIScale.pt(9.5)))
                                        .foregroundStyle(DashSkin.accent(dark))
                                        .help("Runs Memory")
                                }
                            }
                            Text(snapshot.online ? snapshot.os : "Not connected")
                                .font(.edithText(.caption))
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
                                .font(.edithText(.caption).monospacedDigit())
                                .foregroundStyle(DashSkin.inkFaint(dark))
                                .frame(width: UIScale.pt(60), alignment: .trailing)
                        } else {
                            Text(offlineDetail)
                                .font(.edithText(.callout))
                                .foregroundStyle(DashSkin.inkFaint(dark))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(snapshot.connectionFailure ?? "")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        EdithIconView(.chevronRight)
                            .font(.system(size: UIScale.pt(9)))
                            .foregroundStyle(DashSkin.inkFaint(dark))
                    }
                }
            }
            .padding(.vertical, UIScale.pt(1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.edith(.row))
    }

    private var offlineDetail: String {
        snapshot.connectionFailure ?? "Open this machine to connect"
    }

    private func meter(_ label: String, percent: Double, color: Color) -> some View {
        VStack(alignment: .leading, spacing: UIScale.pt(3)) {
            HStack(alignment: .firstTextBaseline, spacing: UIScale.pt(4)) {
                PageCapsLabel(label)
                Text(String(format: "%.0f%%", percent))
                    .font(.edithText(.caption2).monospacedDigit())
                    .foregroundStyle(DashSkin.inkSoft(dark))
            }
            MeterBar(fraction: percent / 100, color: color, track: DashSkin.line(dark))
        }
        .frame(maxWidth: .infinity)
    }
}

enum FleetFirstRun {
    static func needsRemoteMachine(_ snapshots: [MachineSnapshot]) -> Bool {
        !snapshots.contains { !$0.isLocal }
    }

    static func onlineSummary(_ fleet: FleetSummary) -> String {
        if fleet.machinesTotal == 1 {
            return fleet.machinesOnline == 1 ? "1 machine online" : "1 machine, offline"
        }
        return "\(fleet.machinesOnline) of \(fleet.machinesTotal) machines online"
    }
}

private struct FleetFirstRunCard: View {
    let dark: Bool
    let onAddMachine: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: UIScale.pt(16)) {
                PageGuideBadge(icon: .server, size: 48)
                copy.frame(maxWidth: UIScale.pt(560), alignment: .leading)
                Spacer(minLength: UIScale.pt(16))
                addButton
            }
            VStack(alignment: .leading, spacing: UIScale.pt(16)) {
                HStack(alignment: .center, spacing: UIScale.pt(12)) {
                    PageGuideBadge(icon: .server, size: 40)
                    Text(FleetFirstRunCopy.title)
                        .font(.edithText(.headline)).fontWeight(.semibold)
                        .foregroundStyle(DashSkin.ink(dark))
                        .fixedSize(horizontal: false, vertical: true)
                }
                details
                addButton
            }
        }
        .padding(UIScale.pt(20))
        .frame(maxWidth: .infinity, alignment: .leading)
        .widgetBar(
            cornerRadius: PageMetrics.cardCornerRadius, fill: DashSkin.paper2(dark),
            stroke: DashSkin.line(dark)
        )
        .accessibilityElement(children: .contain)
    }

    private var copy: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(4)) {
            Text(FleetFirstRunCopy.title)
                .font(.edithText(.headline)).fontWeight(.semibold)
                .foregroundStyle(DashSkin.ink(dark))
                .accessibilityAddTraits(.isHeader)
            details
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(8)) {
            Text(FleetFirstRunCopy.message)
                .font(.edithText(.callout)).foregroundStyle(DashSkin.inkSoft(dark))
                .fixedSize(horizontal: false, vertical: true)
            Text(FleetFirstRunCopy.footnote)
                .font(.edithText(.caption)).foregroundStyle(DashSkin.inkFaint(dark))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var addButton: some View {
        Button(action: onAddMachine) {
            Label("Add machine", edith: .plus)
        }
        .buttonStyle(.edith(.primary))
        .keyboardShortcut(.defaultAction)
        .fixedSize()
        .accessibilityIdentifier("machines.first-run.add")
    }
}

enum FleetFirstRunCopy {
    static let title = "Add your first remote machine"
    static let message =
        "Connect a server, a Raspberry Pi or any computer you can reach over SSH. Its CPU, memory and disk show up here, and you can open a terminal, browse its files and manage its containers."
    static let footnote =
        "Edith signs in with your SSH keys or a password saved in your keychain. Removing a machine later only forgets it."
}

enum MachinesMode: String {
    case fleet
    case workspace
    case machine
}
