import SwiftUI

public enum PageNoticeTone {
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

    var fill: Color {
        self == .information ? Color.primary.opacity(0.04) : color.opacity(0.08)
    }

    var stroke: Color {
        self == .information ? Color.primary.opacity(0.12) : color.opacity(0.3)
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

public struct PageNotice<Detail: View, Actions: View>: View {
    let message: String
    var title: String?
    var tone: PageNoticeTone = .information
    var symbol: String?
    @ViewBuilder let detail: () -> Detail
    @ViewBuilder let actions: () -> Actions

    public init(
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

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: UIScale.pt(10)) {
            Image(systemName: symbol ?? tone.symbol)
                .font(.edithText(title == nil ? .body : .headline))
                .foregroundStyle(tone.color)
                .frame(width: UIScale.pt(16))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: UIScale.pt(4)) {
                if let title {
                    Text(title).font(.edithText(.headline))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(message).font(.edithText(.body)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                detail()
                if Actions.self != EmptyView.self {
                    WrapHStack(
                        spacing: UIScale.pt(PageMetrics.controlSpacing),
                        lineSpacing: UIScale.pt(PageMetrics.controlSpacing)
                    ) {
                        actions()
                    }
                    .buttonStyle(.edith(.secondary))
                    .padding(.top, UIScale.pt(4))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, UIScale.pt(16))
        .padding(.vertical, UIScale.pt(12))
        .frame(maxWidth: .infinity, alignment: .leading)
        .widgetBar(
            cornerRadius: 12, fill: tone.fill, stroke: tone.stroke
        )
        .accessibilityElement(children: .contain)
    }
}
