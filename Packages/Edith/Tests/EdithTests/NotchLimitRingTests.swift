import EdithKit
import Testing

@testable import EdithHelper

@Suite struct NotchLimitRingTests {
    @Test func missingWindowIsUnavailable() {
        let value = NotchLimitRingValue(nil)

        #expect(value.progress == 0)
        #expect(value.text == "-")
    }

    @Test func availableWindowShowsRoundedUsage() {
        let value = NotchLimitRingValue(LimitWindow(percent: 47.4, resetsAt: nil))

        #expect(value.progress == 47.4)
        #expect(value.text == "47%")
    }
}
