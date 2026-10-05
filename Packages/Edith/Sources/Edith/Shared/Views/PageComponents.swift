import EdithKit
import SwiftUI

struct PageCard<Content: View>: View {
    var title: String?
    var note: String?
    var fill = false
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(PageMetrics.cardSpacing)) {
            if let title {
                PageSectionHeader(title) {
                    if let note {
                        Text(note).font(.edithText(.caption)).foregroundStyle(.secondary)
                    }
                }
            }
            content()
        }
        .padding(UIScale.pt(16))
        .frame(maxWidth: .infinity, maxHeight: fill ? .infinity : nil, alignment: .topLeading)
        .edithSurface(cornerRadius: 14)
    }
}

struct PageMetric: View {
    let title: String
    let value: String
    var detail: String?
    var symbol: String?

    var body: some View {
        PageCard {
            HStack(spacing: UIScale.pt(6)) {
                if let symbol { Image(systemName: symbol) }
                Text(title).font(.edithText(.caption)).foregroundStyle(.secondary)
            }
            Text(value).font(.edithText(.title2)).fontWeight(.semibold).monospacedDigit()
            if let detail {
                Text(detail).font(.edithText(.caption)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct PageToolbarButton: View {
    let action: () -> Void
    let systemImage: String
    let helperText: String
    var isLoading = false
    var tint: Color?

    var body: some View {
        Button(action: action) {
            Group {
                if isLoading {
                    LoadingIndicator()
                } else {
                    Image(systemName: systemImage).foregroundStyle(tint ?? .primary)
                }
            }
            .frame(width: UIScale.pt(30), height: UIScale.pt(30))
        }
        .buttonStyle(.edith(.toolbar))
        .disabled(isLoading)
        .help(helperText)
        .accessibilityLabel(helperText)
    }
}

enum PageNoticeTone {
    case information
    case success
    case warning
    case error

    var color: Color {
        switch self {
        case .information: .secondary
        case .success: .green
        case .warning: .orange
        case .error: .red
        }
    }

    var symbol: String {
        switch self {
        case .information: "info.circle"
        case .success: "checkmark.circle"
        case .warning: "exclamationmark.triangle"
        case .error: "exclamationmark.octagon"
        }
    }
}

struct PageNotice<Detail: View, Actions: View>: View {
    let message: String
    var title: String?
    var tone: PageNoticeTone = .information
    var symbol: String?
    @ViewBuilder let detail: () -> Detail
    @ViewBuilder let actions: () -> Actions

    init(
        _ message: String, title: String? = nil, tone: PageNoticeTone = .information,
        symbol: String? = nil,
        @ViewBuilder detail: @escaping () -> Detail = { EmptyView() },
        @ViewBuilder actions: @escaping () -> Actions = { EmptyView() }
    ) {
        self.message = message
        self.title = title
        self.tone = tone
        self.symbol = symbol
        self.detail = detail
        self.actions = actions
    }

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(10)) {
            HStack(alignment: .top, spacing: UIScale.pt(10)) {
                Image(systemName: symbol ?? tone.symbol).foregroundStyle(tone.color)
                VStack(alignment: .leading, spacing: UIScale.pt(4)) {
                    if let title {
                        Text(title).font(.edithText(.headline))
                    }
                    Text(message).font(.edithText(.body)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    detail()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            actions().buttonStyle(.edith(.secondary))
        }
        .padding(UIScale.pt(14))
        .frame(maxWidth: .infinity, alignment: .leading)
        .widgetBar(
            cornerRadius: 14, fill: tone.color.opacity(0.08), stroke: tone.color.opacity(0.3)
        )
        .accessibilityElement(children: .contain)
    }
}

struct PageColumns<Content: View>: View {
    var spacing = PageMetrics.sectionSpacing
    @ViewBuilder let content: () -> Content
    @Environment(\.compactLayout) private var compact

    var body: some View {
        let layout =
            compact
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: UIScale.pt(spacing)))
            : AnyLayout(HStackLayout(alignment: .top, spacing: UIScale.pt(spacing)))
        layout { content() }
    }
}
