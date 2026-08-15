import AppKit
import EdithKit
import SwiftUI

struct DockerContainerList: View {
    let session: MachineSession
    let query: String
    let dark: Bool
    let busyIDs: Set<String>
    let onOpen: (DockerContainer) -> Void
    let onAction: (DockerContainer, String) -> Void
    let onShell: (DockerContainer) -> Void
    let onRemove: (DockerContainer) -> Void
    let onGroupAction: (String, [DockerContainer], String) -> Void

    static let groupKeyPrefix = "group:"

    static func groupKey(_ project: String?) -> String { "\(groupKeyPrefix)\(project ?? "")" }

    private var filtered: [DockerContainer] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return session.containers }
        return session.containers.filter {
            $0.displayName.localizedCaseInsensitiveContains(trimmed)
                || $0.image.localizedCaseInsensitiveContains(trimmed)
                || ($0.composeProject ?? "").localizedCaseInsensitiveContains(trimmed)
        }
    }

    private var groups: [(project: String?, containers: [DockerContainer])] {
        let grouped = Dictionary(grouping: filtered) { $0.composeProject }
        let projects = grouped.keys.compactMap { $0 }
            .sorted(by: DockerProjectOrder.before)
        var result: [(String?, [DockerContainer])] = projects.map { project in
            (project, (grouped[project] ?? []).sorted { $0.displayName < $1.displayName })
        }
        if let standalone = grouped[nil], !standalone.isEmpty {
            result.append((nil, standalone.sorted { $0.displayName < $1.displayName }))
        }
        return result
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                if !session.containersLoaded {
                    ListRowsSkeleton(rows: 5, dark: dark)
                } else if filtered.isEmpty {
                    Text("No containers.")
                        .font(.system(size: UIScale.pt(12)))
                        .foregroundStyle(DashSkin.inkFaint(dark))
                        .padding(UIScale.pt(20))
                }
                ForEach(groups, id: \.project) { group in
                    Section {
                        ForEach(group.containers) { container in
                            DockerContainerRow(
                                container: container, dark: dark,
                                busy: busyIDs.contains(container.id),
                                onOpen: { onOpen(container) },
                                onAction: { onAction(container, $0) },
                                onShell: { onShell(container) },
                                onRemove: { onRemove(container) })
                            Divider().opacity(0.2)
                        }
                    } header: {
                        HStack(spacing: UIScale.pt(6)) {
                            Image(systemName: DockerProjectOrder.symbol(group.project))
                                .font(.system(size: UIScale.pt(10)))
                            Text(DockerProjectOrder.title(group.project))
                                .font(.system(size: UIScale.pt(11), weight: .semibold))
                            if DockerProjectOrder.isCompanion(group.project) {
                                Text("Edith")
                                    .font(DashSkin.mono(9))
                                    .padding(.horizontal, UIScale.pt(5))
                                    .padding(.vertical, UIScale.pt(1))
                                    .background(DashSkin.accent(dark).opacity(0.18))
                                    .clipShape(Capsule())
                                    .foregroundStyle(DashSkin.accent(dark))
                            }
                            Text("\(group.containers.count)")
                                .font(DashSkin.mono(10))
                                .foregroundStyle(DashSkin.inkFaint(dark))
                            Spacer(minLength: 0)
                            groupSwitch(group.project, group.containers)
                        }
                        .foregroundStyle(DashSkin.inkSoft(dark))
                        .padding(.horizontal, UIScale.pt(16))
                        .padding(.vertical, UIScale.pt(6))
                        .background(.thinMaterial)
                    }
                }
            }
        }
    }

    private static func groupHelp(_ verb: String, _ count: Int, _ noun: String) -> String {
        "\(verb) the \(count) \(noun) container" + (count == 1 ? "" : "s") + " in this group"
    }

    @ViewBuilder
    private func groupSwitch(_ project: String?, _ containers: [DockerContainer]) -> some View {
        let key = Self.groupKey(project)
        let plan = DockerGroupPlan(containers: containers)
        if busyIDs.contains(key) {
            ProgressView().controlSize(.small).scaleEffect(0.5).frame(width: UIScale.pt(20))
        } else {
            HStack(spacing: UIScale.pt(4)) {
                if plan.canStart {
                    Button {
                        onGroupAction(key, plan.startable, "start")
                    } label: {
                        Image(systemName: "play.fill")
                            .font(.system(size: UIScale.pt(9.5)))
                    }
                    .buttonStyle(HoverButtonStyle())
                    .help(Self.groupHelp("Start", plan.startable.count, "stopped"))
                }
                if plan.canStop {
                    Button {
                        onGroupAction(key, plan.stoppable, "stop")
                    } label: {
                        Image(systemName: "stop.fill")
                            .font(.system(size: UIScale.pt(9.5)))
                    }
                    .buttonStyle(HoverButtonStyle())
                    .help(Self.groupHelp("Stop", plan.stoppable.count, "running"))
                }
            }
        }
    }
}

private struct DockerContainerRow: View {
    let container: DockerContainer
    let dark: Bool
    let busy: Bool
    let onOpen: () -> Void
    let onAction: (String) -> Void
    let onShell: () -> Void
    let onRemove: () -> Void
    @State private var hovering = false

    private var stateColor: Color {
        switch container.state {
        case .running: return container.health == .unhealthy ? DashSkin.warn : DashSkin.ok
        case .paused, .restarting: return DashSkin.gold
        default: return DashSkin.inkFaint(dark)
        }
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(density: .full)
            row(density: .medium)
            row(density: .compact)
        }
        .padding(.horizontal, UIScale.pt(16))
        .padding(.vertical, UIScale.pt(9))
        .background(hovering ? DashSkin.inkFaint(dark).opacity(0.06) : .clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2, perform: onOpen)
        .contextMenu {
            Button("Open Details", action: onOpen)
            Button(container.state.isRunning ? "Stop" : "Start") {
                onAction(container.state.isRunning ? "stop" : "start")
            }
            Button("Restart") { onAction("restart") }
            Button(container.state == .paused ? "Unpause" : "Pause") {
                onAction(container.state == .paused ? "unpause" : "pause")
            }
            Button("Shell", action: onShell).disabled(!container.state.isRunning)
            Divider()
            Button("Copy ID") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(container.id, forType: .string)
            }
            Divider()
            Button("Remove", role: .destructive, action: onRemove)
        }
    }

    private enum RowDensity {
        case full
        case medium
        case compact

        var nameWidth: Double {
            return switch self {
            case .full: 230
            case .medium: 190
            case .compact: 150
            }
        }

        var showsStatus: Bool { self != .compact }
        var showsPorts: Bool { self == .full }
        var showsMemory: Bool { self != .compact }
    }

    private func row(density: RowDensity) -> some View {
        HStack(spacing: UIScale.pt(12)) {
            Circle().fill(stateColor).frame(width: UIScale.pt(8), height: UIScale.pt(8))
            VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                Text(container.composeService ?? container.displayName)
                    .font(.system(size: UIScale.pt(13), weight: .medium))
                    .foregroundStyle(DashSkin.ink(dark))
                    .lineLimit(1)
                Text(container.image)
                    .font(DashSkin.mono(10))
                    .foregroundStyle(DashSkin.inkFaint(dark))
                    .lineLimit(1)
            }
            .frame(width: UIScale.pt(density.nameWidth), alignment: .leading)
            if density.showsStatus {
                Text(container.status)
                    .font(.system(size: UIScale.pt(11)))
                    .foregroundStyle(DashSkin.inkSoft(dark))
                    .lineLimit(1)
                    .frame(width: UIScale.pt(density == .full ? 150 : 120), alignment: .leading)
            }
            if density.showsPorts {
                portsView.frame(width: UIScale.pt(160), alignment: .leading)
            }
            Text(container.cpuPercent.map { String(format: "%.1f%%", $0) } ?? "—")
                .font(DashSkin.mono(11))
                .foregroundStyle(DashSkin.inkSoft(dark))
                .frame(width: UIScale.pt(54), alignment: .trailing)
            if density.showsMemory {
                Text(container.memUsedBytes.map { ByteFormatter.string($0) } ?? "—")
                    .font(DashSkin.mono(11))
                    .foregroundStyle(DashSkin.inkSoft(dark))
                    .frame(width: UIScale.pt(70), alignment: .trailing)
            }
            Spacer(minLength: 0)
            actions
        }
    }

    @ViewBuilder
    private var portsView: some View {
        HStack(spacing: UIScale.pt(4)) {
            ForEach(container.ports.prefix(2), id: \.self) { port in
                if let url = port.browserURL {
                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
                        Text(port.displayName)
                            .font(DashSkin.mono(9.5))
                            .padding(.horizontal, UIScale.pt(5))
                            .padding(.vertical, UIScale.pt(2))
                            .background(DashSkin.accent(dark).opacity(0.15), in: Capsule())
                            .foregroundStyle(DashSkin.accent(dark))
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                } else {
                    Text(port.displayName)
                        .font(DashSkin.mono(9.5))
                        .padding(.horizontal, UIScale.pt(5))
                        .padding(.vertical, UIScale.pt(2))
                        .background(DashSkin.line(dark), in: Capsule())
                        .foregroundStyle(DashSkin.inkFaint(dark))
                }
            }
        }
    }

    private var actions: some View {
        HStack(spacing: UIScale.pt(2)) {
            if busy {
                ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: UIScale.pt(24))
            } else {
                Button {
                    onAction(container.state.isRunning ? "stop" : "start")
                } label: {
                    Image(systemName: container.state.isRunning ? "stop.fill" : "play.fill")
                }
                .buttonStyle(HoverButtonStyle())
                .help(container.state.isRunning ? "Stop" : "Start")
            }
            Button(action: onOpen) {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(HoverButtonStyle())
            .help("Open details")
        }
        .font(.system(size: UIScale.pt(11)))
    }
}

struct DockerSimpleList: View {
    let rows: [DockerRow]
    let dark: Bool
    let onDelete: ((String) -> Void)?

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if rows.isEmpty {
                    Text("Nothing here.")
                        .font(.system(size: UIScale.pt(12)))
                        .foregroundStyle(DashSkin.inkFaint(dark))
                        .padding(UIScale.pt(20))
                }
                ForEach(rows) { row in
                    HStack(spacing: UIScale.pt(12)) {
                        Image(systemName: row.symbol)
                            .foregroundStyle(DashSkin.inkFaint(dark))
                            .frame(width: UIScale.pt(16))
                        VStack(alignment: .leading, spacing: UIScale.pt(1)) {
                            Text(row.title)
                                .font(.system(size: UIScale.pt(12.5)))
                                .foregroundStyle(DashSkin.ink(dark))
                                .lineLimit(1)
                            Text(row.subtitle)
                                .font(DashSkin.mono(10))
                                .foregroundStyle(DashSkin.inkFaint(dark))
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        if let badge = row.badge {
                            Text(badge)
                                .font(.system(size: UIScale.pt(9.5), weight: .medium))
                                .padding(.horizontal, UIScale.pt(6))
                                .padding(.vertical, UIScale.pt(2))
                                .background(DashSkin.sage.opacity(0.18), in: Capsule())
                                .foregroundStyle(DashSkin.sage)
                        }
                        Text(row.trailing)
                            .font(DashSkin.mono(11))
                            .foregroundStyle(DashSkin.inkSoft(dark))
                        if let onDelete {
                            Button {
                                onDelete(row.id)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(HoverButtonStyle())
                            .help("Remove")
                        }
                    }
                    .padding(.horizontal, UIScale.pt(16))
                    .padding(.vertical, UIScale.pt(9))
                    Divider().opacity(0.2)
                }
            }
        }
    }
}

struct DockerUsageView: View {
    let session: MachineSession
    let dark: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: UIScale.pt(12)) {
                ForEach(session.diskUsage, id: \.type) { usage in
                    VStack(alignment: .leading, spacing: UIScale.pt(6)) {
                        HStack {
                            Text(usage.type)
                                .font(.system(size: UIScale.pt(13), weight: .medium))
                                .foregroundStyle(DashSkin.ink(dark))
                            Spacer()
                            Text(ByteFormatter.string(usage.sizeBytes))
                                .font(DashSkin.mono(12))
                                .foregroundStyle(DashSkin.ink(dark))
                        }
                        MeterBar(
                            fraction: usage.sizeBytes > 0
                                ? Double(usage.sizeBytes - usage.reclaimableBytes)
                                    / Double(usage.sizeBytes) : 0,
                            color: DashSkin.accent(dark), track: DashSkin.line(dark))
                        Text(
                            "\(usage.active) active of \(usage.totalCount)  ·  "
                                + "\(ByteFormatter.string(usage.reclaimableBytes)) reclaimable"
                        )
                        .font(.system(size: UIScale.pt(10.5)))
                        .foregroundStyle(DashSkin.inkFaint(dark))
                    }
                    .padding(UIScale.pt(14))
                    .background(
                        DashSkin.paper2(dark), in: RoundedRectangle(cornerRadius: UIScale.pt(12)))
                }
            }
            .padding(UIScale.pt(16))
        }
    }
}
