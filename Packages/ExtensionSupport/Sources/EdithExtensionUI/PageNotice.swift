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
