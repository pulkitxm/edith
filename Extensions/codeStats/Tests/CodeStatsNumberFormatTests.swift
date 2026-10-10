@testable import CodeStatsExtension
import EdithExtensionSupport
import Foundation
import Testing

@Suite struct CodeStatsNumberFormatTests {
    @Test func groupsInThreesWhateverTheLocale() {
        #expect(CodeStatsNumberFormat.grouped(0) == "0")
        #expect(CodeStatsNumberFormat.grouped(999) == "999")
        #expect(CodeStatsNumberFormat.grouped(1_000) == "1,000")
        #expect(CodeStatsNumberFormat.grouped(1_234_567) == "1,234,567")
        #expect(CodeStatsNumberFormat.grouped(-12_345_678) == "-12,345,678")
        #expect(CodeStatsNumberFormat.grouped(1_234_567) != "12,34,567")
        let indian = 1_234_567.formatted(.number.locale(Locale(identifier: "en_IN")))
        #expect(indian == "12,34,567")
        #expect(CodeStatsNumberFormat.grouped(1_234_567) != indian)
    }

    @Test func compactUsesThousandsMillionsAndBillions() {
        #expect(CodeStatsNumberFormat.compact(9_999) == "9,999")
        #expect(CodeStatsNumberFormat.compact(12_345) == "12.3K")
        #expect(CodeStatsNumberFormat.compact(20_000) == "20K")
        #expect(CodeStatsNumberFormat.compact(1_234_567) == "1.2M")
        #expect(CodeStatsNumberFormat.compact(14_360_000) == "14.4M")
        #expect(CodeStatsNumberFormat.compact(3_400_000_000) == "3.4B")
        #expect(CodeStatsNumberFormat.compact(999_950) == "1M")
        #expect(CodeStatsNumberFormat.compact(-2_500_000) == "-2.5M")
        #expect(CodeStatsNumberFormat.compact(1_234_000_000_000) == "1,234B")
        for value in [12_345, 1_234_567, 3_400_000_000] {
            let text = CodeStatsNumberFormat.compact(value)
            #expect(!text.contains("L") && !text.lowercased().contains("cr"))
        }
    }

    @Test func decimalsAndPercentagesStayWestern() {
        #expect(CodeStatsNumberFormat.decimal(1_234_567.891) == "1,234,567.9")
        #expect(CodeStatsNumberFormat.decimal(0.04, fractionDigits: 2) == "0.04")
        #expect(CodeStatsNumberFormat.decimal(-0.01) == "0.0")
        #expect(CodeStatsNumberFormat.percent(12.4) == "12%")
        #expect(CodeStatsNumberFormat.signedPercent(12.6) == "+13%")
        #expect(CodeStatsNumberFormat.signedPercent(-40) == "-40%")
        #expect(CodeStatsNumberFormat.signed(1_500) == "+1,500")
    }
}
