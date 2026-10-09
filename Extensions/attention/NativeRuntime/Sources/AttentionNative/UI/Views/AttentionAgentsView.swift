@_implementationOnly import EdithExtensionSupport
@_implementationOnly import EdithExtensionUI
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
                columns: PageMetrics.cardColumns(compact, minimum: 200, spacing: 12),
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
                table("Machines", agents.machines, color: violet)
                table("Agents", agents.kinds, color: violet)
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

struct AttentionAgentTable: View {
    let totals: [AttentionAgentTotal]
    let color: Color
    @State private var columns = TableColumnCustomization<AttentionAgentTotal>()
    @Environment(\.compactLayout) private var compact

    var body: some View {
        let peak = totals.reduce(1) { max($0, $1.working) }
        GeometryReader { geometry in
            Table(totals, columnCustomization: $columns) {
                SwiftUI.TableColumn("Agent group") { total in
                    VStack(alignment: .leading, spacing: UIScale.pt(3)) {
                        Text(total.key).font(.edithText(.body)).lineLimit(1).help(total.key)
                        if compact {
                            Text(
                                "Waiting \(AttentionFormat.duration(total.blocked)) · You \(AttentionFormat.duration(total.attended)) · \(total.sessions) sessions"
                            )
                            .font(.edithText(.caption)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        GeometryReader { bar in
                            Capsule().fill(color.opacity(0.8))
                                .frame(
                                    width: max(
                                        2, bar.size.width * max(0, min(1, total.working / peak))))
                        }.frame(height: UIScale.pt(4)).accessibilityHidden(true)
                    }.padding(.vertical, UIScale.pt(4))
                }
                .width(
                    PageMetrics.tableNameWidth(
                        viewport: geometry.size.width,
                        fixedWidth: compact ? 90 : 330, columnCount: compact ? 2 : 5))
                SwiftUI.TableColumn("Working") { total in
                    Text(AttentionFormat.duration(total.working)).monospacedDigit().foregroundStyle(
                        color)
                }.width(UIScale.pt(90))
                SwiftUI.TableColumn("Waiting") { total in
                    Text(AttentionFormat.duration(total.blocked)).monospacedDigit()
                }.width(UIScale.pt(90)).customizationID("waiting")
                    .defaultVisibility(compact ? .hidden : .visible)
                SwiftUI.TableColumn("You") { total in
                    Text(AttentionFormat.duration(total.attended)).monospacedDigit()
                }.width(UIScale.pt(90)).customizationID("you")
                    .defaultVisibility(compact ? .hidden : .visible)
                SwiftUI.TableColumn("Sessions") { total in
                    Text("\(total.sessions)").monospacedDigit()
                }.width(UIScale.pt(60)).customizationID("sessions")
                    .defaultVisibility(compact ? .hidden : .visible)
            }
            .tableStyle(.inset)
            .font(.edithText(.body))
            .accessibilityLabel("All agent groups")
        }.frame(height: attentionTableHeight(totals.count))
    }
}

struct AttentionAgentSessions: View {
    let sessions: [AttentionAgentSession]
    @State private var columns = TableColumnCustomization<AttentionAgentSession>()
    @Environment(\.compactLayout) private var compact

    var body: some View {
        AttentionPanel("Sessions", subtitle: "\(sessions.count) sessions in this period.") {
            GeometryReader { geometry in
                Table(sessions, columnCustomization: $columns) {
                    SwiftUI.TableColumn("Session") { session in
                        VStack(alignment: .leading, spacing: UIScale.pt(3)) {
                            Text(session.title).font(.edithText(.body)).lineLimit(1).help(
                                session.title)
                            Text(
                                [session.kind, session.machine, session.project].compactMap { $0 }
                                    .joined(separator: " · ")
                            )
                            .font(.edithText(.caption)).foregroundStyle(.secondary).lineLimit(1)
                            if compact {
                                Text(
                                    "Waiting \(AttentionFormat.duration(session.blocked)) · Last seen \(AttentionFormat.time(session.lastSeen))"
                                )
                                .font(.edithText(.caption)).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }.padding(.vertical, UIScale.pt(4))
                    }.width(
                        PageMetrics.tableNameWidth(
                            viewport: geometry.size.width,
                            fixedWidth: compact ? 90 : 280, columnCount: compact ? 2 : 4))
                    SwiftUI.TableColumn("Working") { session in
                        Text(AttentionFormat.duration(session.working)).monospacedDigit()
                    }.width(UIScale.pt(90))
                    SwiftUI.TableColumn("Waiting") { session in
                        Text(AttentionFormat.duration(session.blocked)).monospacedDigit()
                    }.width(UIScale.pt(90)).customizationID("waiting")
                        .defaultVisibility(compact ? .hidden : .visible)
                    SwiftUI.TableColumn("Last seen") { session in
                        Text(AttentionFormat.time(session.lastSeen)).monospacedDigit()
                    }.width(UIScale.pt(100)).customizationID("lastSeen")
                        .defaultVisibility(compact ? .hidden : .visible)
                }
                .tableStyle(.inset)
                .font(.edithText(.body))
                .accessibilityLabel("All agent sessions")
            }.frame(height: attentionTableHeight(sessions.count))
        }
    }
}

private func attentionTableHeight(_ count: Int) -> CGFloat {
    UIScale.pt(min(420, max(120, Double(count) * 62 + 32)))
}
