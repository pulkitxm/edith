import SwiftUI

public struct PageMetric: View {
    let title: String
    let value: String
    var detail: String?
    var symbol: String?
    var tint: Color?
    var trend: String?
    var trendPositive = true

    public init(
        title: String, value: String, detail: String? = nil, symbol: String? = nil,
        tint: Color? = nil, trend: String? = nil, trendPositive: Bool = true
    ) {
        self.title = title; self.value = value; self.detail = detail; self.symbol = symbol
        self.tint = tint; self.trend = trend; self.trendPositive = trendPositive
    }

    public var body: some View {
        PageCard {
            HStack(spacing: UIScale.pt(6)) {
                if let symbol { Image(systemName: symbol).foregroundStyle(tint ?? .secondary) }
                Text(title).font(.edithText(.caption)).foregroundStyle(.secondary)
            }
            Text(value).font(.edithText(.title2)).fontWeight(.semibold).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.6).contentTransition(.numericText())
            if let trend {
                Label(trend, systemImage: trendPositive ? "arrow.up.right" : "arrow.down.right")
                    .font(.edithText(.caption)).foregroundStyle(trendPositive ? .green : .red)
                    .help("Compared with the previous period of the same length")
            }
            if let detail {
                Text(detail).font(.edithText(.caption)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
