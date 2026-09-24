import Foundation
import Testing
import EdithKit

@Suite struct ParseISOTests {
    let epoch = Date(timeIntervalSince1970: 1_751_364_000)

    @Test func nilAndEmptyAndGarbageReturnNil() {
        #expect(EdithDate.parseISO(nil) == nil)
        #expect(EdithDate.parseISO("") == nil)
        #expect(EdithDate.parseISO("not a date") == nil)
    }

    @Test func plainTimestampParses() {
        #expect(EdithDate.parseISO("2025-07-01T10:00:00Z") == epoch)
    }

    @Test func fractionalSecondsAreStripped() {
        #expect(EdithDate.parseISO("2025-07-01T10:00:00.123Z") == epoch)
        #expect(EdithDate.parseISO("2025-07-01T10:00:00.123456Z") == epoch)
    }

    @Test func offsetTimezoneParses() {
        #expect(EdithDate.parseISO("2025-07-01T12:00:00+02:00") == epoch)
        #expect(EdithDate.parseISO("2025-07-01T12:00:00.500+02:00") == epoch)
    }
}
