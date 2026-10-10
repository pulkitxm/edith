import Charts
import EdithExtensionSupport
import SwiftUI

struct SurfaceChartContent: View {
    let chart: SurfaceChart
    let tile: SurfaceTile

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(4)) {
            Text(chart.title).font(.edithText(.caption2)).foregroundStyle(.secondary)
            Chart {
                ForEach(Array(chart.series.enumerated()), id: \.element.id) { index, series in
                    ForEach(series.points) { point in
                        marks(point, series: series)
                            .foregroundStyle(
                                tile.highlightColor.opacity(max(0.35, 1 - Double(index) * 0.12))
                            )
                            .accessibilityLabel(point.label.isEmpty ? series.title : point.label)
                            .accessibilityValue(
                                point.value.isEmpty ? point.y.formatted() : point.value)
                    }
                }
            }
            .chartXScale(domain: chart.xDomain)
            .chartYScale(domain: chart.yDomain)
            .chartYAxis(.hidden)
            .chartXAxis {
                AxisMarks(values: chart.axisValues) { axis in
                    AxisValueLabel {
                        if let value = axis.as(Double.self) {
                            Text(axisLabel(value)).font(.edithText(.caption2))
                        }
                    }
                }
            }
            .chartLegend(.hidden)
            .frame(height: UIScale.pt(tile.dense ? 60 : 90))
            .accessibilityLabel(chart.title)
        }
    }

    @ChartContentBuilder private func marks(_ point: SurfaceChartPoint, series: SurfaceChartSeries)
        -> some ChartContent
    {
        switch chart.style {
        case .bar:
            BarMark(
                x: .value(chart.xTitle, chart.plotXValue(point.x)),
                y: .value(chart.yTitle, SurfaceChart.plotValue(point.y))
            ).position(by: .value("Series", series.id))
        case .line:
            LineMark(
                x: .value(chart.xTitle, chart.plotXValue(point.x)),
                y: .value(chart.yTitle, SurfaceChart.plotValue(point.y)),
                series: .value("Series", series.id))
        case .area:
            AreaMark(
                x: .value(chart.xTitle, chart.plotXValue(point.x)),
                y: .value(chart.yTitle, SurfaceChart.plotValue(point.y)),
                series: .value("Series", series.id))
        }
    }

    private func axisLabel(_ value: Double) -> String {
        switch chart.xAxis {
        case .date:
            Date(timeIntervalSince1970: chart.plotXValue(value)).formatted(.dateTime.day())
        case .category:
            chart.series.flatMap(\.points).first(where: { chart.plotXValue($0.x) == value })?.label
                ?? ""
        case .number:
            value.formatted(.number.precision(.fractionLength(0)))
        }
    }
}
