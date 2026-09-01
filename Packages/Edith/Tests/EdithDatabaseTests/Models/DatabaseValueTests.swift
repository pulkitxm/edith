import EdithDatabase
import Foundation
import Testing

@Suite struct DatabaseValueTests {
    @Test func missingAndNullRemainDistinct() throws {
        let missing = try modelRoundTrip(DatabaseValue.missing)
        let null = try modelRoundTrip(DatabaseValue.null)
        let missingData = try JSONEncoder().encode(DatabaseValue.missing)
        let nullData = try JSONEncoder().encode(DatabaseValue.null)

        #expect(missing == .missing)
        #expect(null == .null)
        #expect(missing != null)
        #expect(missingData != nullData)
    }

    @Test func exactNumericRepresentationsRoundTrip() throws {
        let decimalText = "999999999999999999999999999999.000000000000000000000000000001"
        let values: [DatabaseValue] = [
            .signedInteger(Int64.min),
            .signedInteger(Int64.max),
            .unsignedInteger(UInt64.max),
            .decimal(DatabaseDecimalValue(rawValue: decimalText)),
            .floatingPoint(Double(bitPattern: 0x3FD5_5555_5555_5555)),
        ]

        let decoded = try modelRoundTrip(values)

        #expect(decoded == values)
        guard case let .decimal(decimal) = decoded[3] else {
            Issue.record("Expected an exact decimal value")
            return
        }
        #expect(decimal.rawValue == decimalText)
        guard case let .floatingPoint(floatingPoint) = decoded[4] else {
            Issue.record("Expected a floating point value")
            return
        }
        #expect(floatingPoint.bitPattern == 0x3FD5_5555_5555_5555)
    }

    @Test func structuredAndProductValuesPreserveOrderAndTypes() throws {
        let value = DatabaseValue.object([
            DatabaseObjectField(name: "present", value: .null),
            DatabaseObjectField(name: "absent", value: .missing),
            DatabaseObjectField(
                name: "nested",
                value: .array([
                    .boolean(true),
                    .uuid(UUID(uuidString: "E2EB2DCD-C0B5-46F3-A34C-0583F497A358")!),
                    .date(DatabaseDateValue(text: "2026-08-30", calendarIdentifier: "iso8601")),
                    .time(
                        DatabaseTimeValue(
                            text: "12:34:56.123456", timeZoneOffsetMinutes: 330, precision: 6)),
                    .timestamp(
                        DatabaseTimestampValue(
                            text: "2026-08-30T12:34:56.123456+05:30",
                            timeZoneIdentifier: "Asia/Kolkata",
                            timeZoneOffsetMinutes: 330,
                            precision: 6)),
                ])),
            DatabaseObjectField(
                name: "native",
                value: .productSpecific(
                    DatabaseProductValue(
                        product: .postgresql,
                        typeName: "inet",
                        textRepresentation: "10.77.0.2/32",
                        attributes: [DatabaseStringAttribute(name: "family", value: "IPv4")]))),
        ])

        let decoded = try modelRoundTrip(value)

        #expect(decoded == value)
        guard case let .object(fields) = decoded else {
            Issue.record("Expected an object value")
            return
        }
        #expect(fields.map(\.name) == ["present", "absent", "nested", "native"])
    }

    @Test func completeAndPreviewBinaryValuesRemainDifferent() throws {
        let complete = DatabaseValue.binary(
            .complete(data: Data([0, 1, 2, 3]), mediaType: "application/octet-stream", digest: nil))
        let preview = DatabaseValue.binary(
            .preview(
                byteCount: 4_096,
                bytes: Data([0, 1, 2, 3]),
                mediaType: "application/octet-stream",
                digest: "sha256:abc"))

        #expect(try modelRoundTrip(complete) == complete)
        #expect(try modelRoundTrip(preview) == preview)
        #expect(complete != preview)
    }
}
