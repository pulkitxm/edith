import EdithExtensionUI
import EdithHostCore
import SwiftUI

struct HostExtensionRow: View {
    let entry: HostExtension
    let state: HostExtensionRowState
    let subtitle: String
    let details: () -> Void
    let perform: (HostExtensionRowState.Action) -> Void
    let toggle: (Bool) -> Void
    @Environment(\.compactLayout) private var compact
    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false

    private var dark: Bool { scheme == .dark }

    var body: some View {
        HStack(spacing: UIScale.pt(12)) {
            icon
            VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                Text(entry.title).font(.edithText(.body).weight(.semibold))
                    .foregroundStyle(DashSkin.ink(dark)).lineLimit(1)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHint("Shows details")
                    .accessibilityAction { details() }
                if compact {
                    status
                } else {
                    Text(subtitle).font(.edithText(.caption))
                        .foregroundStyle(DashSkin.inkSoft(dark)).lineLimit(1)
                }
            }
            Spacer(minLength: UIScale.pt(8))
            if !compact { status.layoutPriority(1) }
            trailing
            Toggle("", isOn: Binding(get: { state.on }, set: toggle))
                .labelsHidden().toggleStyle(.switch).controlSize(.small)
                .tint(DashSkin.accent(dark)).disabled(!state.canToggle)
                .accessibilityLabel("\(entry.title) enabled")
        }
        .padding(.horizontal, UIScale.pt(14))
        .padding(.vertical, UIScale.pt(10))
        .background(hovering ? Color.primary.opacity(0.04) : .clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: details)
        .onHover { hovering = $0 }
        .help(subtitle)
        .accessibilityElement(children: .contain)
    }

    private var icon: some View {
        Image(systemName: entry.symbolName)
            .font(.system(size: UIScale.pt(14), weight: .semibold))
            .foregroundStyle(state.on ? DashSkin.accent(dark) : DashSkin.inkSoft(dark))
            .frame(width: UIScale.pt(28), height: UIScale.pt(28))
            .background(
                state.on ? DashSkin.accent(dark).opacity(0.14) : Color.primary.opacity(0.06),
                in: RoundedRectangle(cornerRadius: UIScale.pt(7))
            )
            .accessibilityHidden(true)
    }

    private var status: some View {
        Text(state.status).font(.edithText(.caption)).foregroundStyle(tone)
            .monospacedDigit().lineLimit(1).truncationMode(.tail)
    }

    private var tone: Color {
        switch state.tone {
        case .neutral: DashSkin.inkSoft(dark)
        case .positive: DashSkin.accent(dark)
        case .attention: .orange
        case .failure: .red
        }
    }

    private var trailing: some View {
        action.frame(minWidth: UIScale.pt(76), alignment: .trailing)
    }

    @ViewBuilder private var action: some View {
        if let progress = state.progress {
            LoadingProgress(value: progress).frame(width: UIScale.pt(64))
                .accessibilityLabel("Working on \(entry.title)")
        } else if let action = state.action {
            Button(action.title) { perform(action) }
                .buttonStyle(.edith(action == .update ? .primary : .secondary))
                .controlSize(.small)
        }
    }
}
