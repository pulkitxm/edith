import EdithKit
import SwiftUI

enum AttentionPalette {
    static func category(_ id: String, dark: Bool) -> Color {
        switch id {
        case "work-coding": DashSkin.accent(dark)
        case "work-research": Color.blue
        case "work-design": Color.purple
        case "communication-work": Color.teal
        case "communication-personal": Color.cyan
        case "admin": DashSkin.gold
        case "entertainment-video": Color.indigo
        case "entertainment-music": Color.pink
        case "distraction-social": DashSkin.danger
        default: DashSkin.inkFaint(dark)
        }
    }

    static func presence(_ presence: AttentionPresence, dark: Bool) -> Color {
        switch presence {
        case .active: DashSkin.sage
        case .passive: Color.indigo
        case .away: DashSkin.inkFaint(dark)
        case .uncertain: DashSkin.warn
        }
    }

    static func kind(_ kind: AttentionCategoryKind, dark: Bool) -> Color {
        switch kind {
        case .productive: DashSkin.sage
        case .neutral: DashSkin.inkSoft(dark)
        case .distracting: DashSkin.danger
        case .entertainment: Color.indigo
        }
    }
}

struct AttentionPanel<Content: View>: View {
    let title: String
    var subtitle: String?
    var actionTitle: String?
    var action: (() -> Void)?
    @ViewBuilder var content: () -> Content
    @Environment(\.colorScheme) private var scheme

    private var dark: Bool { scheme == .dark }

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(14)) {
            HStack(alignment: .firstTextBaseline, spacing: UIScale.pt(10)) {
                VStack(alignment: .leading, spacing: UIScale.pt(3)) {
                    Text(title)
                        .font(DashSkin.serif(18))
                        .foregroundStyle(DashSkin.ink(dark))
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: UIScale.pt(11.5)))
                            .foregroundStyle(DashSkin.inkFaint(dark))
                    }
                }
                Spacer(minLength: UIScale.pt(8))
                if let actionTitle, let action {
                    Button(actionTitle, action: action)
                        .buttonStyle(.plain)
                        .font(.system(size: UIScale.pt(11.5), weight: .medium))
                        .foregroundStyle(DashSkin.accentDeep(dark))
                        .pointerCursor()
                }
            }
            content()
        }
        .padding(UIScale.pt(16))
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .widgetBar(
            cornerRadius: 16,
            fill: DashSkin.paper2(dark),
            stroke: DashSkin.line(dark),
            shadow: .black.opacity(dark ? 0.3 : 0.045))
    }
}

struct AttentionMetricCard: View {
    let metric: AttentionMetric
    @Environment(\.colorScheme) private var scheme

    private var dark: Bool { scheme == .dark }

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(11)) {
            HStack {
                Image(systemName: metric.symbol)
                    .font(.system(size: UIScale.pt(13), weight: .semibold))
                    .foregroundStyle(DashSkin.accentDeep(dark))
                Text(metric.title.uppercased())
                    .font(.system(size: UIScale.pt(9.5), weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(DashSkin.inkFaint(dark))
                Spacer()
            }
            Text(metric.value)
                .font(DashSkin.serif(24))
                .foregroundStyle(DashSkin.ink(dark))
            Text(metric.detail)
                .font(.system(size: UIScale.pt(10.5)))
                .foregroundStyle(DashSkin.inkSoft(dark))
                .lineLimit(1)
        }
        .padding(UIScale.pt(14))
        .frame(maxWidth: .infinity, alignment: .leading)
        .widgetBar(
            cornerRadius: 14,
            fill: DashSkin.paper2(dark),
            stroke: DashSkin.line(dark),
            shadow: .black.opacity(dark ? 0.28 : 0.04))
    }
}

struct AttentionSectionTabs: View {
    @Bindable var store: AttentionMockStore
    @Environment(\.colorScheme) private var scheme

    private var dark: Bool { scheme == .dark }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: UIScale.pt(4)) {
                ForEach(AttentionSection.allCases) { section in
                    Button {
                        withAnimation(.easeOut(duration: 0.16)) { store.selectedSection = section }
                    } label: {
                        HStack(spacing: UIScale.pt(6)) {
                            Image(systemName: section.symbol)
                            Text(section.title)
                        }
                        .font(.system(size: UIScale.pt(11.5), weight: .medium))
                        .foregroundStyle(
                            store.selectedSection == section
                                ? DashSkin.ink(dark) : DashSkin.inkSoft(dark))
                        .padding(.horizontal, UIScale.pt(11))
                        .frame(height: UIScale.pt(30))
                        .background(
                            store.selectedSection == section
                                ? DashSkin.paper2(dark) : Color.clear,
                            in: RoundedRectangle(cornerRadius: UIScale.pt(8)))
                        .overlay {
                            if store.selectedSection == section {
                                RoundedRectangle(cornerRadius: UIScale.pt(8))
                                    .strokeBorder(DashSkin.line(dark))
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                }
            }
        }
    }
}

struct AttentionRangePicker: View {
    @Bindable var store: AttentionMockStore
    @Environment(\.colorScheme) private var scheme

    private var dark: Bool { scheme == .dark }

    var body: some View {
        HStack(spacing: UIScale.pt(2)) {
            ForEach(AttentionRange.allCases) { range in
                Button(range.title) {
                    withAnimation(.easeOut(duration: 0.16)) { store.selectedRange = range }
                }
                .buttonStyle(.plain)
                .font(.system(size: UIScale.pt(10.5), weight: .semibold))
                .foregroundStyle(
                    store.selectedRange == range ? Color.white : DashSkin.inkSoft(dark))
                .padding(.horizontal, UIScale.pt(9))
                .frame(height: UIScale.pt(26))
                .background(
                    store.selectedRange == range ? DashSkin.accentDeep(dark) : Color.clear,
                    in: RoundedRectangle(cornerRadius: UIScale.pt(7)))
                .pointerCursor()
            }
        }
        .padding(UIScale.pt(2))
        .background(DashSkin.grid(dark), in: RoundedRectangle(cornerRadius: UIScale.pt(9)))
    }
}

struct AttentionBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: UIScale.pt(9.5), weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, UIScale.pt(7))
            .frame(height: UIScale.pt(20))
            .background(color.opacity(0.12), in: Capsule())
    }
}

struct AttentionLegendItem: View {
    let title: String
    let color: Color

    var body: some View {
        HStack(spacing: UIScale.pt(5)) {
            Circle().fill(color).frame(width: UIScale.pt(7), height: UIScale.pt(7))
            Text(title)
                .font(.system(size: UIScale.pt(9.5)))
                .foregroundStyle(.secondary)
        }
    }
}

struct AttentionPrototypePlaceholder: View {
    let section: AttentionSection
    @Environment(\.colorScheme) private var scheme

    private var dark: Bool { scheme == .dark }

    var body: some View {
        ContentUnavailableView(
            section.title, systemImage: section.symbol,
            description: Text("This part of the interactive mock is being assembled."))
            .frame(maxWidth: .infinity, minHeight: UIScale.pt(360))
            .foregroundStyle(DashSkin.inkSoft(dark))
    }
}
