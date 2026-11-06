import EdithExtensionUI
import EdithHostCore
import SwiftUI

struct HostExtensionIcon: View {
    let entry: HostExtension
    var size: CGFloat = 40
    var tint: Color?

    static func resolve(_ entry: HostExtension) -> EdithIcon { entry.icon }

    var body: some View {
        PageGuideBadge(icon: Self.resolve(entry), size: size, tint: tint)
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
                minWidth: UIScale.pt(large ? HostExtensionRowMetrics.heroProgressWidth : 120),
                maxWidth: large ? UIScale.pt(HostExtensionRowMetrics.heroProgressWidth) : .infinity
            )
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
        case .restart: "Restart Edith to finish updating \(title)"
        default: action.title
        }
    }
}

enum HostExtensionRowMetrics {
    static let icon = 32.0
    static let horizontalPadding = EdithRowMetrics.plateInset + EdithRowMetrics.contentHorizontal
    static let verticalPadding = EdithRowMetrics.plateInset + EdithRowMetrics.contentVertical
    static let contentSpacing = 12.0
    static let contentHeight = 32.0
    static let actionWidth = 76.0
    static let progressWidth = 160.0
    static let heroProgressWidth = 220.0
}

struct HostExtensionRow: View {
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
    @Environment(\.compactLayout) private var compact

    private var dark: Bool { scheme == .dark }

    var body: some View {
        Button(action: details) {
            HStack(spacing: UIScale.pt(HostExtensionRowMetrics.contentSpacing)) {
                HostExtensionIcon(
                    entry: entry, size: HostExtensionRowMetrics.icon, tint: DashSkin.inkSoft(dark))
                VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                    Text(entry.title).font(.edithText(.body).weight(.semibold))
                        .foregroundStyle(DashSkin.ink(dark)).lineLimit(1)
                    if compact, state.progress == nil {
                        status
                    } else {
                        Text(tagline).font(.edithText(.caption))
                            .foregroundStyle(DashSkin.inkSoft(dark)).lineLimit(1)
                    }
                }
                Spacer(minLength: UIScale.pt(8))
                if !compact, state.progress == nil { status.layoutPriority(1) }
                controls.hidden().accessibilityHidden(true)
            }
            .frame(minHeight: UIScale.pt(HostExtensionRowMetrics.contentHeight))
        }
        .buttonStyle(.edith(.row))
        .accessibilityLabel(entry.title)
        .accessibilityValue(state.progress == nil ? note ?? state.status : "")
        .accessibilityHint("\(tagline). Shows details")
        .overlay(alignment: .trailing) {
            controls.padding(.trailing, UIScale.pt(HostExtensionRowMetrics.horizontalPadding))
        }
        .help(tagline)
        .accessibilityElement(children: .contain)
    }

    private var controls: some View {
        HStack(spacing: UIScale.pt(HostExtensionRowMetrics.contentSpacing)) {
            action
            Toggle("", isOn: Binding(get: { state.on }, set: toggle))
                .labelsHidden().toggleStyle(.edithSwitch).controlSize(.small)
                .disabled(!state.canToggle)
                .accessibilityLabel("\(entry.title) enabled")
        }
    }

    private var status: some View {
        Text(note ?? state.status).font(.edithText(.caption)).foregroundStyle(tone)
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

    @ViewBuilder private var action: some View {
        if state.progress != nil {
            HostInstallControl(
                title: entry.title, state: state, canCancel: canCancel, perform: perform,
                cancel: cancel
            )
            .frame(width: UIScale.pt(HostExtensionRowMetrics.progressWidth))
        } else {
            ZStack(alignment: .trailing) {
                Color.clear.frame(width: UIScale.pt(HostExtensionRowMetrics.actionWidth), height: 1)
                HostInstallControl(
                    title: entry.title, state: state, prominent: state.stage == .ready,
                    canCancel: false, perform: perform, cancel: cancel)
            }
        }
    }
}

struct HostExtensionList: View {
    let entries: [HostExtension]
    let row: (HostExtension) -> HostExtensionRow

    var body: some View {
        EdithRowList(entries, id: \.id) { entry in row(entry).id(entry.id) }
    }
}

struct HostExtensionListSkeleton: View {
    let rows: Int
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        SkeletonReplica("Loading extensions") {
            VStack(spacing: 0) {
                ForEach(0..<rows, id: \.self) { index in
                    if index > 0 {
                        Rectangle().fill(DashSkin.line(scheme == .dark)).frame(height: 1)
                            .padding(.horizontal, UIScale.pt(EdithRowMetrics.plateInset))
                    }
                    HStack(spacing: UIScale.pt(HostExtensionRowMetrics.contentSpacing)) {
                        SkeletonBlock(
                            width: HostExtensionRowMetrics.icon,
                            height: HostExtensionRowMetrics.icon, corner: 7)
                        VStack(alignment: .leading, spacing: UIScale.pt(6)) {
                            SkeletonBlock(width: 120, height: 12)
                            SkeletonBlock(width: 240, height: 9)
                        }
                        Spacer(minLength: 0)
                        SkeletonBlock(width: 52, height: 24, corner: 7)
                    }
                    .padding(.horizontal, UIScale.pt(HostExtensionRowMetrics.horizontalPadding))
                    .padding(.vertical, UIScale.pt(HostExtensionRowMetrics.verticalPadding))
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .edithSurface(cornerRadius: PageMetrics.cardCornerRadius)
        }
    }
}
