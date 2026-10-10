import Foundation
import JourneyContract
import Testing

@Test func checkboxSelectionAcceptsOnlyExactStringOrNumericBinaryValues() throws {
    for value: Any in ["0", NSNumber(value: 0), NSNumber(value: false), NSNumber(value: 0.0)] {
        #expect(try JourneyInteraction.checkboxState(value) == 0)
    }
    for value: Any in ["1", NSNumber(value: 1), NSNumber(value: true), NSNumber(value: 1.0)] {
        #expect(try JourneyInteraction.checkboxState(value) == 1)
    }
}

@Test func invalidCheckboxValuesNeverPermitASelectionClick() {
    let values: [Any?] = [
        nil, "", "true", "false", "01", "1.0", " 1", "1 ", "2", "-1",
        NSNumber(value: 2), NSNumber(value: -1), NSNumber(value: 0.5),
        NSNumber(value: Double.nan), NSNumber(value: Double.infinity), ["1"], ["value": 1],
    ]
    for value in values {
        #expect(throws: JourneyContractError.invalidMetadata) {
            try JourneyInteraction.checkboxState(value)
        }
    }
}

@Test func checkboxDiagnosticsExposeOnlyClosedValueCategories() {
    #expect(JourneyInteraction.checkboxValueCategory(nil) == "absent")
    #expect(JourneyInteraction.checkboxValueCategory("private input") == "string")
    #expect(JourneyInteraction.checkboxValueCategory(NSNumber(value: 1)) == "number")
    #expect(JourneyInteraction.checkboxValueCategory(["private": "input"]) == "unsupported")
}
