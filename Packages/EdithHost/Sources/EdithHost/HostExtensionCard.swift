import EdithExtensionUI
import EdithHostCore
import SwiftUI

struct HostExtensionIcon: View {
    let symbolName: String
    var size: CGFloat = 40
    var prominent = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        let accent = DashSkin.accent(dark)
        let shape = RoundedRectangle(cornerRadius: UIScale.pt(size * 0.25), style: .continuous)
        Image(systemName: symbolName)
            .font(.system(size: UIScale.pt(size * 0.42), weight: .semibold))
            .foregroundStyle(prominent ? Color.white : accent)
            .frame(width: UIScale.pt(size), height: UIScale.pt(size))
            .background {
                if prominent {
                    shape.fill(accent)
                    shape.fill(
                        LinearGradient(
                            colors: [.white.opacity(0.22), .black.opacity(0.12)], startPoint: .top,
                            endPoint: .bottom))
                } else {
                    shape.fill(accent.opacity(dark ? 0.18 : 0.12))
                }
            }
            .overlay {
                shape.strokeBorder(
                    prominent ? Color.white.opacity(0.18) : accent.opacity(0.22),
                    lineWidth: UIScale.pt(0.75))
            }
            .accessibilityHidden(true)
    }
}

struct HostInstallControl: View {
    let title: String
    let state: HostExtensionRowState
    var large = false
    var prominent = true
    var canCancel = false
    let perform: (HostExtensionRowState.Action) -> Void
    let cancel: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if let progress = state.progress {
            VStack(alignment: .leading, spacing: UIScale.pt(large ? 8 : 6)) {
                LoadingProgress(value: progress)
                    .accessibilityLabel("Installing \(title)")
                HStack(alignment: .firstTextBaseline, spacing: UIScale.pt(8)) {
                    Text(state.status).font(.edithText(.caption))
                        .foregroundStyle(DashSkin.inkSoft(scheme == .dark)).monospacedDigit()
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: UIScale.pt(4))
                    if canCancel {
                        Button("Cancel", action: cancel).buttonStyle(.edith(.borderless))
                            .font(.edithText(.caption))
                            .accessibilityLabel("Cancel installing \(title)")
                    }
                }
            }
            .frame(
                minWidth: UIScale.pt(large ? HostExtensionCardMetrics.heroProgressWidth : 120),
                maxWidth: large ? UIScale.pt(HostExtensionCardMetrics.heroProgressWidth) : .infinity)
        } else if let action = state.action {
            Button {
                perform(action)
            } label: {
                Text(label(action)).lineLimit(1)
            }
            .buttonStyle(.edith(prominent && state.emphasizesAction ? .primary : .secondary))
            .controlSize(large ? .large : .small)
            .fixedSize()
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

enum HostExtensionCardMetrics {
    static let icon = 40.0
    static let footerHeight = 32.0
    static let titleHeight = 20.0
    static let minimumColumn = 280.0
    static let compactMinimumColumn = 240.0
    static let heroProgressWidth = 220.0
}

struct HostExtensionCard: View {
    let entry: HostExtension
    let state: HostExtensionRowState
    let tagline: String
    var note: String? = nil
    var canCancel = false
    let details: () -> Void
    let perform: (HostExtensionRowState.Action) -> Void
    let cancel: () -> Void
    let toggle: (Bool) -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false

    private var dark: Bool { scheme == .dark }

    var body: some View {
        let shape = RoundedRectangle(
            cornerRadius: UIScale.pt(PageMetrics.cardCornerRadius), style: .continuous)
        VStack(alignment: .leading, spacing: UIScale.pt(PageMetrics.cardSpacing)) {
            HStack(alignment: .top, spacing: UIScale.pt(12)) {
                HostExtensionIcon(symbolName: entry.symbolName, size: HostExtensionCardMetrics.icon)
                VStack(alignment: .leading, spacing: UIScale.pt(4)) {
                    HStack(alignment: .center, spacing: UIScale.pt(8)) {
                        Text(entry.title).font(.edithText(.body).weight(.semibold))
                            .foregroundStyle(DashSkin.ink(dark)).lineLimit(1)
                            .accessibilityAddTraits(.isButton)
                            .accessibilityHint("Shows details")
                            .accessibilityAction { details() }
                        Spacer(minLength: 0)
                        if state.isInstalled {
                            Toggle("", isOn: Binding(get: { state.on }, set: toggle))
                                .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                                .tint(DashSkin.accent(dark)).disabled(!state.canToggle)
                                .accessibilityLabel("\(entry.title) enabled")
                        }
                    }
                    .frame(minHeight: UIScale.pt(HostExtensionCardMetrics.titleHeight))
                    Text(tagline).font(.edithText(.callout))
                        .foregroundStyle(DashSkin.inkSoft(dark))
                        .lineLimit(2, reservesSpace: true)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            footer
                .frame(height: UIScale.pt(HostExtensionCardMetrics.footerHeight))
        }
        .padding(UIScale.pt(PageMetrics.cardPadding))
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background {
            shape.fill(DashSkin.paper2(dark))
            if hovering { shape.fill(Color.primary.opacity(dark ? 0.04 : 0.025)) }
        }
        .overlay {
            shape.strokeBorder(
                state.stage == .ready
                    ? DashSkin.accent(dark).opacity(0.55)
                    : hovering ? DashSkin.lineStrong(dark) : DashSkin.line(dark),
                lineWidth: UIScale.pt(state.stage == .ready ? 1 : 0.75))
        }
        .contentShape(shape)
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
            HStack(alignment: .center, spacing: UIScale.pt(12)) {
                Text(note ?? state.status).font(.edithText(.caption)).foregroundStyle(tone)
                    .monospacedDigit().lineLimit(2).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                HostInstallControl(
                    title: entry.title, state: state, prominent: state.stage == .ready,
                    canCancel: false, perform: perform, cancel: cancel)
            }
        }
    }

    private var tone: Color {
        switch state.tone {
        case .neutral: DashSkin.inkFaint(dark)
        case .positive: DashSkin.accent(dark)
        case .attention: .orange
        case .failure: .red
        }
    }
}

struct HostExtensionCardSkeleton: View {
    var body: some View {
        SkeletonReplica("Loading extensions") {
            VStack(alignment: .leading, spacing: UIScale.pt(PageMetrics.cardSpacing)) {
                HStack(alignment: .top, spacing: UIScale.pt(12)) {
                    SkeletonBlock(
                        width: HostExtensionCardMetrics.icon, height: HostExtensionCardMetrics.icon,
                        corner: 10)
                    VStack(alignment: .leading, spacing: UIScale.pt(8)) {
                        SkeletonBlock(width: 120, height: 14)
                        SkeletonBlock(height: 10)
                        SkeletonBlock(width: 150, height: 10)
                    }
                }
                HStack {
                    SkeletonBlock(width: 64, height: 10)
                    Spacer()
                    SkeletonBlock(width: 52, height: 28, corner: 7)
                }
                .frame(height: UIScale.pt(HostExtensionCardMetrics.footerHeight))
            }
            .padding(UIScale.pt(PageMetrics.cardPadding))
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .edithSurface(cornerRadius: PageMetrics.cardCornerRadius)
        }
    }
}
