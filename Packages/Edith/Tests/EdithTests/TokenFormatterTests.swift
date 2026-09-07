import Testing

@testable import Edith
@testable import EdithKit

@Suite struct TokenFormatterTests {
    @Test func compactValuesPromoteAcrossRoundedBoundaries() {
        #expect(TokenFormatter.compact(999) == "999")
        #expect(TokenFormatter.compact(999_999) == "1.0M")
        #expect(TokenFormatter.compact(999_999_999) == "1.00B")
        #expect(TokenFormatter.compact(1_250_000_000) == "1.25B")
    }

    @Test func zeroDonutTotalRemainsZero() {
        #expect(donutTotal([]) == 0)
        #expect(
            donutTotal([
                DonutSlice(id: "one", label: "one", value: 2, color: .red),
                DonutSlice(id: "two", label: "two", value: 3, color: .blue),
            ]) == 5)
    }

    @Test func denseDonutsKeepTheLargestSlicesAndPreserveTheTotal() {
        let slices = (1...12).map {
            DonutSlice(id: "\($0)", label: "model-\($0)", value: Double($0), color: .red)
        }
        let compact = compactDonutSlices(slices, limit: 8, otherColor: .gray)

        #expect(compact.count == 9)
        #expect(compact.last?.label == "Other")
        #expect(donutTotal(compact) == donutTotal(slices))
    }

    @Test func chartDomainsContainOnlyRenderedSeriesInFirstSeenOrder() {
        let bars = [
            StackDatum(id: "1", x: "day-1", series: "b", value: 1),
            StackDatum(id: "2", x: "day-1", series: "a", value: 2),
            StackDatum(id: "3", x: "day-2", series: "b", value: 3),
            StackDatum(id: "4", x: "day-2", series: "Other", value: 4),
        ]

        #expect(chartSeriesDomain(bars) == ["b", "a", "Other"])
    }
}
