import Foundation

public enum SweaterStitch: String, CaseIterable, Sendable {
    case stockinette
    case rib
    case garter

    public var title: String {
        switch self {
        case .stockinette: "Stockinette"
        case .rib: "Rib"
        case .garter: "Garter"
        }
    }

    public static func from(_ raw: String?) -> SweaterStitch {
        raw.flatMap(SweaterStitch.init(rawValue:)) ?? .stockinette
    }
}

public enum SweaterAnchor: String, CaseIterable, Sendable {
    case corner
    case centre

    public var title: String {
        switch self {
        case .corner: "Corner"
        case .centre: "Centre"
        }
    }

    public static func from(_ raw: String?) -> SweaterAnchor {
        raw.flatMap(SweaterAnchor.init(rawValue:)) ?? .corner
    }
}

public enum SweaterOrder: String, CaseIterable, Sendable {
    case below
    case above

    public var title: String {
        switch self {
        case .below: "Behind the window"
        case .above: "In front of the window"
        }
    }

    public static func from(_ raw: String?) -> SweaterOrder {
        raw.flatMap(SweaterOrder.init(rawValue:)) ?? .below
    }
}

public struct SweaterBasket: Equatable, Sendable, Identifiable {
    public let name: String
    public let title: String
    public let colors: [UInt32]

    public var id: String { name }

    public init(name: String, title: String, colors: [UInt32]) {
        self.name = name
        self.title = title
        self.colors = colors
    }
}

public enum SweaterBaskets {
    public static let all: [SweaterBasket] = [
        SweaterBasket(
            name: "dopamine", title: "Dopamine",
            colors: [
                0xff_ff2d95, 0xff_00d9ff, 0xff_ffd400, 0xff_7c3aff, 0xff_00e676,
                0xff_ff6b00, 0xff_ff1744, 0xff_00b8d4,
            ]),
        SweaterBasket(
            name: "neon", title: "Neon",
            colors: [0xff_f50057, 0xff_00e5ff, 0xff_c6ff00, 0xff_651fff, 0xff_1de9b6, 0xff_ff9100]),
        SweaterBasket(
            name: "punch", title: "Punch",
            colors: [0xff_e8175d, 0xff_0fb9b1, 0xff_fec230, 0xff_5f27cd, 0xff_10ac84, 0xff_ee5a24]),
        SweaterBasket(
            name: "wool", title: "Wool",
            colors: [
                0xff_d1495b, 0xff_4e8098, 0xff_edae49, 0xff_7c9885, 0xff_9b6a8f,
                0xff_e8846b, 0xff_3f7d6e, 0xff_c46a4e, 0xff_6d7ba8, 0xff_b8935f,
            ]),
        SweaterBasket(
            name: "sorbet", title: "Sorbet",
            colors: [
                0xff_f08ca4, 0xff_7fc6c4, 0xff_ffc978, 0xff_b08ed4, 0xff_8fce90,
                0xff_ff9f7a, 0xff_8ab6f0, 0xff_e5a3d0,
            ]),
        SweaterBasket(
            name: "forest", title: "Forest",
            colors: [
                0xff_4a6b52, 0xff_7d8f5c, 0xff_3f6b6e, 0xff_8a7248, 0xff_5c6b8a,
                0xff_6b5344, 0xff_2f5e4a,
            ]),
        SweaterBasket(
            name: "mono", title: "Mono",
            colors: [0xff_9aa0a6, 0xff_7c8288, 0xff_b4bac0, 0xff_686e74, 0xff_8d939a]),
    ]

    public static let defaultName = "wool"

    public static func basket(named name: String?) -> SweaterBasket {
        all.first { $0.name == name } ?? all.first { $0.name == defaultName } ?? all[0]
    }
}

public enum SweaterPattern: Equatable, Sendable {
    case byApp
    case plain
    case chart(String)

    public var rawValue: String {
        switch self {
        case .byApp: "by-app"
        case .plain: "none"
        case .chart(let name): name
        }
    }

    public static func from(_ raw: String?) -> SweaterPattern {
        switch raw {
        case "by-app", nil: .byApp
        case "none": .plain
        case .some(let name):
            SweaterChartCatalog.chart(named: name) == nil ? .byApp : .chart(name)
        }
    }

    public var chartName: String? {
        if case .chart(let name) = self { return name }
        return nil
    }
}

public enum SweaterPatternCatalog {
    public static let featured: [(name: String, title: String)] = [
        ("zigzag", "Zigzag"),
        ("picnic", "Picnic Checks"),
        ("ribbon", "Ribbon Stripes"),
        ("posy", "Little Bows"),
        ("twinkle", "Tiny Stars"),
        ("candy-stripe", "Candy Stripes"),
    ]

    public static func title(for chartName: String) -> String {
        if let match = featured.first(where: { $0.name == chartName }) { return match.title }
        return
            chartName
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .capitalized
    }

    public static func minimumRows(for pattern: SweaterPattern) -> Double {
        switch pattern {
        case .plain: return 3
        case .byApp: return 6
        case .chart(let name):
            guard let chart = SweaterChartCatalog.chart(named: name) else { return 6 }
            return max(6, Double(chart.height))
        }
    }
}

public struct SweaterSettings: Equatable, Sendable {
    public var active: Bool
    public var pattern: SweaterPattern
    public var stitch: SweaterStitch
    public var basket: String
    public var borderWidth: Double
    public var gauge: Double
    public var anchor: SweaterAnchor
    public var order: SweaterOrder
    public var unfocusedDim: Double
    public var accessibilityFocus: Bool
    public var excludedApps: [String]
    public var appTheme: AppTheme

    public init(
        active: Bool = true,
        pattern: SweaterPattern = .byApp,
        stitch: SweaterStitch = .stockinette,
        basket: String = SweaterBaskets.defaultName,
        borderWidth: Double = SweaterLimits.defaultBorderWidth,
        gauge: Double = SweaterLimits.defaultGauge,
        anchor: SweaterAnchor = .corner,
        order: SweaterOrder = .below,
        unfocusedDim: Double = 0,
        accessibilityFocus: Bool = false,
        excludedApps: [String] = [],
        appTheme: AppTheme = .accent
    ) {
        self.active = active
        self.pattern = pattern
        self.stitch = stitch
        self.basket = basket
        self.borderWidth = borderWidth
        self.gauge = gauge
        self.anchor = anchor
        self.order = order
        self.unfocusedDim = unfocusedDim
        self.accessibilityFocus = accessibilityFocus
        self.excludedApps = excludedApps
        self.appTheme = appTheme
    }

    public var effectiveGauge: Double {
        max(gauge, SweaterPatternCatalog.minimumRows(for: pattern))
    }
}

public enum SweaterLimits {
    public static let borderWidthRange: ClosedRange<Double> = 2...60
    public static let defaultBorderWidth = 12.0
    public static let gaugeRange: ClosedRange<Double> = 1.5...40
    public static let defaultGauge = 6.0
    public static let dimRange: ClosedRange<Double> = 0...0.9

    public static let borderWidthPresets: [(title: String, value: Double)] = [
        ("Slim", 6), ("Medium", 12), ("Regular", 14), ("Wide", 18), ("Extra Wide", 28),
    ]

    public static let gaugePresets: [(title: String, value: Double)] = [
        ("Chunky", 3), ("Medium", 6), ("Fine", 10), ("Very Fine", 14),
    ]

    public static func clampBorderWidth(_ value: Double) -> Double {
        guard value.isFinite else { return defaultBorderWidth }
        return min(max(value, borderWidthRange.lowerBound), borderWidthRange.upperBound)
    }

    public static func clampGauge(_ value: Double) -> Double {
        guard value.isFinite else { return defaultGauge }
        return min(max(value, gaugeRange.lowerBound), gaugeRange.upperBound)
    }

    public static func clampDim(_ value: Double) -> Double {
        guard value.isFinite else { return dimRange.lowerBound }
        return min(max(value, dimRange.lowerBound), dimRange.upperBound)
    }
}
