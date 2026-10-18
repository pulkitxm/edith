import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

struct HerdrNotchAgentsCard: View {
    let store: HerdrStore
    let monitor: AgentActivityMonitor
    private var presenterState = PresenterState.shared
    @Environment(\.automaticViewActionsEnabled) private var automaticActions

    init(store: HerdrStore, monitor: AgentActivityMonitor) {
        self.store = store
        self.monitor = monitor
    }

    private var tile: SurfaceTile {
        var tile = SurfaceTile(.agents)
        tile.itemLimit = 20
        tile.dense = true
        return tile
    }

    private var presentation: AgentActivityPresentation {
        AgentActivityPresentation(
            activity: monitor.activity,
            terminals: monitor.terminals.snapshot(
                hosts: Array(store.hosts.prefix(64)), enabled: monitor.discoversTerminals),
            tile: tile, now: monitor.now, observedAt: monitor.terminals.observedAt)
    }

    private var emptyMessage: String {
        if !monitor.activity.settings.enabled && !monitor.discoversTerminals {
            return "Agent observation is off. Connect providers or enable terminal discovery."
        }
        if monitor.activity.providerSignals.isEmpty && monitor.activity.settings.enabled {
            return
                "Waiting for a provider event. Start or resume a session after configuring its hooks."
        }
        return "No sessions match this widget."
    }

    var body: some View {
        let presentation = presentation
        let tile = tile
        ScrollView {
            VStack(alignment: .leading, spacing: UIScale.pt(8)) {
                LazyVGrid(
                    columns: tile.metricGrid(minimum: 64), alignment: .leading,
                    spacing: UIScale.pt(8)
                ) {
                    metric("Working", presentation.working, color: .green)
                    metric("Needs you", presentation.waiting, color: .orange)
                    metric("Active", presentation.active, color: .secondary)
                    if monitor.activity.settings.monitorTerminalAttention {
                        metric("Stuck", presentation.stuck, color: .red)
                    } else {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Off").font(.edithText(.title2))
                            Text("Stuck detection").font(.edithText(.caption))
                                .foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                let approvals = monitor.activity.approvals
                ForEach(Array(approvals.prefix(tile.itemLimit))) { request in
                    AgentApprovalCard(request: request, monitor: monitor, dense: true)
                }
                ForEach(Array(presentation.rows.prefix(tile.itemLimit))) { row in session(row) }
                if presentation.rows.isEmpty && approvals.isEmpty {
                    Text(emptyMessage).font(.edithText(.caption)).foregroundStyle(.secondary)
                }
            }
            .padding(UIScale.pt(10))
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(
                Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: UIScale.pt(12))
            )
            .padding(.horizontal, 12).padding(.bottom, 12)
        }
        .task(id: automaticActions) {
            if automaticActions { await store.watch() } else { store.stopWatching() }
        }
        .task { await monitor.observe() }
    }

    private func metric(_ title: String, _ count: Int, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("\(count)").font(.edithText(.title2)).monospacedDigit()
                .foregroundStyle(count > 0 ? color : .primary)
            Text(title).font(.edithText(.caption)).foregroundStyle(.secondary).lineLimit(1)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func session(_ row: AgentActivityRow) -> some View {
        VStack(alignment: .leading, spacing: UIScale.pt(4)) {
            HStack(spacing: UIScale.pt(6)) {
                Circle().fill(AgentActivityStyle.color(row.phase)).frame(width: 6, height: 6)
                Text(row.title).font(.edithText(.callout)).fontWeight(.medium).lineLimit(2)
                    .multilineTextAlignment(.leading)
                if row.isSubagent { Image(systemName: "arrow.turn.down.right") }
                Spacer(minLength: 0)
            }
            HStack(spacing: UIScale.pt(6)) {
                Text(row.providerTitle)
                Text(row.phase.title).foregroundStyle(AgentActivityStyle.color(row.phase))
                Spacer(minLength: 0)
                Text(
                    Duration.seconds(max(0, monitor.now.timeIntervalSince(row.startedAt)))
                        .formatted(
                            .units(
                                allowed: [.hours, .minutes, .seconds], width: .abbreviated,
                                maximumUnitCount: 2))
                ).monospacedDigit()
            }.font(.edithText(.caption)).foregroundStyle(.secondary)
            if let tool = row.tool {
                Text(tool + (row.detail.map { ": " + $0 } ?? "")).font(.edithText(.caption))
                    .lineLimit(1).foregroundStyle(.secondary)
            }
        }.presenterCover(presenterState.hidesAgents)
    }
}
