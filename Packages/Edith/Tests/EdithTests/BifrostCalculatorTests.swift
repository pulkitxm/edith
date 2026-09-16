import Foundation
import Testing

@testable import EdithKit

@Suite struct BifrostCalculatorTests {
    @Test(arguments: [
        ("2+2", "4"),
        ("10 - 4 * 2", "2"),
        ("(10 - 4) * 2", "12"),
        ("7 / 2", "3.5"),
        ("2^10", "1024"),
        ("2 ^ 3 ^ 2", "512"),
        ("-3 + 1", "-2"),
        ("sqrt(144)", "12"),
        ("max(3, 9) * 2", "18"),
        ("round(2.5)", "3"),
        ("floor(-1.2)", "-2"),
        ("1,234 + 1", "1235"),
        ("0xff + 1", "256"),
        ("0b1011 * 2", "22"),
        ("1e3 / 4", "250"),
        ("17 mod 5", "2"),
        ("pi * 0", "0"),
    ]) func evaluatesArithmetic(expression: String, expected: String) {
        let calculation = BifrostCalculator.evaluate(expression)
        #expect(calculation?.copyText == expected, "\(expression)")
    }

    @Test(arguments: [
        ("50 + 10%", "55"),
        ("200 - 25%", "150"),
        ("10% of 50", "5"),
        ("50%", "0.5"),
    ]) func readsPercentagesTheWayPeopleWriteThem(expression: String, expected: String) {
        #expect(BifrostCalculator.evaluate(expression)?.copyText == expected, "\(expression)")
    }

    @Test(arguments: [
        "", "safari", "5", "notes", "2 +", "+", "()", "1 / 0", "sqrt(-4)", "unknown(2)",
        "2 ** 3", "hello world", "1 2 3",
    ]) func refusesWhatIsNotAnExpression(input: String) {
        #expect(BifrostCalculator.evaluate(input) == nil, "\(input)")
    }

    @Test func refusesOverlongInput() {
        let long = String(repeating: "1+", count: 200) + "1"
        #expect(BifrostCalculator.evaluate(long) == nil)
    }

    @Test func plainValueAcceptsABareNumber() {
        #expect(BifrostCalculator.value(of: "12") == 12)
        #expect(BifrostCalculator.value(of: "2 * 3") == 6)
        #expect(BifrostCalculator.value(of: "") == nil)
    }

    @Test func displayGroupsThousandsAndCopyDoesNot() throws {
        let calculation = try #require(BifrostCalculator.evaluate("1000 * 1000"))
        #expect(calculation.display == "1,000,000")
        #expect(calculation.copyText == "1000000")
    }

    @Test func keepsPrecisionReadable() throws {
        let calculation = try #require(BifrostCalculator.evaluate("1 / 3"))
        #expect(calculation.copyText == "0.3333333333")
    }

    @Test func formatsNegativeGroupedNumbers() {
        #expect(BifrostNumberFormat.grouped(-1_234_567) == "-1,234,567")
        #expect(BifrostNumberFormat.grouped(1234.5) == "1,234.5")
        #expect(BifrostNumberFormat.plain(0) == "0")
    }
}
