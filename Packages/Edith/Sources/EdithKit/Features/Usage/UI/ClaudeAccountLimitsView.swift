import SwiftUI

public struct ClaudeAccountLimitsView: View {
    private let accounts: [ClaudeAccountLimits]
    private let compact: Bool

    public init(accounts: [ClaudeAccountLimits], compact: Bool = false) {
        self.accounts = accounts
        self.compact = compact
    }

    public var body: some View {
        LazyVGrid(
            columns: compact
                ? [GridItem(.flexible())]
                : [GridItem(.adaptive(minimum: UIScale.pt(accounts.count <= 2 ? 180 : 220)))],
            alignment: .leading, spacing: UIScale.pt(12)
        ) {
            ForEach(accounts) { account in
                VStack(alignment: .leading, spacing: UIScale.pt(8)) {
                    Text(account.name).font(.edithText(.headline)).lineLimit(2)
                    ForEach(MenuBarLimits.slots(for: .claude), id: \.self) { slot in
                        if slot != .fable || account.limits.fable != nil {
                            let window = account.limits.window(for: slot)
                            let percent = SurfaceQuotaValue(window).percent
                            VStack(alignment: .leading, spacing: UIScale.pt(4)) {
                                HStack {
                                    Text(slot.settingsLabel(for: .claude))
                                    Spacer()
                                    Text(percent.map { "\(Int($0))%" } ?? "Unavailable")
                                        .monospacedDigit()
                                }.font(.edithText(.caption))
                                if let percent {
                                    LoadingProgress(value: percent, total: 100)
                                }
                                if let reset = window?.resetsAt, reset > Date() {
                                    Text("Resets \(reset, style: .relative)")
                                        .font(.edithText(.caption2)).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    if let error = account.limits.error {
                        Text(error).font(.edithText(.caption)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(UIScale.pt(compact ? 10 : 14))
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: UIScale.pt(10)))
                .accessibilityElement(children: .contain)
                .accessibilityLabel(account.name + " Claude limits")
            }
        }
    }
}
