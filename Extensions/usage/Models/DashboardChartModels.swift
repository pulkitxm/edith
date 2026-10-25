import Foundation

struct ComboPoint: Identifiable {
    let id: String
    let label: String
    let tokens: Double
    let cost: Double
}

struct StackDatum: Identifiable {
    let id: String
    let x: String
    let series: String
    let value: Double
}

struct DashChartData {
    var daily: [ComboPoint] = []
    var stackedCost: [ComboPoint] = []
    var dow: [ComboPoint] = []
    var hourly: [ComboPoint] = []
    var project: [ComboPoint] = []
    var tokenMix: [StackDatum] = []
    var modelTime: [StackDatum] = []
    var source: [StackDatum] = []
    var heatScale = UsageCalendarScale(days: [])
}
