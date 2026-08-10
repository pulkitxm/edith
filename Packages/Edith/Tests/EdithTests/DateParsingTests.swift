import EdithKit
import Foundation
import Testing

@Suite struct DateParsingTests {
    @Test func parsesPlainISO() {
        let date = EdithDate.parseISO("2026-07-07T10:30:00Z")
        #expect(date != nil)
        #expect(date?.timeIntervalSince1970 == 1_783_420_200)
    }

    @Test func stripsFractionalSeconds() {
        #expect(
            EdithDate.parseISO("2026-07-07T10:30:00.123Z")
                == EdithDate.parseISO("2026-07-07T10:30:00Z"))
    }

    @Test func parsesTimezoneOffsets() {
        #expect(
            EdithDate.parseISO("2026-07-07T16:00:00+05:30")
                == EdithDate.parseISO("2026-07-07T10:30:00Z"))
    }

    @Test func rejectsNilAndGarbage() {
        #expect(EdithDate.parseISO(nil) == nil)
        #expect(EdithDate.parseISO("") == nil)
        #expect(EdithDate.parseISO("not a date") == nil)
        #expect(EdithDate.parseISO("2026-07-07") == nil)
    }
}
