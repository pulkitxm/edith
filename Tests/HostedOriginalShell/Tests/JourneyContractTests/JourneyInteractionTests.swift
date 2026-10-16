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

@MainActor
@Test func checkboxWaitObservesDelayedRedrawWithoutRepeatingTheInteraction() async throws {
    var reads = 0
    var pauses = 0
    let actual = try await JourneyInteraction.waitForCheckboxState(
        0,
        read: {
            reads += 1
            return reads < 3 ? "1" : NSNumber(value: 0)
        },
        pause: { pauses += 1 })
    #expect(actual == 0)
    #expect(reads == 3)
    #expect(pauses == 2)
}

@MainActor
@Test func checkboxWaitRetainsAnUnchangedValueAtItsExactObservationLimit() async throws {
    var reads = 0
    var pauses = 0
    let actual = try await JourneyInteraction.waitForCheckboxState(
        0, observations: 4,
        read: {
            reads += 1
            return "1"
        },
        pause: { pauses += 1 })
    #expect(actual == 1)
    #expect(reads == 4)
    #expect(pauses == 3)
}

@MainActor
@Test func checkboxWaitRejectsMalformedValuesBeforeAnotherObservation() async {
    var reads = 0
    var pauses = 0
    await #expect(throws: JourneyContractError.invalidMetadata) {
        try await JourneyInteraction.waitForCheckboxState(
            0,
            read: {
                reads += 1
                return "false"
            },
            pause: { pauses += 1 })
    }
    #expect(reads == 1)
    #expect(pauses == 0)
}

@MainActor
@Test func checkboxWaitPropagatesCancellationAndRejectsUnboundedConfiguration() async {
    var reads = 0
    await #expect(throws: CancellationError.self) {
        try await JourneyInteraction.waitForCheckboxState(
            0,
            read: {
                reads += 1
                return "1"
            },
            pause: { throw CancellationError() })
    }
    #expect(reads == 1)
    for (expected, observations) in [(2, 1), (0, 0), (0, 52)] {
        await #expect(throws: JourneyContractError.invalidMetadata) {
            try await JourneyInteraction.waitForCheckboxState(
                expected, observations: observations, read: { "0" }, pause: {})
        }
    }
    #expect(reads == 1)
}
