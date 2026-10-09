import SwiftUI

public struct AgentActivityCard: View {
    private let tile: SurfaceTile
    private let active: Bool
    private let allApprovals: Bool
    private let fixture: AgentActivitySnapshot?
    private let fixtureTerminals: SessionsSnapshot?
    @State private var monitor: AgentActivityMonitor
    @Environment(\.surfacePresentation) private var surface
    @Environment(\.surfaceFillHeight) private var fillHeight

    @MainActor public init(
        tile: SurfaceTile, active: Bool = true, activity: AgentActivitySnapshot? = nil,
        terminals: SessionsSnapshot? = nil, monitor: AgentActivityMonitor? = nil,
        allApprovals: Bool = false
    ) {
        self.tile = tile
        self.active = active
        self.allApprovals = allApprovals
        fixture = activity
        fixtureTerminals = terminals
        _monitor = State(initialValue: monitor ?? .shared)
    }

    private var snapshot: AgentActivitySnapshot { fixture ?? monitor.activity }
    private var terminals: SessionsSnapshot? {
        fixture == nil ? monitor.terminals : fixtureTerminals
    }
    private var presentation: AgentActivityPresentation {
        AgentActivityPresentation(
            activity: snapshot, terminals: terminals,
            tile: tile, now: fixture?.refreshedAt ?? monitor.now,
            observedAt: fixture == nil ? monitor.observedAt : [:])
    }

    private var approvals: [AgentApprovalRequest] {
        allApprovals ? snapshot.approvals : presentation.approvals
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(tile.dense ? 8 : 12)) {
            if tile.showTitle || tile.showActions {
                HStack {
                    if tile.showTitle {
                        Label(tile.displayTitle, systemImage: "terminal").font(
                            .edithText(.headline))
                    }
                    Spacer(minLength: 0)
                    if tile.showActions {
                        Button {
                            MainApp.openSettings(tab: "agentActivity")
                        } label: {
                            Image(systemName: "slider.horizontal.3")
                        }.buttonStyle(.edith(.borderless)).help("Agent connections")
                    }
                }
            }
            if fixture == nil, let error = monitor.load.errorMessage {
                Text(error).font(.edithText(.caption)).foregroundStyle(.secondary).lineLimit(3)
                Button("Reconnect") { monitor.retry() }.buttonStyle(.edith(.secondary))
            }
            if fixture == nil, !monitor.load.hasContent, monitor.load.isRunning {
                LoadingIndicator()
            } else {
                metrics
                if tile.shows("approvals"), !approvals.isEmpty {
                    ForEach(Array(approvals.prefix(tile.itemLimit))) { request in
                        AgentApprovalCard(
                            request: request, monitor: monitor, dense: tile.dense,
                            showsActions: tile.showActions && fixture == nil)
                    }
                    if approvals.count > tile.itemLimit {
                        Button("View all \(approvals.count) requests") {
                            MainApp.openSettings(tab: "agentActivity")
                        }
                        .font(.edithText(.caption)).buttonStyle(.edith(.borderless))
                    }
                }
                if tile.showDetails, tile.shows("sessions") {
                    ForEach(Array(presentation.rows.prefix(tile.itemLimit))) { row in session(row) }
                }
                if presentation.rows.isEmpty && approvals.isEmpty {
                    Text(emptyMessage).font(.edithText(.caption)).foregroundStyle(.secondary)
                    if tile.showActions && !snapshot.settings.enabled {
                        Button("Connect an agent") { MainApp.openSettings(tab: "agentActivity") }
                            .buttonStyle(.edith(.secondary))
                    }
                }
            }
        }
        .padding(UIScale.pt(surface?.padding ?? (tile.dense ? 10 : 14)))
        .frame(maxWidth: .infinity, maxHeight: fillHeight ? .infinity : nil, alignment: .topLeading)
        .background(
            Color.secondary.opacity(0.08),
            in: RoundedRectangle(cornerRadius: UIScale.pt(surface?.cornerRadius ?? 12))
        )
        .task(id: active) {
            guard active, fixture == nil else { return }
            await monitor.observe()
        }
    }

    private var emptyMessage: String {
        if tile.sourceIDs?.isEmpty == true || tile.agentPhases?.isEmpty == true {
            return "Choose providers and states in the widget inspector."
        }
        if !snapshot.settings.enabled && terminals == nil {
            return "Agent observation is off. Connect providers or enable terminal discovery."
        }
        if snapshot.providerSignals.isEmpty && snapshot.settings.enabled {
            return
                "Waiting for a provider event. Start or resume a session after configuring its hooks."
        }
        return "No sessions match this widget."
    }

    private var metrics: some View {
        LazyVGrid(
            columns: tile.metricGrid(minimum: tile.dense ? 64 : 80),
            alignment: .leading, spacing: UIScale.pt(8)
        ) {
            if tile.shows("running") { metric("Working", presentation.working, color: .green) }
            if tile.shows("waiting") { metric("Needs you", presentation.waiting, color: .orange) }
            if tile.shows("total") { metric("Active", presentation.active, color: .secondary) }
            if tile.shows("stuck") {
                if snapshot.settings.monitorTerminalAttention
                    || (fixture == nil
                        && AgentAttentionSettings(defaults: SharedDefaults.store).stuckMonitoring)
                {
                    metric("Stuck", presentation.stuck, color: .red)
                } else {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Off").font(.edithText(.title2))
                        Text("Stuck detection").font(.edithText(.caption)).foregroundStyle(
                            .secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if tile.shows("quiet") { metric("No signal", presentation.quiet, color: .secondary) }
            if tile.shows("errors") { metric("Errors", presentation.errors, color: .red) }
            if tile.shows("subagents") {
                metric("Subagents", presentation.subagents, color: .secondary)
            }
        }
    }

    private func metric(_ title: String, _ count: Int, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("\(count)").font(.edithText(.title2)).monospacedDigit()
                .foregroundStyle(tile.accent && count > 0 ? color : .primary)
            Text(title).font(.edithText(.caption)).foregroundStyle(.secondary).lineLimit(1)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func session(_ row: AgentActivityRow) -> some View {
        VStack(alignment: .leading, spacing: UIScale.pt(4)) {
            HStack(spacing: UIScale.pt(6)) {
                Circle().fill(AgentActivityStyle.color(row.phase)).frame(width: 6, height: 6)
                Text(row.title).font(.edithText(.callout)).fontWeight(.medium).lineLimit(2)
                    .multilineTextAlignment(.leading).help(row.title)
                if row.isSubagent { Image(systemName: "arrow.turn.down.right").help("Subagent") }
                Spacer(minLength: 0)
                if tile.showActions, let terminal = row.terminal {
                    Button {
                        HerdrOpenRequests.submit(
                            HerdrOpenRequest(
                                agentID: terminal.id, hostID: terminal.machineID, view: .agent))
                        MainApp.open(section: "herdr")
                    } label: {
                        Image(systemName: "arrow.up.right")
                    }
                    .buttonStyle(.edith(.borderless)).help("Open agent terminal")
                }
            }
            if tile.shows("project"), row.title != row.projectTitle, !row.project.isEmpty {
                Text(row.projectTitle).font(.edithText(.caption)).foregroundStyle(.secondary)
                    .lineLimit(1).help(row.project)
            }
            HStack(spacing: UIScale.pt(6)) {
                if tile.shows("provider") { Text(row.providerTitle) }
                Text(row.phase.title).foregroundStyle(AgentActivityStyle.color(row.phase))
                Spacer(minLength: 0)
                if tile.shows("elapsed") {
                    Text(
                        Duration.seconds(
                            max(
                                0,
                                (fixture?.refreshedAt ?? monitor.now).timeIntervalSince(
                                    row.startedAt))
                        )
                        .formatted(
                            .units(
                                allowed: [.hours, .minutes, .seconds], width: .abbreviated,
                                maximumUnitCount: 2))
                    )
                    .monospacedDigit()
                }
            }.font(.edithText(.caption)).foregroundStyle(.secondary)
            if tile.shows("tool"), let tool = row.tool {
                Text(tool + (row.detail.map { ": " + $0 } ?? "")).font(.edithText(.caption))
                    .lineLimit(tile.dense ? 1 : 2).foregroundStyle(.secondary)
            }
            if tile.shows("model"), let model = row.model {
                Text(model).font(.edithText(.caption2)).foregroundStyle(.secondary).lineLimit(1)
            }
            if tile.shows("source") {
                HStack {
                    Text(row.sourceTitle)
                    Spacer(minLength: 0)
                    Text(row.updatedAt, style: .relative)
                }.font(.edithText(.caption2)).foregroundStyle(.secondary)
            }
        }.presenterCover(.agents)
    }
}

public struct AgentApprovalCard: View {
    public let request: AgentApprovalRequest
    public let monitor: AgentActivityMonitor
    public var dense: Bool
    public var showsActions: Bool
    @State private var detailHeight: CGFloat = 20
    @State private var input: AgentApprovalInput

    public init(
        request: AgentApprovalRequest, monitor: AgentActivityMonitor, dense: Bool = false,
        showsActions: Bool = true
    ) {
        self.request = request
        self.monitor = monitor
        self.dense = dense
        self.showsActions = showsActions
        _input = State(initialValue: AgentApprovalInput(request.detail))
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(8)) {
            HStack {
                Label(request.tool, systemImage: "hand.raised.fill").font(.edithText(.callout))
                Spacer(minLength: 0)
                Text("\(max(0, Int(request.expiresAt.timeIntervalSince(monitor.now))))s").font(
                    .edithText(.caption)
                ).monospacedDigit().foregroundStyle(.secondary)
            }
            Text(
                request.provider.title + " · "
                    + URL(fileURLWithPath: request.project).lastPathComponent
            )
            .font(.edithText(.caption)).foregroundStyle(.secondary).lineLimit(1)
            .presenterCover(.agents)
            ScrollView {
                VStack(alignment: .leading, spacing: UIScale.pt(10)) {
                    ForEach(input.fields) { field in
                        VStack(alignment: .leading, spacing: UIScale.pt(4)) {
                            if input.fields.count > 1 || field.id != "details" {
                                Text(field.title).font(.edithText(.caption2)).foregroundStyle(
                                    .secondary)
                            }
                            Text(field.value).font(.edithText(.caption)).monospaced().textSelection(
                                .enabled
                            )
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) {
                    $0.size.height
                } action: {
                    detailHeight = $0
                }
            }.frame(height: min(UIScale.pt(dense ? 64 : 120), detailHeight)).presenterCover(.agents)
            if let error = monitor.decisionErrors[request.id] {
                Text(error).font(.edithText(.caption)).foregroundStyle(.red)
            }
            if showsActions {
                HStack {
                    Button("Deny") { Task { await monitor.decide(request, choice: .deny) } }
                        .buttonStyle(.edith(.secondary))
                    Spacer(minLength: 0)
                    Button("Allow once") {
                        Task { await monitor.decide(request, choice: .allowOnce) }
                    }.buttonStyle(.edith(.primary))
                }.disabled(
                    monitor.deciding.contains(request.id) || request.expiresAt <= monitor.now)
            }
        }
        .padding(UIScale.pt(10)).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: UIScale.pt(10)))
        .overlay(RoundedRectangle(cornerRadius: UIScale.pt(10)).stroke(Color.orange.opacity(0.3)))
    }
}

public enum AgentActivityStyle {
    public static func color(_ phase: AgentActivityPhase) -> Color {
        switch phase {
        case .working: .green
        case .permission, .blocked, .waiting: .orange
        case .error, .stuck: .red
        case .finished: .blue
        case .idle, .quiet, .ended: .secondary
        }
    }
}
