import SwiftUI

public struct SurfaceIntegrationCard: View {
    let tile: SurfaceTile
    let active: Bool
    let open: (String) -> Void
    @State private var usage: UsageTopicSnapshot?
    @State private var load = ContentLoad()
    @State private var sessions: SessionsSnapshot?
    @State private var report: CodeStatsReport?
    @State private var focus: AttentionFocusSession?
    @State private var error: String?
    @State private var loading = true
    @State private var retry = 0
    @State private var machines: [Machine] = []
    @Environment(\.surfacePresentation) private var presentation
    private let repository: AttentionRepository

    public init(
        tile: SurfaceTile, active: Bool = true,
        repository: AttentionRepository = AttentionRepository(), open: @escaping (String) -> Void
    ) {
        self.tile = tile
        self.active = active
        self.repository = repository
        self.open = open
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(10)) {
            if tile.showTitle || tile.showActions {
                HStack {
                    if tile.showTitle {
                        Label(tile.displayTitle, systemImage: tile.widget.icon).font(
                            .edithText(.headline)
                        )
                        .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if tile.showActions {
                        Button {
                            open(tile.widget.destination)
                        } label: {
                            Image(systemName: "arrow.up.right")
                        }
                        .buttonStyle(.edith(.borderless)).help("Open \(tile.widget.title)")
                        .accessibilityLabel("Open \(tile.widget.title)")
                    }
                }
            }
            if let error {
                Text(error).font(.edithText(.caption)).foregroundStyle(.secondary).lineLimit(3)
                Button("Retry") { retry += 1 }.font(.edithText(.caption))
            }
            if load.hasContent || error == nil, !loading {
                content
            } else if loading {
                LoadingIndicator()
            }
        }
        .padding(UIScale.pt(presentation?.padding ?? (tile.dense ? 10 : 14))).frame(
            maxWidth: .infinity, alignment: .leading
        )
        .background(
            Color.secondary.opacity(0.08),
            in: RoundedRectangle(cornerRadius: UIScale.pt(presentation?.cornerRadius ?? 12))
        )
        .task(id: "\(active):\(tile.widget.id):\(tile.days):\(retry)") {
            guard active else {
                loading = false
                return
            }
            repeat {
                await refresh()
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
            } while !Task.isCancelled
        }
    }

    @ViewBuilder private var content: some View {
        switch tile.widget {
        case .usage, .activity:
            if let usage {
                HStack {
                    metric(
                        "Total cost", String(format: "$%.2f", Double(usage.totalCostCents) / 100))
                    metric("Days", "\(usage.days)")
                }.presenterCover(.usage)
                if !tile.dense {
                    Text("Updated \(usage.refreshedAt.formatted(.dateTime.hour().minute()))")
                        .font(.edithText(.caption)).foregroundStyle(.secondary)
                }
            }
        case .agents:
            if let sessions {
                let agents = sessions.hosts.flatMap(\.agents)
                let blocked = agents.filter { $0.status == .blocked }.count
                HStack {
                    if tile.shows("running") { metric("Working", "\(sessions.working)") }
                    if tile.shows("waiting") { metric("Needs you", "\(blocked)") }
                    if tile.shows("total") { metric("Total", "\(sessions.total)") }
                }
                if tile.showDetails, tile.shows("sessions") {
                    ForEach(
                        Array(
                            agents.sorted { $0.status == .blocked && $1.status != .blocked }.prefix(
                                tile.itemLimit))
                    ) { agent in
                        HStack {
                            Circle().fill(agent.status == .blocked ? Color.orange : .green).frame(
                                width: 6, height: 6)
                            Text(agent.workspace).lineLimit(1)
                            Spacer(minLength: 0)
                            Text(agent.status.title).foregroundStyle(.secondary)
                        }.font(.edithText(.caption)).presenterCover(.usage)
                    }
                }
                if agents.isEmpty {
                    Text("No active sessions").font(.edithText(.caption)).foregroundStyle(
                        .secondary)
                }
            } else {
                Text("Open Agents to connect your sessions.").font(.edithText(.caption))
            }
        case .codeStats, .github:
            if let report {
                HStack {
                    if tile.shows("commits") { metric("Commits", "\(report.totals.commits)") }
                    if tile.shows("lines") {
                        metric("Lines", CodeStatsNumberFormat.compact(report.totals.authored))
                    }
                    if tile.shows("streak") { metric("Streak", "\(report.totals.currentStreak)d") }
                }
                if tile.showDetails, tile.shows("repositories") {
                    Text("Last \(tile.days) days · \(report.totals.repositories) repositories")
                        .font(.edithText(.caption)).foregroundStyle(.secondary)
                    ForEach(Array(report.repositories.prefix(tile.itemLimit)), id: \.repository) {
                        repo in
                        HStack {
                            Text(repo.repository).lineLimit(1)
                            Spacer()
                            Text("\(repo.commits)")
                        }
                        .font(.edithText(.caption)).presenterCover(.usage)
                    }
                }
            } else {
                Text("Set up your code stats mirror to see commit activity.").font(
                    .edithText(.caption)
                ).foregroundStyle(.secondary)
                Button("Set up Code Stats") { open("codeStats") }
            }
        case .focus:
            if let focus {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let seconds = max(
                        0,
                        Int(focus.plannedDuration - context.date.timeIntervalSince(focus.startedAt))
                    )
                    HStack {
                        Text(String(format: "%02d:%02d", seconds / 60, seconds % 60))
                            .font(.edithText(.title2)).monospacedDigit()
                        Spacer()
                        Button("Finish") { finishFocus() }.buttonStyle(.edith(.secondary))
                    }
                    if !tile.dense {
                        Text(focus.name.isEmpty ? "Deep work" : focus.name).font(
                            .edithText(.caption)
                        ).lineLimit(1)
                    }
                }
            } else {
                HStack {
                    Text("\(tile.focusMinutes) min").font(.edithText(.title2)).monospacedDigit()
                    Spacer()
                    Button("Start focus") { startFocus() }.buttonStyle(.edith(.secondary))
                }
            }
        case .machines:
            metric("Registered", "\(machines.count)")
            if !tile.dense {
                ForEach(Array(machines.prefix(3)), id: \.id) { machine in
                    Button(machine.name) { open("machines") }.font(.edithText(.caption))
                }
            }
            if machines.isEmpty { Button("Add a machine") { open("machines") } }
        case .desk:
            shortcuts([("Clipboard", "desk"), ("Desk tools", "desk")])
            Button("Pick a color") { IPC.post(IPC.Name.requestColorPick) }
                .font(.edithText(.caption))
        case .media:
            shortcuts([
                ("Music", "music"), ("Downloads", "downloads"), ("Studio", "studio"),
                ("Camera", "virtualCamera"),
            ])
        case .databases:
            Text("Browse connections, run queries, and inspect tables.").font(.edithText(.caption))
                .foregroundStyle(.secondary)
            Button("Open database workspace") { open("database") }.buttonStyle(.edith(.secondary))
        default:
            Text(tile.widget.summary).font(.edithText(.caption)).foregroundStyle(.secondary)
            Button("Open \(tile.widget.title)") { open(tile.widget.destination) }.buttonStyle(
                .edith(.secondary))
        }
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value).font(.edithText(.title3)).monospacedDigit()
            Text(title).font(.edithText(.caption)).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func shortcuts(_ items: [(String, String)]) -> some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading) {
            ForEach(items, id: \.0) { item in
                Button(item.0) { open(item.1) }.font(.edithText(.caption)).buttonStyle(
                    .edith(.secondary))
            }
        }
    }

    private func refresh() async {
        let request = load.begin()
        defer { if Task.isCancelled { load.cancel(request) } }
        do {
            switch tile.widget {
            case .usage, .activity:
                let next = try await AgentClient.shared.snapshotAsync(
                    UsageTopicSnapshot.self, topic: .usage)
                guard load.isCurrent(request) else { return }
                usage = next
                if let failure = next.failure {
                    throw NSError(
                        domain: "SurfaceUsage", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: failure])
                }
            case .agents:
                let next = try await AgentClient.shared.snapshotAsync(
                    SessionsSnapshot.self, topic: .sessions)
                guard load.isCurrent(request) else { return }
                sessions = next
            case .codeStats, .github:
                let next = try await CodeStatsAgentClient().report(.days(tile.days))
                guard load.isCurrent(request) else { return }
                report = next
            case .focus: focus = repository.activeFocus()
            case .machines: machines = MachineRegistry.machines()
            default: break
            }
            error = nil
            load.complete(request)
        } catch {
            guard load.isCurrent(request) else { return }
            load.fail(request, error: error)
            self.error = error.localizedDescription
        }
        loading = false
    }

    private func startFocus() {
        do {
            focus = try AttentionFocusOperationExecution.start(
                name: "Deep work", duration: Double(tile.focusMinutes * 60), repository: repository)
            error = nil
        } catch { self.error = error.localizedDescription }
    }
    private func finishFocus() {
        do {
            try AttentionFocusOperationExecution.stop(repository: repository)
            focus = nil
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}
