import EdithDatabase
import Foundation
import Testing

@testable import Edith

struct DatabaseGridProjectionTests {
    @Test func reorderedSparseAndDuplicateFieldsUseNames() {
        let records = [
            DatabaseRecord(fields: [
                DatabaseObjectField(name: "b", value: .null),
                DatabaseObjectField(name: "a", value: .string("first")),
                DatabaseObjectField(name: "a", value: .string("duplicate")),
            ]),
            DatabaseRecord(fields: [DatabaseObjectField(name: "b", value: .boolean(true))]),
        ]
        var projection = DatabaseGridProjection()
        #expect(projection.value(named: "a", row: 0, records: records) == .string("first"))
        #expect(projection.value(named: "b", row: 0, records: records) == .null)
        #expect(projection.value(named: "a", row: 1, records: records) == .missing)
        #expect(projection.value(named: "b", row: 1, records: records) == .boolean(true))
        #expect(projection.value(named: "a", row: -1, records: records) == .missing)
        #expect(projection.value(named: "a", row: 2, records: records) == .missing)
    }

    @Test func scrollingCacheStaysBoundedAndInvalidationReleasesValues() {
        let records = (0..<10_000).map {
            DatabaseRecord(fields: [
                DatabaseObjectField(name: "id", value: .signedInteger(Int64($0)))
            ])
        }
        var projection = DatabaseGridProjection()
        for row in records.indices {
            #expect(
                projection.value(named: "id", row: row, records: records)
                    == .signedInteger(Int64(row)))
            #expect(projection.cachedRows.count <= DatabaseGridProjection.rowCacheLimit)
        }
        projection.invalidateRows()
        #expect(projection.cachedRows.isEmpty)
        let replacement = [DatabaseRecord(fields: [DatabaseObjectField(name: "id", value: .null)])]
        #expect(projection.value(named: "id", row: 0, records: replacement) == .null)
    }

    @Test func previewsBoundLargeValuesAndPreserveGraphemes() {
        let family = "👨‍👩‍👧‍👦"
        #expect(DatabaseGridProjection.preview("") == "")
        #expect(DatabaseGridProjection.preview("a\nb\rc") == "a b c")
        let exact = String(repeating: family, count: 512)
        #expect(DatabaseGridProjection.preview(exact) == exact)
        let large = String(repeating: "x", count: 8_000_000)
        #expect(DatabaseGridProjection.preview(large) == String(repeating: "x", count: 511) + "…")
        #expect(
            DatabaseGridProjection.preview(exact + family) == String(repeating: family, count: 511)
                + "…")
    }

    @Test func largeValuePreviewBenchmark() {
        let value = String(repeating: "sample text\n", count: 700_000)
        let start = ContinuousClock.now
        for _ in 0..<20 {
            #expect(DatabaseGridProjection.preview(value).count == 512)
        }
        let bounded = start.duration(to: .now)
        let referenceStart = ContinuousClock.now
        for _ in 0..<20 {
            let compact = value.replacingOccurrences(of: "\n", with: " ")
            #expect(compact.count > 512)
        }
        let reference = referenceStart.duration(to: .now)
        print(
            "database preview, 20 values of 8.4 MB: bounded \(bounded), full-scan reference \(reference)"
        )
    }
}
