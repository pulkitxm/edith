import EdithKit
import SwiftUI

struct BudgetCardView: View {
    let theme: Color
    let dark: Bool

    @AppStorage("budgetEnabled", store: SharedDefaults.store) private var enabled = false
    @AppStorage("budgetMode", store: SharedDefaults.store) private var modeRaw = "pace"
    @AppStorage("budgetKind", store: SharedDefaults.store) private var kindRaw = "weekly"
    @AppStorage("budgetCapPercent", store: SharedDefaults.store) private var cap = 50.0
    @AppStorage("budgetDeadline", store: SharedDefaults.store) private var deadlineTS = 0.0
    @State private var latest: DashLimitPoint?

    private var kind: LimitWindowKind { kindRaw == "session" ? .session : .weekly }
    private var mode: BudgetMode { BudgetMode(rawValue: modeRaw) ?? .pace }

    private var status: BudgetStatus? {
        guard enabled, let latest else { return nil }
        let pct = kind == .session ? latest.s : latest.w
        let reset = kind == .session ? latest.sr : latest.wr
        guard let pct, let reset else { return nil }
        let start = reset.addingTimeInterval(-kind.duration)
        let deadline =
            mode == .cap && deadlineTS > 0
            ? Date(timeIntervalSinceReferenceDate: deadlineTS) : reset
        return LimitMath.budgetStatus(
            actual: pct, capPercent: cap, start: start, deadline: deadline, now: Date(),
            resetsAt: mode == .pace ? reset : nil)
    }

    var body: some View {
        SkinCard(title: "Personal budget", dark: dark) {
            if let status {
                content(status)
            } else {
                Text(
                    enabled
                        ? "Waiting for usage data…"
                        : "Set a personal cap in Settings › Usage to pace your Claude spend."
                )
                .font(.system(size: 12)).foregroundStyle(DashSkin.inkFaint(dark))
                .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
            }
        }
        .task { latest = DashLimits.loadLatest() }
    }

    private func content(_ status: BudgetStatus) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(Int(status.actualPercent.rounded()))%")
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                statePill(status.state)
                Spacer()
                Text("cap \(Int(cap))% · \(kind == .session ? "session" : "week")")
                    .font(.system(size: 11)).foregroundStyle(DashSkin.inkFaint(dark))
            }
            meter(status)
            HStack(spacing: 16) {
                stat("On-pace target", "\(Int(status.targetPercent.rounded()))%")
                if let daily = status.dailyBudgetPercent {
                    stat("Today's budget", "\(Int(daily.rounded()))%")
                }
                stat(
                    status.deltaPercent >= 0 ? "Over pace" : "Under pace",
                    "\(abs(Int(status.deltaPercent.rounded())))%")
            }
        }
    }

    private func meter(_ status: BudgetStatus) -> some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.08))
                Capsule().fill(color(status.state).opacity(0.85))
                    .frame(width: max(3, w * min(1, status.actualPercent / 100)))
                Rectangle().fill(theme.opacity(0.6)).frame(width: 2)
                    .offset(x: w * min(1, cap / 100) - 1)
            }
        }
        .frame(height: 8)
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 10)).foregroundStyle(DashSkin.inkFaint(dark))
            Text(value).font(.system(size: 14, weight: .medium)).monospacedDigit()
        }
    }

    private func statePill(_ state: BudgetState) -> some View {
        Text(label(state))
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 9).padding(.vertical, 3)
            .background(color(state).opacity(0.18), in: Capsule())
            .foregroundStyle(color(state))
    }

    private func label(_ state: BudgetState) -> String {
        switch state {
        case .onPace: "On pace"
        case .under: "Under budget"
        case .over: "Over pace"
        case .exceeded: "Cap reached"
        case .noData: "No data"
        }
    }

    private func color(_ state: BudgetState) -> Color {
        switch state {
        case .onPace, .under: DashPalette.color("#34C759")
        case .over: DashPalette.color("#FF9500")
        case .exceeded: DashPalette.color("#FF3B30")
        case .noData: DashSkin.inkFaint(dark)
        }
    }
}

extension BudgetStatus {
    fileprivate var deltaPercent: Double { actualPercent - targetPercent }
}
