import Foundation
import Testing

@testable import EdithDatabase

@Test func clickHouseValueCodecPreservesTypedRows() throws {
    let body = Data(
        """
        ["id","balance","active","created_at","tags","uuid"]
        ["UInt64","Decimal(38,9)","Bool","DateTime64(3, 'UTC')","Array(String)","UUID"]
        ["18446744073709551615","12345678901234567890.123456789",true,"2026-08-30 12:34:56.789",["one","two"],"123E4567-E89B-12D3-A456-426614174000"]

        """.utf8)

    let result = try ClickHouseDatabaseValueCodec.decode(body)

    #expect(result.names == ["id", "balance", "active", "created_at", "tags", "uuid"])
    #expect(result.rows.count == 1)
    #expect(result.rows[0].cells[0].value == .unsignedInteger(UInt64.max))
    #expect(
        result.rows[0].cells[1].value
            == .decimal(DatabaseDecimalValue(rawValue: "12345678901234567890.123456789")))
    #expect(result.rows[0].cells[2].value == .boolean(true))
    #expect(
        result.rows[0].cells[3].value
            == .timestamp(
                DatabaseTimestampValue(
                    text: "2026-08-30 12:34:56.789",
                    timeZoneIdentifier: "UTC",
                    precision: 3)))
    #expect(result.rows[0].cells[4].value == .array([.string("one"), .string("two")]))
    #expect(
        result.rows[0].cells[5].value
            == .uuid(UUID(uuidString: "123E4567-E89B-12D3-A456-426614174000")!))
}

@Test func clickHouseValueCodecBuildsBoundedRecordsAndDescriptors() throws {
    let body = Data(
        """
        ["name","optional"]
        ["LowCardinality(String)","Nullable(Int32)"]
        ["alpha",null]

        """.utf8)

    let result = try ClickHouseDatabaseValueCodec.decode(body)
    let record = try ClickHouseDatabaseValueCodec.record(
        result.rows[0],
        names: result.names)

    #expect(result.fields.map(\.isNullable) == [false, true])
    #expect(record.fields.map(\.name) == ["name", "optional"])
    #expect(record.fields.map(\.value) == [.string("alpha"), .null])
}

@Test func clickHouseValueCodecRejectsMalformedAndUnboundedResults() throws {
    let mismatched = Data(
        """
        ["id"]
        ["UInt64","String"]

        """.utf8)
    #expect(throws: ClickHouseDatabaseValueCodecFailure.invalidResponse) {
        _ = try ClickHouseDatabaseValueCodec.decode(mismatched)
    }

    let duplicate = Data(
        """
        ["id","id"]
        ["UInt64","UInt64"]

        """.utf8)
    #expect(throws: ClickHouseDatabaseValueCodecFailure.invalidResponse) {
        _ = try ClickHouseDatabaseValueCodec.decode(duplicate)
    }

    let oversized = Data(repeating: 0x41, count: DatabaseAdapterBounds.maximumPageBytes + 1)
    #expect(throws: ClickHouseDatabaseValueCodecFailure.responseTooLarge) {
        _ = try ClickHouseDatabaseValueCodec.decode(oversized)
    }
}

@Test func clickHouseValueCodecPreviewsLargeStringsWithoutLosingSize() throws {
    let value = String(repeating: "x", count: ClickHouseDatabaseValueCodec.maximumPreviewBytes + 1)
    let encodedValue = try #require(String(data: JSONEncoder().encode(value), encoding: .utf8))
    let data = try #require(
        """
        ["payload"]
        ["String"]
        [\(encodedValue)]

        """.data(using: .utf8))

    let result = try ClickHouseDatabaseValueCodec.decode(data)

    guard case let .productSpecific(preview) = result.rows[0].cells[0].value else {
        Issue.record("expected a bounded ClickHouse string preview")
        return
    }
    #expect(preview.typeName == "String")
    #expect(
        preview.textRepresentation?.utf8.count
            == ClickHouseDatabaseValueCodec.maximumPreviewBytes)
    #expect(
        preview.attributes.contains(
            DatabaseStringAttribute(name: "truncated", value: "true")))
}
