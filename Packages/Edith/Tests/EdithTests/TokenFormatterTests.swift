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
}
