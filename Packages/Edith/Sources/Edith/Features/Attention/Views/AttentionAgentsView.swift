import EdithKit
import SwiftUI

struct AttentionAgentsView: View {
    @Bindable var model: AttentionPageModel
    @Environment(\.compactLayout) private var compact
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let agents = model.summary.agents
        let dark = scheme == .dark
        let violet = AttentionPalette.accent(dark)
        let interval = model.period.interval()
        VStack(alignment: .leading, spacing: UIScale.pt(14)) {
            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.flexible(), spacing: UIScale.pt(12)),
                    count: compact ? 2 : 5),
                spacing: UIScale.pt(12)
            ) {
                AttentionTile(
                    label: "Agent work", value: AttentionFormat.duration(agents.working),
                    detail: AttentionFormat.delta(
                        agents.working, model.summary.previous?.agentWorking),
                    tint: violet, symbol: "sparkles")
                AttentionTile(
                    label: "Waiting on you", value: AttentionFormat.duration(agents.blocked),
                    detail: "blocked for input or approval",
                    tint: DashSkin.inkSoft(dark),
                    symbol: "hand.raised")
                AttentionTile(
                    label: "Peak at once", value: "\(agents.peakConcurrent)",
                    detail: "agents working together", tint: violet,
                    symbol: "square.stack.3d.up")
                AttentionTile(
                    label: "Sessions", value: "\(agents.sessions.count)",
                    detail: "\(agents.machines.count) machines · \(agents.kinds.count) kinds",
                    tint: violet, symbol: "terminal")
                AttentionTile(
                    label: "Leverage",
                    value: agents.attended > 0
                        ? String(format: "%.1f×", agents.working / agents.attended) : "n/a",
                    detail:
                        "agent time per minute you watched \(AttentionFormat.duration(agents.attended))",
                    tint: violet, symbol: "arrow.up.right")
            }
            if agents.isEmpty {
                AttentionPanel("Agents") {
                    AttentionEmpty(
                        text: model.settings.agentTrackingEnabled
                            ? "Edith records every Herdr agent that is working or waiting, on every machine. Activity appears here as sessions run."
                            : "Agent tracking is off. Turn it on in Attention settings.",
                        symbol: "sparkles")
                }
            } else {
                AttentionPanel(
                    "Agents working over time",
                    subtitle: "Average number of agents working in each interval."
                ) {
                    AttentionConcurrencyChart(
                        points: agents.concurrency, domain: interval.start...interval.end,
                        height: 150)
                }
                if compact {
                    table("Machines", agents.machines, color: violet)
                    table("Agents", agents.kinds, color: violet)
                } else {
                    HStack(alignment: .top, spacing: UIScale.pt(14)) {
                        table("Machines", agents.machines, color: violet)
                        table("Agents", agents.kinds, color: violet)
                    }
                }
                if !agents.projects.isEmpty {
                    table("Projects", agents.projects, color: violet)
                }
                AttentionAgentSessions(sessions: agents.sessions)
            }
        }
    }

    private func table(_ title: String, _ totals: [AttentionAgentTotal], color: Color)
        -> some View
    {
        AttentionPanel(title, subtitle: "Working time, waiting time and your own attention.") {
            AttentionAgentTable(totals: totals, color: color)
        }
    }
}

private struct AttentionAgentTable: View {
    let totals: [AttentionAgentTotal]
    let color: Color
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        let top = totals.map(\.working).max() ?? 1
        VStack(spacing: UIScale.pt(8)) {
            HStack {
                Text("").frame(maxWidth: .infinity, alignment: .leading)
                header("Working")
                header("Waiting")
                header("You")
                header("Sessions")
            }
            .foregroundStyle(DashSkin.inkFaint(dark))
            ForEach(totals.prefix(12)) { total in
                VStack(alignment: .leading, spacing: UIScale.pt(3)) {
                    HStack {
                        Text(total.key)
                            .font(.system(size: UIScale.pt(12.5), weight: .medium))
                            .foregroundStyle(DashSkin.ink(dark))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        cell(AttentionFormat.duration(total.working), dark)
                        cell(AttentionFormat.duration(total.blocked), dark)
                        cell(AttentionFormat.duration(total.attended), dark)
                        cell("\(total.sessions)", dark)
                    }
                    GeometryReader { geometry in
                        Capsule().fill(color)
                            .frame(width: max(2, geometry.size.width * total.working / max(top, 1)))
                    }
                    .frame(height: UIScale.pt(4))
                }
            }
        }
    }

    private func header(_ text: String) -> some View {
        Text(text.uppercased())
            .font(DashSkin.mono(9.5)).tracking(UIScale.pt(1))
            .frame(width: UIScale.pt(70), alignment: .trailing)
    }

    private func cell(_ text: String, _ dark: Bool) -> some View {
        Text(text)
            .font(.system(size: UIScale.pt(11.5)))
            .monospacedDigit()
            .foregroundStyle(DashSkin.inkSoft(dark))
            .frame(width: UIScale.pt(70), alignment: .trailing)
    }
}

private struct AttentionAgentSessions: View {
    let sessions: [AttentionAgentSession]
    @State private var limit = 20
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        AttentionPanel("Sessions", subtitle: "Every agent that worked in this period.") {
            VStack(spacing: 0) {
                ForEach(Array(sessions.prefix(limit).enumerated()), id: \.element.id) {
                    index, session in
                    if index > 0 { Divider().opacity(0.5) }
                    HStack(spacing: UIScale.pt(12)) {
                        VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                            Text(session.title)
                                .font(.system(size: UIScale.pt(12.5), weight: .medium))
                                .foregroundStyle(DashSkin.ink(dark))
                                .lineLimit(1)
                            Text(
                                [session.kind, session.machine, session.project].compactMap { $0 }
                                    .joined(separator: " · ")
                            )
                            .font(.system(size: UIScale.pt(10.5)))
                            .foregroundStyle(DashSkin.inkFaint(dark))
                            .lineLimit(1)
                        }
                        Spacer(minLength: UIScale.pt(8))
                        VStack(alignment: .trailing, spacing: UIScale.pt(2)) {
                            Text(AttentionFormat.duration(session.working))
                                .font(.system(size: UIScale.pt(12), weight: .semibold))
                                .monospacedDigit()
                                .foregroundStyle(DashSkin.ink(dark))
                            Text(
                                session.blocked > 0
                                    ? "waited \(AttentionFormat.duration(session.blocked)) · \(AttentionFormat.time(session.lastSeen))"
                                    : "last seen \(AttentionFormat.time(session.lastSeen))"
                            )
                            .font(.system(size: UIScale.pt(10)))
                            .foregroundStyle(DashSkin.inkFaint(dark))
                        }
                    }
                    .padding(.vertical, UIScale.pt(7))
                }
                if sessions.count > limit {
                    Button("Show \(min(20, sessions.count - limit)) more") { limit += 20 }
                        .buttonStyle(.edith(.secondary))
                        .frame(maxWidth: .infinity)
                        .padding(.top, UIScale.pt(6))
                }
            }
        }
    }
}
