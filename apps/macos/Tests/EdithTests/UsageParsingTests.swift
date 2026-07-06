import Foundation
import Testing
@testable import EdithMenuBar

@Suite struct ParseISOTests {
    let epoch = Date(timeIntervalSince1970: 1_751_364_000)

    @Test func nilAndEmptyAndGarbageReturnNil() {
        #expect(UsageStore.parseISO(nil) == nil)
        #expect(UsageStore.parseISO("") == nil)
        #expect(UsageStore.parseISO("not a date") == nil)
    }

    @Test func plainTimestampParses() {
        #expect(UsageStore.parseISO("2025-07-01T10:00:00Z") == epoch)
    }

    @Test func fractionalSecondsAreStripped() {
        #expect(UsageStore.parseISO("2025-07-01T10:00:00.123Z") == epoch)
        #expect(UsageStore.parseISO("2025-07-01T10:00:00.123456Z") == epoch)
    }

    @Test func offsetTimezoneParses() {
        #expect(UsageStore.parseISO("2025-07-01T12:00:00+02:00") == epoch)
        #expect(UsageStore.parseISO("2025-07-01T12:00:00.500+02:00") == epoch)
    }
}

@Suite struct ModelRowTokensTests {
    private func decode(_ json: String) throws -> UsageStore.ModelRow {
        try JSONDecoder().decode(UsageStore.ModelRow.self, from: Data(json.utf8))
    }

    @Test func sumsAllTokenBuckets() throws {
        let row = try decode(
            """
            {"inputTokens":100,"outputTokens":200,"cacheCreationTokens":30,"cacheReadTokens":5}
            """)
        #expect(row.tokens == 335)
    }

    @Test func missingBucketsCountAsZero() throws {
        let row = try decode(#"{"inputTokens":100,"outputTokens":200}"#)
        #expect(row.tokens == 300)
    }

    @Test func allMissingIsZero() throws {
        let row = try decode("{}")
        #expect(row.tokens == 0)
    }

    @Test func costDoesNotCountAsTokens() throws {
        let row = try decode(#"{"inputTokens":100,"cost":42.5}"#)
        #expect(row.tokens == 100)
    }
}
