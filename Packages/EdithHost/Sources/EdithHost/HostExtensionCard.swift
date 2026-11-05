import EdithExtensionUI
import EdithHostCore
import SwiftUI

struct HostExtensionIcon: View {
    let symbolName: String
    let active: Bool
    var size: CGFloat = 40
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        Image(systemName: symbolName)
            .font(.system(size: UIScale.pt(size * 0.44), weight: .semibold))
            .foregroundStyle(active ? DashSkin.accent(dark) : DashSkin.inkSoft(dark))
            .frame(width: UIScale.pt(size), height: UIScale.pt(size))
            .background(
                active ? DashSkin.accent(dark).opacity(dark ? 0.18 : 0.12) : Color.primary.opacity(0.06),
                in: RoundedRectangle(cornerRadius: UIScale.pt(size * 0.26), style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: UIScale.pt(size * 0.26), style: .continuous)
                    .strokeBorder(active ? DashSkin.accent(dark).opacity(0.25) : DashSkin.line(dark))
            )
            .accessibilityHidden(true)
    }
}

struct HostInstallControl: View {
    let title: String
    let state: HostExtensionRowState
    var large = false
    var canCancel = false
    let perform: (HostExtensionRowState.Action) -> Void
    let cancel: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if let progress = state.progress {
            VStack(alignment: .leading, spacing: UIScale.pt(4)) {
                LoadingProgress(value: progress)
                    .accessibilityLabel("Installing \(title)")
                HStack(spacing: UIScale.pt(8)) {
                    Text(state.status).font(.edithText(large ? .callout : .caption))
                        .foregroundStyle(DashSkin.inkSoft(scheme == .dark)).monospacedDigit()
                        .lineLimit(1)
                    Spacer(minLength: UIScale.pt(4))
                    if canCancel {
                        Button("Cancel", action: cancel).buttonStyle(.edith(.borderless))
                            .controlSize(.small)
                            .accessibilityLabel("Cancel installing \(title)")
                    }
                }
            }
            .frame(minWidth: UIScale.pt(large ? 220 : 120))
        } else if let action = state.action {
            Button {
                perform(action)
            } label: {
                Text(label(action))
            }
            .buttonStyle(.edith(state.emphasizesAction ? .primary : .secondary))
            .controlSize(large ? .large : .small)
            .accessibilityLabel(accessibilityLabel(action))
        }
    }

    private func label(_ action: HostExtensionRowState.Action) -> String {
        large && action == .open ? "Open \(title)" : action.title
    }

    private func accessibilityLabel(_ action: HostExtensionRowState.Action) -> String {
        switch action {
        case .download, .update, .retry, .open: "\(action.title) \(title)"
        default: action.title
        }
    }
}

struct HostExtensionCard: View {
    let entry: HostExtension
    let state: HostExtensionRowState
    let tagline: String
    var hint: String? = nil
    var canCancel = false
    let details: () -> Void
    let perform: (HostExtensionRowState.Action) -> Void
    let cancel: () -> Void
    let toggle: (Bool) -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false

    private var dark: Bool { scheme == .dark }
    private var active: Bool {
        switch state.stage {
        case .ready, .installed, .updateAvailable, .starting, .verifying, .downloading: true
        default: false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(12)) {
            HStack(alignment: .top, spacing: UIScale.pt(12)) {
                HostExtensionIcon(symbolName: entry.symbolName, active: state.on || active)
                VStack(alignment: .leading, spacing: UIScale.pt(3)) {
                    Text(entry.title).font(.edithText(.body).weight(.semibold))
                        .foregroundStyle(DashSkin.ink(dark)).lineLimit(1)
                        .accessibilityAddTraits(.isButton)
                        .accessibilityHint("Shows details")
                        .accessibilityAction { details() }
                    Text(tagline).font(.edithText(.caption))
                        .foregroundStyle(DashSkin.inkSoft(dark))
                        .lineLimit(2, reservesSpace: true)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if state.isInstalled {
                    Toggle("", isOn: Binding(get: { state.on }, set: toggle))
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                        .tint(DashSkin.accent(dark)).disabled(!state.canToggle)
                        .accessibilityLabel("\(entry.title) enabled")
                }
            }
            if state.stage == .ready, let hint {
                Text(hint).font(.edithText(.caption)).foregroundStyle(DashSkin.accent(dark))
                    .fixedSize(horizontal: false, vertical: true)
            }
            footer
        }
        .padding(UIScale.pt(14))
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            hovering ? DashSkin.paper2(dark) : DashSkin.paper(dark),
            in: RoundedRectangle(cornerRadius: UIScale.pt(12), style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: UIScale.pt(12), style: .continuous)
                .strokeBorder(
                    state.stage == .ready ? DashSkin.accent(dark).opacity(0.5) : DashSkin.line(dark))
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: details)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var footer: some View {
        if state.progress != nil {
            HostInstallControl(
                title: entry.title, state: state, canCancel: canCancel, perform: perform,
                cancel: cancel)
        } else {
            HStack(spacing: UIScale.pt(8)) {
                Text(state.status).font(.edithText(.caption)).foregroundStyle(tone)
                    .monospacedDigit().lineLimit(2).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: UIScale.pt(4))
                HostInstallControl(
                    title: entry.title, state: state, canCancel: false, perform: perform,
                    cancel: cancel)
            }
        }
    }

    private var tone: Color {
        switch state.tone {
        case .neutral: DashSkin.inkSoft(dark)
        case .positive: DashSkin.accent(dark)
        case .attention: .orange
        case .failure: .red
        }
    }
}

struct HostExtensionCardSkeleton: View {
    var body: some View {
        SkeletonReplica("Loading extensions") {
            VStack(alignment: .leading, spacing: UIScale.pt(12)) {
                HStack(alignment: .top, spacing: UIScale.pt(12)) {
                    SkeletonBlock(width: 40, height: 40, corner: 10)
                    VStack(alignment: .leading, spacing: UIScale.pt(6)) {
                        SkeletonBlock(width: 110, height: 14)
                        SkeletonBlock(height: 10)
                        SkeletonBlock(width: 150, height: 10)
                    }
                }
                HStack {
                    SkeletonBlock(width: 70, height: 10)
                    Spacer()
                    SkeletonBlock(width: 54, height: 22, corner: 6)
                }
            }
            .padding(UIScale.pt(14))
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .edithSurface(cornerRadius: 12)
        }
    }
}
