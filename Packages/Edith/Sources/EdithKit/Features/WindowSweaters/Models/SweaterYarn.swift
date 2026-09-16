import Foundation

public enum SweaterYarn {
    public static func resolve(
        app: String, pattern: SweaterPattern, basket: SweaterBasket, appTheme: AppTheme,
        userRules: [SweaterAppRule] = []
    ) -> (color: UInt32, chart: SweaterChart?) {
        if SweaterTheme.dressesWindows(of: app) {
            let color = SweaterTheme.yarn(for: appTheme)
            switch pattern {
            case .byApp: return (color, SweaterTheme.chart(for: appTheme))
            case .plain: return (color, nil)
            case .chart(let name): return (color, SweaterChartCatalog.chart(named: name))
            }
        }
        let rule = SweaterCollection.rule(for: app, userRules: userRules)
        let color = rule?.color ?? KnitMath.color(forApp: app, basket: basket)
        switch pattern {
        case .byApp:
            guard let name = rule?.chart, !name.isEmpty else { return (color, nil) }
            return (color, SweaterChartCatalog.chart(named: name))
        case .plain:
            return (color, nil)
        case .chart(let name):
            return (color, SweaterChartCatalog.chart(named: name))
        }
    }
}
