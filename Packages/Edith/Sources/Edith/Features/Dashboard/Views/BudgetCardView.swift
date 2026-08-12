import EdithKit
import SwiftUI

struct BudgetCardView: View {
    let theme: Color
    let dark: Bool

    @AppStorage(AppStorageKeys.Budget.enabled, store: SharedDefaults.store) private var enabled =
        false
    @AppStorage(AppStorageKeys.Budget.mode, store: SharedDefaults.store) private var modeRaw =
        "pace"
    @AppStorage(AppStorageKeys.Budget.kind, store: SharedDefaults.store) private var kindRaw =
        "weekly"
    @AppStorage(AppStorageKeys.Budget.capPercent, store: SharedDefaults.store) private var cap =
        50.0
    @AppStorage(AppStorageKeys.Budget.deadline, store: SharedDefaults.store) private
        var deadlineTS = 0.0
    @State private var latest: LimitPoint?

    private var kind: LimitWindowKind { kindRaw == "session" ? .session : .weekly }
    private var mode: BudgetMode { BudgetMode(rawValue: modeRaw) ?? .pace }

    private var status: BudgetStatus? {
        guard enabled, let latest else { return nil }
        let pct = kind == .session ? latest.s : latest.w
        let reset = kind == .session ? latest.sessionReset : latest.weekReset
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
                .font(.system(size: UIScale.pt(12))).foregroundStyle(DashSkin.inkFaint(dark))
                .frame(maxWidth: .infinity, minHeight: UIScale.pt(60), alignment: .leading)
            }
        }
        .task { latest = LimitsHistory.loadLatestPoint() }
    }

    private func content(_ status: BudgetStatus) -> some View {
        VStack(alignment: .leading, spacing: UIScale.pt(12)) {
            HStack(alignment: .firstTextBaseline, spacing: UIScale.pt(8)) {
                Text("\(Int(status.actualPercent.rounded()))%")
                    .font(.system(size: UIScale.pt(26), weight: .semibold, design: .rounded))
                    .monospacedDigit()
                statePill(status.state)
                Spacer()
                Text("cap \(Int(cap))% · \(kind == .session ? "session" : "week")")
                    .font(.system(size: UIScale.pt(11))).foregroundStyle(DashSkin.inkFaint(dark))
            }
            meter(status)
            HStack(spacing: UIScale.pt(16)) {
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
                Rectangle().fill(theme.opacity(0.6)).frame(width: UIScale.pt(2))
                    .offset(x: w * min(1, cap / 100) - 1)
            }
        }
        .frame(height: UIScale.pt(8))
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: UIScale.pt(2)) {
            Text(label).font(.system(size: UIScale.pt(10))).foregroundStyle(DashSkin.inkFaint(dark))
            Text(value).font(.system(size: UIScale.pt(14), weight: .medium)).monospacedDigit()
        }
    }

    private func statePill(_ state: BudgetState) -> some View {
        Text(label(state))
            .font(.system(size: UIScale.pt(11), weight: .semibold))
            .padding(.horizontal, UIScale.pt(9)).padding(.vertical, UIScale.pt(3))
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
        case .onPace, .under: DashSkin.ok
        case .over: DashSkin.warn
        case .exceeded: DashSkin.danger
        case .noData: DashSkin.inkFaint(dark)
        }
    }
}

extension BudgetStatus {
    fileprivate var deltaPercent: Double { actualPercent - targetPercent }
}
