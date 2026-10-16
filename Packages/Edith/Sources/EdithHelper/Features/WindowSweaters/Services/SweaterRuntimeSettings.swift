import EdithKit
import Foundation

enum SweaterOrdering {
    static let above: Int32 = 1
    static let below: Int32 = -1
}

struct SweaterRuntimeSettings {
    let active: Bool
    let borderWidth: Double
    let order: Int32
    let stitch: SweaterStitch
    let anchor: SweaterAnchor
    let gauge: KnitGauge
    let hidpi: Bool
    let unfocusedDim: Double
    let tuck: Double
    let pattern: SweaterPattern
    let basket: SweaterBasket
    let excludedApps: [String]
    let accessibilityFocus: Bool
    let appTheme: AppTheme
    let renderer: KnitRenderer

    init(_ settings: SweaterSettings, renderer: KnitRenderer) {
        var gauge = KnitGauge.standard
        gauge.rows = settings.effectiveGauge
        self.active = settings.active
        self.borderWidth = SweaterLimits.clampBorderWidth(settings.borderWidth)
        self.order = settings.order == .above ? SweaterOrdering.above : SweaterOrdering.below
        self.stitch = settings.stitch
        self.anchor = settings.anchor
        self.gauge = gauge
        self.hidpi = true
        self.unfocusedDim = SweaterLimits.clampDim(settings.unfocusedDim)
        self.tuck = gauge.tuck
        self.pattern = settings.pattern
        self.basket = SweaterBaskets.basket(named: settings.basket)
        self.excludedApps = settings.excludedApps
        self.accessibilityFocus = settings.accessibilityFocus
        self.appTheme = settings.appTheme
        self.renderer = renderer
    }

    func yarn(forApp app: String) -> (color: UInt32, chart: SweaterChart?) {
        SweaterYarn.resolve(
            app: app, pattern: pattern, basket: basket, appTheme: appTheme)
    }

    func allows(app: String) -> Bool {
        guard !excludedApps.isEmpty else { return true }
        return !excludedApps.contains { $0.caseInsensitiveCompare(app) == .orderedSame }
    }
}
