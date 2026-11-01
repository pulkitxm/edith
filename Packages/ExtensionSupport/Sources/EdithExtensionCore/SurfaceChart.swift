import Foundation

public enum SurfaceChartStyle: String, Codable, Sendable { case bar, line, area }
public enum SurfaceChartXAxis: String, Codable, Sendable { case number, date, category }

public struct SurfaceChartPoint: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let x: Double
    public let y: Double
    public let label: String
    public let value: String

    public init(_ id: String, x: Double, y: Double, label: String = "", value: String = "") {
        self.id = id; self.x = x; self.y = y; self.label = label; self.value = value
    }
}

public struct SurfaceChartSeries: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let points: [SurfaceChartPoint]
    public let sourceID: String?

    public init(_ id: String, _ title: String, points: [SurfaceChartPoint], sourceID: String? = nil)
    {
        self.id = id; self.title = title; self.points = points; self.sourceID = sourceID
    }
}

public struct SurfaceChart: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let series: [SurfaceChartSeries]
    public let style: SurfaceChartStyle
    public let xAxis: SurfaceChartXAxis
    public let xTitle: String
    public let yTitle: String
    public let field: String?

    public init(
        _ id: String, _ title: String, series: [SurfaceChartSeries],
        style: SurfaceChartStyle = .bar, xAxis: SurfaceChartXAxis = .number,
        xTitle: String = "", yTitle: String = "", field: String? = "chart"
    ) {
        self.id = id; self.title = title; self.series = series; self.style = style;
        self.xAxis = xAxis
        self.xTitle = xTitle; self.yTitle = yTitle; self.field = field
    }

    public var xDomain: ClosedRange<Double> {
        Self.domain(series.flatMap(\.points).map { plotXValue($0.x) }, includeZero: false)
    }

    public var yDomain: ClosedRange<Double> {
        Self.domain(series.flatMap(\.points).map(\.y), includeZero: style != .line)
    }

    public var axisValues: [Double] {
        let values = Array(Set(series.flatMap(\.points).map { plotXValue($0.x) })).sorted()
        guard values.count > 5 else { return values }
        return (0..<5).map { values[$0 * (values.count - 1) / 4] }
    }

    public func plotXValue(_ value: Double) -> Double {
        let plotted = Self.plotValue(value)
        return xAxis == .date ? min(253_402_300_799, max(-62_135_596_800, plotted)) : plotted
    }

    public static func plotValue(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(1e15, max(-1e15, value))
    }

    func validate() throws {
        guard SurfaceSnapshot.validText(id, maximum: 80),
            SurfaceSnapshot.validText(title, maximum: 256),
            SurfaceSnapshot.validText(xTitle, maximum: 256, empty: true),
            SurfaceSnapshot.validText(yTitle, maximum: 256, empty: true),
            field.map({ SurfaceSnapshot.validText($0, maximum: 80) }) ?? true,
            !series.isEmpty, series.count <= 8, Set(series.map(\.id)).count == series.count,
            series.allSatisfy({ series in
                SurfaceSnapshot.validText(series.id, maximum: 80)
                    && SurfaceSnapshot.validText(series.title, maximum: 256)
                    && (series.sourceID.map { SurfaceSnapshot.validText($0, maximum: 2048) } ?? true)
                    && series.points.count <= 1024
                    && Set(series.points.map(\.id)).count == series.points.count
                    && series.points.allSatisfy { point in
                        SurfaceSnapshot.validText(point.id, maximum: 80)
                            && SurfaceSnapshot.validText(point.label, maximum: 256, empty: true)
                            && SurfaceSnapshot.validText(point.value, maximum: 256, empty: true)
                            && point.x.isFinite && point.y.isFinite
                    }
            })
        else { throw ExtensionPeerError.invalidRequest }
    }

    private static func domain(_ values: [Double], includeZero: Bool) -> ClosedRange<Double> {
        let plotted = values.map(plotValue) + (includeZero ? [0] : [])
        let lower = plotted.min() ?? 0
        let upper = plotted.max() ?? 1
        guard lower == upper else { return lower...upper }
        let padding = max(1, abs(lower) * 0.01)
        return plotValue(lower - padding)...plotValue(upper + padding)
    }
}
