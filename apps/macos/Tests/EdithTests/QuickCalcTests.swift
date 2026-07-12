import Testing

@testable import EdithKit

@Suite struct QuickCalcTests {
    @Test func evaluatesBasicArithmetic() {
        #expect(QuickCalc.evaluate("2 + 2") == "4")
        #expect(QuickCalc.evaluate("10 - 3") == "7")
        #expect(QuickCalc.evaluate("4 * 5") == "20")
        #expect(QuickCalc.evaluate("10 / 4") == "2.5")
    }

    @Test func respectsOperatorPrecedenceAndParens() {
        #expect(QuickCalc.evaluate("2 + 3 * 4") == "14")
        #expect(QuickCalc.evaluate("(2 + 3) * 4") == "20")
        #expect(QuickCalc.evaluate("-(2 + 3)") == "-5")
    }

    @Test func returnsNilForIncompleteInput() {
        #expect(QuickCalc.evaluate("2 +") == nil)
        #expect(QuickCalc.evaluate("(2 + 3") == nil)
        #expect(QuickCalc.evaluate("") == nil)
        #expect(QuickCalc.evaluate("   ") == nil)
    }

    @Test func returnsNilOnDivideByZeroInsteadOfCrashing() {
        #expect(QuickCalc.evaluate("1 / 0") == nil)
    }

    @Test func returnsNilForGarbageInput() {
        #expect(QuickCalc.evaluate("hello world") == nil)
        #expect(QuickCalc.evaluate("2 ** 2") == nil)
        #expect(QuickCalc.evaluate("2 & 2") == nil)
    }

    @Test func convertsLength() {
        #expect(QuickCalc.evaluate("1 km to m") == "1000 m")
        #expect(QuickCalc.evaluate("12 in to ft") == "1 ft")
    }

    @Test func convertsWeight() {
        #expect(QuickCalc.evaluate("1 kg to lb") == "2.20462 lb")
    }

    @Test func convertsTemperature() {
        #expect(QuickCalc.evaluate("100 c to f") == "212 f")
        #expect(QuickCalc.evaluate("32 f to c") == "0 c")
    }

    @Test func convertsTime() {
        #expect(QuickCalc.evaluate("2 hr to min") == "120 min")
    }

    @Test func rejectsMismatchedUnitCategories() {
        #expect(QuickCalc.evaluate("1 km to kg") == nil)
    }
}
